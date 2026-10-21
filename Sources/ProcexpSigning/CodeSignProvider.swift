//
//  CodeSignProvider.swift
//  ProcexpSigning — W7
//
//  Real implementation of `SigningProviding`: inspects a Mach-O / bundle on
//  disk with the Security framework code-signing API and computes its SHA-256,
//  and (separately) looks up file reputation via VirusTotal.
//

import Foundation
import Security
import CryptoKit
import ProcexpModel

/// Code-signing + reputation provider (W7).
///
/// `final` + immutable, `Sendable` stored state → safely `Sendable`, as the
/// `SigningProviding` protocol requires.
public final class CodeSignProvider: SigningProviding {
    private let virusTotalClient: VirusTotalClient

    public init() {
        // The client reads the API key from the Keychain each time it needs it,
        // so a key set later via `setAPIKey` takes effect without re-creating.
        self.virusTotalClient = VirusTotalClient(apiKeyProvider: { try Keychain.readAPIKey() })
    }

    // MARK: - API key management

    /// Stores the VirusTotal API key in the login Keychain. Once set, future
    /// `virusTotal(sha256:)` calls will hit the network (subject to caching and
    /// rate limiting). Throws `ProviderError.underlying` on Keychain failure.
    public func setAPIKey(_ key: String) throws {
        try Keychain.setAPIKey(key)
    }

    // MARK: - SigningProviding

    public func signature(forPath path: String) async -> SignatureInfo {
        // SHA-256 is computed regardless of code-signing outcome — it is the key
        // used for VirusTotal lookups and is useful even for unsigned binaries.
        let sha = Self.sha256Hex(path: path)

        let url = URL(fileURLWithPath: path)

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            // Could not even form a static code object → treat as invalid, but
            // still return the hash so reputation checks remain possible.
            return SignatureInfo(
                status: .invalid,
                sha256: sha,
                validationErrorCode: createStatus,
                validationErrorMessage: Self.securityMessage(for: createStatus)
            )
        }

        // 1) Validity → SigningStatus.
        let checkFlags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures))
        let checkStatus = SecStaticCodeCheckValidity(code, checkFlags, nil)
        let status: SigningStatus
        switch checkStatus {
        case errSecSuccess:    status = .signed
        case errSecCSUnsigned: status = .unsigned
        default:               status = .invalid
        }

        // 2) Copy signing information (signer identity + requirement data).
        var teamID: String?
        var authority: [String] = []
        var isAdHoc = false
        var isPlatform: Bool?

        let infoFlags = SecCSFlags(
            rawValue: UInt32(kSecCSSigningInformation) | UInt32(kSecCSRequirementInformation))
        var infoCF: CFDictionary?
        if SecCodeCopySigningInformation(code, infoFlags, &infoCF) == errSecSuccess,
           let cf = infoCF {
            let info = cf as NSDictionary

            teamID = info[kSecCodeInfoTeamIdentifier as String] as? String

            // Authority chain: array of SecCertificate → common names.
            if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
                for cert in certs {
                    var cn: CFString?
                    if SecCertificateCopyCommonName(cert, &cn) == errSecSuccess,
                       let name = cn as String? {
                        authority.append(name)
                    }
                }
            }

            // Code-signature flags → ad-hoc bit. `kSecCodeSignatureAdhoc` is a
            // C `#define` (SecCode.h) and isn't imported into Swift, so we use
            // its documented value (0x2) directly.
            if let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value {
                let adhocBit: UInt32 = 0x0000_0002
                isAdHoc = (flags & adhocBit) != 0
            }

            if status == .unsigned || (status == .signed && isAdHoc) {
                isPlatform = false
            } else if status == .signed {
                isPlatform = Self.platformBinaryStatus(signingInformation: info)
                if isPlatform == true {
                    var appleRequirement: SecRequirement?
                    let requirementStatus = SecRequirementCreateWithString(
                        "anchor apple" as CFString, [], &appleRequirement)
                    if requirementStatus == errSecSuccess, let appleRequirement {
                        let anchorStatus = SecStaticCodeCheckValidity(code, checkFlags, appleRequirement)
                        switch anchorStatus {
                        case errSecSuccess: isPlatform = true
                        case errSecCSReqFailed: isPlatform = false
                        default: isPlatform = nil
                        }
                    } else {
                        isPlatform = nil
                    }
                }
            }
        }

        return SignatureInfo(
            status: status,
            teamID: teamID,
            authority: authority,
            isPlatformBinary: isPlatform,
            isAdHoc: isAdHoc,
            sha256: sha,
            virusTotal: nil,
            validationErrorCode: checkStatus == errSecSuccess ? nil : checkStatus,
            validationErrorMessage: checkStatus == errSecSuccess ? nil : Self.securityMessage(for: checkStatus))
    }

    public func virusTotal(sha256: String) async throws -> VirusTotalResult? {
        try await virusTotalClient.result(forSHA256: sha256)
    }

    // MARK: - Helpers

    private static func platformBinaryStatus(signingInformation info: NSDictionary) -> Bool? {
        guard let value = info[kSecCodeInfoPlatformIdentifier as String] else { return false }
        guard let number = value as? NSNumber else { return nil }
        return number.uint32Value != 0
    }

    /// Streams the file in 1 MiB chunks so large binaries don't get fully
    /// resident in memory. Returns a lowercase hex digest, or `nil` on error.
    static func sha256Hex(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        do {
            while true {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func securityMessage(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Security.framework status \(status)"
    }

}
