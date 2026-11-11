//
//  PrivilegedDataProvider.swift
//  ProcexpPrivileged — W2
//
//  The client half of the privileged path. Connects to the root helper daemon
//  over `NSXPCConnection`, and exposes it as a `PrivilegedSampling` provider so
//  the app can use it interchangeably with the unprivileged
//  `LibprocDataProvider`.
//
//  Installation is handled via `SMAppService.daemon(plistName:)`. Under the
//  current ad-hoc ("Sign to Run Locally") signature, `register()` will fail —
//  that is expected until the app is Developer-ID signed (W13). Every such
//  failure is surfaced as a ProviderError with its underlying diagnostic.
//

import Foundation
import ServiceManagement
import ProcexpModel
import os

/// A `PrivilegedSampling` provider backed by the root helper daemon.
///
/// `@unchecked Sendable`: the only mutable state is the cached
/// `NSXPCConnection`, guarded by `lock`. All XPC calls are reply-based and
/// funnelled through `continuation`-bridged helpers.
public final class PrivilegedDataProvider: PrivilegedSampling, @unchecked Sendable {

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let requestTimeout: TimeInterval
    private let proxyProvider: ((@escaping (Error) -> Void) -> ProcexpHelperProtocol?)?
    private static let log = Logger(subsystem: HelperConstants.machServiceName, category: "client")

    public init() {
        requestTimeout = 5
        proxyProvider = nil
    }

    deinit { connection?.invalidate() }

    init(
        requestTimeout: TimeInterval,
        proxyProvider: @escaping (@escaping (Error) -> Void) -> ProcexpHelperProtocol?
    ) {
        self.requestTimeout = requestTimeout
        self.proxyProvider = proxyProvider
    }

    public var capabilities: ProviderCapabilities {
        [.crossUser, .accurateCPU, .fullEnvironment, .modules]
    }

    // MARK: - Helper lifecycle (SMAppService)

    public static func isHelperInstalled() -> Bool {
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        // `.enabled` means launchd has it registered and will launch it on
        // demand. `.requiresApproval` counts as "installed but needs the user
        // to approve in System Settings"; treat only `.enabled` as ready.
        return service.status == .enabled
    }

