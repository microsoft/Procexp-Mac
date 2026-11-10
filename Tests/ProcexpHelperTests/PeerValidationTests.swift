import Foundation
import Security
import Testing
@testable import ProcexpHelper

@Suite("Release helper peer policy")
struct PeerValidationTests {
    private func ownCode() throws -> SecCode {
        var code: SecCode?
        #expect(SecCodeCopySelf([], &code) == errSecSuccess)
        return try #require(code)
    }

    @Test("Team ID retrieval requests signing metadata")
    func signingInformationFlag() {
        let team = PeerValidation.ownTeamIdentifier { _, flags, information in
            #expect(flags.rawValue & kSecCSSigningInformation != 0)
            information.pointee = [kSecCodeInfoTeamIdentifier: "UBF8T346G9"] as CFDictionary
            return errSecSuccess
        }
        #expect(team == "UBF8T346G9")
    }

    @Test("Missing signing metadata fails closed")
    func missingTeam() {
        #expect(PeerValidation.ownTeamIdentifier { _, _, information in
            information.pointee = [:] as CFDictionary
            return errSecSuccess
        } == nil)
        #expect(PeerValidation.ownTeamIdentifier { _, _, _ in errSecCSUnsigned } == nil)
    }

    @Test("Release policy retains Apple anchor, official identifier, and same-team requirement")
    func officialRequirement() throws {
        let code = try ownCode()
        for status in [errSecSuccess, errSecCSReqFailed] {
            let accepted = PeerValidation.isOfficialPeer(
                code, pid: getpid(), teamIdentifier: "UBF8T346G9"
            ) { _, _, requirement in
                var text: CFString?
                #expect(SecRequirementCopyString(requirement, [], &text) == errSecSuccess)
                let requirementText = try? #require(text) as String
                #expect(requirementText?.contains("anchor apple generic") == true)
                #expect(requirementText?.contains("com.sysinternals.procexpmac") == true)
                #expect(requirementText?.contains("certificate leaf[subject.OU]") == true)
                #expect(requirementText?.contains("UBF8T346G9") == true)
                return status
            }
            #expect(accepted == (status == errSecSuccess))
        }
    }

    @Test("Release policy rejects unknown teams and an actual non-official peer")
    func rejectsNonOfficialPeer() throws {
        let code = try ownCode()
        #expect(!PeerValidation.isOfficialPeer(code, pid: getpid(), teamIdentifier: nil))
        #expect(!PeerValidation.isOfficialPeer(code, pid: getpid(), teamIdentifier: ""))
        #expect(!PeerValidation.isOfficialPeer(code, pid: getpid(), teamIdentifier: "UBF8T346G9"))
    }
}
