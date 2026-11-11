import Foundation
import Testing
import ProcexpModel
@testable import ProcexpPrivileged

@Suite("Helper connection failures")
struct HelperClientTests {
    private func failure(_ operation: () async throws -> Void) async -> String {
        do {
            try await operation()
            Issue.record("Expected a helper failure")
            return ""
        } catch { return error.localizedDescription }
    }

    @Test("Unavailable and rejected proxies fail rather than return empty snapshots")
    func unavailable() async {
        let missing = PrivilegedDataProvider(requestTimeout: 0.05, proxyProvider: { _ in nil })
        #expect(await failure { _ = try await missing.checkedSnapshot() }.contains("not available"))
        let rejected = PrivilegedDataProvider(requestTimeout: 0.05, proxyProvider: { onError in
            onError(NSError(domain: NSCocoaErrorDomain, code: 4097,
                            userInfo: [NSLocalizedDescriptionKey: "Peer rejected"]))
            return nil
        })
        #expect(await failure { _ = try await rejected.checkedSnapshot() }.contains("Peer rejected"))
    }

    @Test("Nil, malformed, empty, and helper-error snapshots are explicit failures")
    func badSnapshots() async throws {
        let stub = HelperStub()
        let empty = try JSONEncoder().encode(ProcessSnapshotDTO(.empty))
        for payload in [nil, Data("invalid JSON".utf8), empty] {
            stub.onSnapshot = { $0(payload, nil) }
            #expect(!(await failure { _ = try await stub.provider().checkedSnapshot() }).isEmpty)
        }
        stub.onSnapshot = { $0(nil, HelperError.make(.notPermitted, "Denied")) }
        #expect(await failure { _ = try await stub.provider().checkedSnapshot() } == "Operation not permitted.")
    }

    @Test("Valid snapshot and nullable details retain their behavior")
    func success() async throws {
        let stub = HelperStub()
        let data = try JSONEncoder().encode(ProcessSnapshotDTO(HelperStub.snapshot(pid: 42)))
        stub.onSnapshot = { $0(data, nil) }
        stub.onString = { $0(nil, nil) }
        stub.onAction = { $0(nil) }
        let provider = stub.provider()
        #expect(try await provider.checkedSnapshot().processes.count == 1)
        #expect(try await provider.commandLine(of: ProcessID(pid: 42, startTime: 1)) == nil)
        try await provider.setNice(ProcessID(pid: 42, startTime: 1), to: 0)
    }

    @Test("All reply shapes have a bounded timeout")
    func timeout() async {
        let provider = HelperStub().provider()
        let id = ProcessID(pid: 42, startTime: 1)
        let start = Date()
        #expect(await failure { _ = try await provider.checkedSnapshot() }.contains("did not respond"))
        #expect(await failure { _ = try await provider.commandLine(of: id) }.contains("did not respond"))
        #expect(await failure { try await provider.setNice(id, to: 0) }.contains("did not respond"))
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("Cancellation returns promptly, including cancellation before the request")
    func cancellation() async throws {
        let provider = HelperStub().provider(timeout: 30)
        for cancelBeforeRequest in [false, true] {
            let start = Date()
            let task = Task {
                if cancelBeforeRequest { withUnsafeCurrentTask { $0?.cancel() } }
                return try await provider.checkedSnapshot()
            }
            if !cancelBeforeRequest {
                try await Task.sleep(for: .milliseconds(20))
                task.cancel()
            }
            do {
                _ = try await task.value
                Issue.record("Expected cancellation")
            } catch { #expect(error is CancellationError) }
            #expect(Date().timeIntervalSince(start) < 2)
        }
    }

    @Test("Late and duplicate replies after timeout or cancellation are ignored")
    func lateReplies() async throws {
        let stub = HelperStub()
        let data = try JSONEncoder().encode(ProcessSnapshotDTO(HelperStub.snapshot(pid: 42)))
        stub.onSnapshot = { reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                reply(data, nil)
                reply(nil, HelperError.make(.underlying, "late error"))
            }
        }
        let provider = stub.provider(timeout: 0.01)
        #expect(await failure { _ = try await provider.checkedSnapshot() }.contains("did not respond"))
        let task = Task { try await provider.checkedSnapshot() }
        task.cancel()
        _ = await task.result
        try await Task.sleep(for: .milliseconds(150))
    }
}