    public static func helperRequiresApproval() -> Bool {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName).status == .requiresApproval
    }

    public static func installHelper() async throws {
        let helperDirectory = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
        let plistURL = helperDirectory.appendingPathComponent(HelperConstants.daemonPlistName)
        let executableURL = helperDirectory.appendingPathComponent(HelperConstants.machServiceName)
        guard FileManager.default.fileExists(atPath: plistURL.path),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProviderError.underlying("""
            This app build does not contain a complete, executable privileged helper. \
            Plain Xcode builds omit it. Use a packaged, signed build with the helper \
            embedded before enabling privileged mode.
            """)
        }
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        do {
            try service.register()
        } catch {
            throw ProviderError.underlying("Helper registration failed: \(error.localizedDescription)")
        }
    }

    public static func uninstallHelper() async throws {
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        do {
            try await service.unregister()
        } catch {
            throw ProviderError.underlying("Helper removal failed: \(error.localizedDescription)")
        }
    }

    // MARK: - ProcessDataProviding

    public func snapshots(interval: TimeInterval) -> AsyncStream<ProcessSnapshot> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                // First frame immediately, then poll the helper on the interval.
                continuation.yield(await self.snapshot())
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    continuation.yield(await self.snapshot())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compatibility with the non-throwing provider contract. AppModel uses
    /// checkedSnapshot() so failures trigger local fallback, never publication.
    public func snapshot() async -> ProcessSnapshot {
        do { return try await checkedSnapshot() }
        catch {
            Self.log.error("Helper snapshot failed: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    public func checkedSnapshot() async throws -> ProcessSnapshot {
        let data = try await requireData { $0.snapshot(withReply: $1) }
        let snapshot = try Self.decode(ProcessSnapshotDTO.self, data).model
        guard !snapshot.processes.isEmpty else {
            throw ProviderError.underlying("The privileged helper returned an empty process snapshot.")
        }
        return snapshot
    }

    public func threads(of id: ProcessID) async throws -> [ThreadInfo] {
        let data = try await requireData { proxy, reply in
            proxy.threads(pid: id.pid, startTime: id.startTime, withReply: reply)
        }
        return try Self.decode([ThreadInfoDTO].self, data).map(\.model)
    }

    public func modules(of id: ProcessID) async throws -> [ModuleInfo] {
        let data = try await requireData { proxy, reply in
            proxy.modules(pid: id.pid, startTime: id.startTime, withReply: reply)
        }
        return try Self.decode([ModuleInfoDTO].self, data).map(\.model)
    }

    public func fileDescriptors(of id: ProcessID) async throws -> [FileDescriptorInfo] {
        let data = try await requireData { proxy, reply in
            proxy.fileDescriptors(pid: id.pid, startTime: id.startTime, withReply: reply)
        }
        return try Self.decode([FileDescriptorInfoDTO].self, data).map(\.model)
    }

    public func commandLine(of id: ProcessID) async throws -> String? {
        try await callString { $0.commandLine(pid: id.pid, withReply: $1) }
    }

    public func environment(of id: ProcessID) async throws -> [String: String] {
        let data = try await requireData { proxy, reply in
            proxy.environment(pid: id.pid, withReply: reply)
        }
        return try Self.decode([String: String].self, data)
    }

    public func currentDirectory(of id: ProcessID) async throws -> String? {
        try await callString { $0.currentDirectory(pid: id.pid, withReply: $1) }
    }

    public func strings(of id: ProcessID) async throws -> [String] {
        let data = try await requireData { proxy, reply in
            proxy.strings(pid: id.pid, withReply: reply)
        }
        return try Self.decode([String].self, data)
    }

    // MARK: - PrivilegedSampling actions

    public func suspend(_ id: ProcessID) async throws { try await sendSignal(id, SIGSTOP) }
    public func resume(_ id: ProcessID) async throws { try await sendSignal(id, SIGCONT) }
    public func kill(_ id: ProcessID, signal: Int32) async throws { try await sendSignal(id, signal) }

    public func setNice(_ id: ProcessID, to nice: Int32) async throws {
        try await callVoid { proxy, reply in
            proxy.setNice(pid: id.pid, startTime: id.startTime, nice: nice, withReply: reply)
        }
    }

    private func sendSignal(_ id: ProcessID, _ sig: Int32) async throws {
        try await callVoid { proxy, reply in
            proxy.sendSignal(pid: id.pid, startTime: id.startTime, signal: sig, withReply: reply)
        }
    }

    // MARK: - Connection

    /// Lazily create (and cache) a connection to the helper's mach service.
    /// `.privileged` selects launchd's privileged (root) mach registration.
    private func proxyConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let connection = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ProcexpHelperProtocol.self)
        let clear: () -> Void = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.discard(connection)
        }
        connection.interruptionHandler = clear
        connection.invalidationHandler = clear
        connection.resume()
        self.connection = connection
        return connection
    }

    private func discard(_ connection: NSXPCConnection) {
        lock.lock()
        if self.connection === connection { self.connection = nil }
        lock.unlock()
        connection.invalidate()
    }

    // MARK: - Reply-block → async bridges

    /// Bridge a `(Data?, Error?)` reply block, returning the raw `Data?`.
    private func callData(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (Data?, Error?) -> Void) -> Void
    ) async throws -> Data? {
        try await request { proxy, box in
            body(proxy) { data, error in
                if let error { box.resume(throwing: Self.map(error)) }
                else { box.resume(returning: data) }
            }
        }
    }

    /// Like `callData` but treats a `nil` payload as a failure.
    private func requireData(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (Data?, Error?) -> Void) -> Void
    ) async throws -> Data {
        guard let data = try await callData(body) else { throw ProviderError.helperUnavailable }
        return data
    }

    /// Bridge a `(String?, Error?)` reply block. `nil` is a valid result.
    private func callString(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (String?, Error?) -> Void) -> Void
    ) async throws -> String? {
        try await request { proxy, box in
            body(proxy) { value, error in
                if let error { box.resume(throwing: Self.map(error)) }
                else { box.resume(returning: value) }
            }
        }
    }

    /// Bridge an `(Error?)`-only reply block.
    private func callVoid(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (Error?) -> Void) -> Void
    ) async throws {
        try await request { (proxy, box: ContinuationBox<Void>) in
            body(proxy) { error in
                if let error { box.resume(throwing: Self.map(error)) }
                else { box.resume(returning: ()) }
            }
        }
    }

    private func request<T>(
        _ body: @escaping (ProcexpHelperProtocol, ContinuationBox<T>) -> Void
    ) async throws -> T {
        let box = ContinuationBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { raw in
                guard box.install(raw) else { return }
                let connection = proxyProvider == nil ? proxyConnection() : nil
                box.scheduleTimeout(after: requestTimeout) { [weak self] in
                    if let connection { self?.discard(connection) }
                }
                let onError: (Error) -> Void = { error in
                    box.resume(throwing: ProviderError.underlying(
                        "Could not communicate with the privileged helper: \(error.localizedDescription)"
                    ))
                }
                let proxy: ProcexpHelperProtocol?
                if let proxyProvider {
                    proxy = proxyProvider(onError)
                } else {
                    proxy = connection?.remoteObjectProxyWithErrorHandler(onError) as? ProcexpHelperProtocol
                }
                guard let proxy else {
                    box.resume(throwing: ProviderError.helperUnavailable)
                    return
                }
                body(proxy, box)
            }
        } onCancel: {
            box.resume(throwing: CancellationError())
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ProviderError.underlying("decode \(type): \(error.localizedDescription)") }
    }

    /// Map an `NSError` returned by the helper back onto a `ProviderError`.
    private static func map(_ error: Error) -> ProviderError {
        let ns = error as NSError
        guard ns.domain == HelperError.domain,
              let code = HelperError.Code(rawValue: ns.code) else {
            return .underlying(ns.localizedDescription)
        }
        switch code {
        case .notPermitted: return .notPermitted
        case .processGone:  return .processGone
        case .unsupported:  return .unsupported
        case .underlying:   return .underlying(ns.localizedDescription)
        }
    }
}

/// One-shot continuation wrapper so a stray double reply (e.g. the XPC error
/// handler firing after a normal reply, or vice versa) can never trap the
/// checked continuation.
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var timeout: DispatchWorkItem?

    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let result {
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        return true
    }

    func scheduleTimeout(after seconds: TimeInterval, onTimeout: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            if self?.finish(.failure(ProviderError.underlying(
                "The privileged helper did not respond within \(seconds) seconds."
            ))) == true { onTimeout() }
        }
        lock.lock()
        if result == nil { timeout = item } else { item.cancel() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func resume(returning value: T) {
        finish(.success(value))
    }

    func resume(throwing error: Error) {
        finish(.failure(error))
    }

    @discardableResult
    private func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}
