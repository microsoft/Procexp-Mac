import AppKit
import ServiceManagement
import ProcexpModel
@testable import ProcexpPrivileged
@testable import ProcexpMac

private final class LocalProvider: ProcessDataProviding, Sendable {
    let loadStrings: @Sendable () async throws -> [String]

    init(loadStrings: @escaping @Sendable () async throws -> [String] = { ["local"] }) {
        self.loadStrings = loadStrings
    }

    var capabilities: ProviderCapabilities { [] }
    func snapshot() async -> ProcessSnapshot { HelperStub.snapshot(pid: 101, interval: 0) }
    func snapshots(interval: TimeInterval) -> AsyncStream<ProcessSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(HelperStub.snapshot(pid: 101, interval: interval))
                    do { try await Task.sleep(for: .seconds(interval)) }
                    catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func threads(of id: ProcessID) async throws -> [ThreadInfo] { [] }
    func modules(of id: ProcessID) async throws -> [ModuleInfo] { [] }
    func fileDescriptors(of id: ProcessID) async throws -> [FileDescriptorInfo] { [] }
    func commandLine(of id: ProcessID) async throws -> String? { "local" }
    func currentDirectory(of id: ProcessID) async throws -> String? { "/local" }
    func environment(of id: ProcessID) async throws -> [String: String] { ["provider": "local"] }
    func strings(of id: ProcessID) async throws -> [String] { try await loadStrings() }
}

@MainActor
private final class PendingStrings {
    var requests: [CheckedContinuation<[String], Error>] = []

    func load() async throws -> [String] {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
}

@MainActor
private final class Fixture {
    let local = LocalProvider()
    let helper = HelperStub()
    var status: SMAppService.Status = .enabled
    var registrations = 0
    var removals = 0
    var providerCreations = 0
    var registerStatus: SMAppService.Status = .enabled
    var timeout: TimeInterval = 0.05

    var connection: HelperConnection {
        HelperConnection(status: { self.status }, register: {
            self.registrations += 1
            self.status = self.registerStatus
        }, unregister: {
            self.removals += 1
            self.status = .notRegistered
        }, makeProvider: {
            self.providerCreations += 1
            return self.helper.provider(timeout: self.timeout)
        })
    }

    func model() -> AppModel {
        AppModel(localProvider: local, helperConnection: connection, settingsEnabled: false)
    }
    func accept(pid: Int32 = 202) throws {
        let data = try JSONEncoder().encode(ProcessSnapshotDTO(HelperStub.snapshot(pid: pid)))
        helper.onSnapshot = { $0(data, nil) }
    }
    func reject() {
        helper.onSnapshot = { $0(nil, HelperError.make(.underlying, "Peer rejected")) }
    }
}

private enum Failure: Error { case assertion(String) }

@main
struct HelperRecoveryRegression {
    @MainActor
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    @MainActor
    private static func checkLocal(_ model: AppModel, _ fixture: Fixture) async throws {
        try check(model.privileged == nil, "Failed helper is still active")
        try check(model.actions.privileged == nil, "Actions retained an unavailable helper")
        try check((model.data as AnyObject) === fixture.local, "Details did not switch to the local provider")
        try check(model.snapshot.processes.keys.contains { $0.pid == 101 }, "Local snapshot was not published")
        let command = try await model.data.commandLine(of: ProcessID(pid: 101, startTime: 1))
        try check(command == "local", "Process detail access did not recover")
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.assertion("Timed out waiting for sampling state")
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared

        for status: SMAppService.Status in [.notRegistered, .requiresApproval] {
            let fixture = Fixture()
            fixture.status = status
            let model = fixture.model()
            await model.forceRefresh()
            try await checkLocal(model, fixture)
            try check(fixture.providerCreations == 0, "Probed an unapproved or unregistered helper")
            try check(model.helperApprovalPending == (status == .requiresApproval), "Approval state was lost")
        }
        print("PASS: local startup and approval-pending startup")

        let rejected = Fixture()
        rejected.reject()
        for _ in 0..<2 {
            let model = rejected.model()
            try check(model.privileged == nil, "Trusted registration before a response")
            await model.forceRefresh()
            try await checkLocal(model, rejected)
            try check(model.helperInstalled, "Unreachable helper can no longer be uninstalled")
            try check(model.helperFailure?.contains("Peer rejected") == true, "Underlying rejection was hidden")
            try check(model.processActionAlert != nil, "Startup failure was not surfaced")
            model.processActionAlert = nil
            await model.forceRefresh()
            try check(model.processActionAlert == nil, "Repeated warning on local refresh")
        }
        print("PASS: rejected startup and relaunch recover without empty publication or warning loops")

        let running = Fixture()
        try running.accept()
        let active = running.model()
        await active.forceRefresh()
        try check(active.privileged != nil && active.actions.privileged != nil, "Usable helper was not adopted")
        try check(active.snapshot.processes.keys.contains { $0.pid == 202 }, "Verified helper snapshot was not published")
        let activeGeneration = active.providerGeneration
        running.reject()
        await active.forceRefresh()
        try await checkLocal(active, running)
        try check(active.providerGeneration > activeGeneration, "Details were not told to reload on fallback")
        print("PASS: verified activation, later Refresh Now failure, and coherent detail/action fallback")

        let details = Fixture()
        try details.accept(pid: 101)
        details.helper.onString = { $0("helper", nil) }
        let detailModel = details.model()
        detailModel.columns = [.name, .commandLine]
        for _ in 0..<2 {
            await detailModel.forceRefresh()
            try await Task.sleep(for: .milliseconds(20))
        }
        let detailID = ProcessID(pid: 101, startTime: 1)
        try check(detailModel.snapshot.info(detailID)?.commandLine == "helper", "Helper command-line fixture was not cached")
        let detail = PropertiesDetail()
        await detail.loadStringsIfNeeded(
            pid: detailID, data: detailModel.data, providerGeneration: detailModel.providerGeneration
        )
        try check(detail.stringsNote != nil, "Helper strings fixture did not establish a failed lookup")
        details.reject()
        for _ in 0..<2 {
            await detailModel.forceRefresh()
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(detailModel.snapshot.info(detailID)?.commandLine == "local", "Fallback retained stale helper command-line cache")
        await detail.loadStatic(
            pid: detailID, record: detailModel.snapshot.info(detailID), data: detailModel.data,
            signing: detailModel.signing, autostart: detailModel.autostart
        )
        await detail.loadStringsIfNeeded(
            pid: detailID, data: detailModel.data, providerGeneration: detailModel.providerGeneration
        )
        try check(detail.commandLine == "local" && detail.currentDirectory == "/local",
                  "Static process properties did not reload from local access")
        try check(detail.environment.first?.value == "local", "Environment did not recover")
        try check(detail.strings == ["local"] && detail.stringsNote == nil, "Failed strings lookup did not recover after provider change")
        print("PASS: command-line cache and existing process-property details recover on provider change")

        for oldFinishesFirst in [true, false] {
            for oldFails in [true, false] {
                let pending = PendingStrings()
                let local = LocalProvider { try await pending.load() }
                let stringsDetail = PropertiesDetail()
                let oldLoad = Task { await stringsDetail.loadStringsIfNeeded(pid: detailID, data: local) }
                try await waitUntil { pending.requests.count == 1 }
                oldLoad.cancel()
                let replacement = Task { await stringsDetail.loadStringsIfNeeded(pid: detailID, data: local) }
                try await waitUntil { pending.requests.count == 2 }

                func finishOldLoad() {
                    if oldFails {
                        pending.requests[0].resume(throwing: Failure.assertion("Stale scan failed"))
                    } else {
                        pending.requests[0].resume(returning: ["stale"])
                    }
                }

                if oldFinishesFirst {
                    finishOldLoad()
                    await oldLoad.value
                    try check(stringsDetail.isLoadingStrings, "Cancelled load cleared replacement loading state")
                    try check(stringsDetail.strings.isEmpty && stringsDetail.stringsNote == nil,
                              "Cancelled load published stale results")
                }
                pending.requests[1].resume(returning: ["replacement"])
                await replacement.value
                if !oldFinishesFirst {
                    finishOldLoad()
                    await oldLoad.value
                }
                try check(!stringsDetail.isLoadingStrings && stringsDetail.strings == ["replacement"]
                          && stringsDetail.stringsNote == nil, "Reopened Strings tab lost replacement results")
                await stringsDetail.loadStringsIfNeeded(pid: detailID, data: LocalProvider())
                try check(stringsDetail.strings == ["replacement"], "Old completion invalidated replacement cache")
            }
        }
        print("PASS: reopening Strings replaces cancelled scans without stale results or loading-state changes")

        let stalled = Fixture()
        let stalledModel = stalled.model()
        let start = Date()
        await stalledModel.forceRefresh()
        try await checkLocal(stalledModel, stalled)
        try check(Date().timeIntervalSince(start) < 2, "Unresponsive startup hung")
        try check(stalledModel.helperFailure?.contains("did not respond") == true, "Timeout reason was hidden")
        print("PASS: unresponsive helper startup has a bounded recovery")

        let streaming = Fixture()
        try streaming.accept()
        let streamModel = streaming.model()
        await streamModel.start()
        try await waitUntil { streamModel.privileged != nil && !streamModel.snapshot.processes.isEmpty }
        streaming.reject()
        try await waitUntil { streamModel.helperFailure != nil && streamModel.snapshot.processes.keys.contains { $0.pid == 101 } }
        try await checkLocal(streamModel, streaming)
        let timestamp = streamModel.snapshot.timestamp
        try await waitUntil { streamModel.snapshot.timestamp > timestamp }
        try check(streamModel.snapshot.interval == streamModel.refreshInterval,
                  "Fallback replaced the local sampler's interval-aware stream with one-shot polling")
        streamModel.stop()
        print("PASS: ongoing stream failure recovers and local sampling continues")

        let concurrent = Fixture()
        let concurrentStarted = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let concurrentLock = NSLock()
        var concurrentRequests = 0
        let helperData = try JSONEncoder().encode(ProcessSnapshotDTO(HelperStub.snapshot(pid: 202)))
        concurrent.helper.onSnapshot = { reply in
            concurrentLock.lock()
            concurrentRequests += 1
            let request = concurrentRequests
            concurrentLock.unlock()
            if request <= 2 {
                concurrentStarted[request - 1].signal()
                let delay: TimeInterval = request == 1 ? 0.05 : 0.2
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    if request == 1 {
                        reply(helperData, nil)
                    } else {
                        reply(nil, HelperError.make(.underlying, "Superseded helper sample failed"))
                    }
                }
            } else {
                reply(helperData, nil)
            }
        }
        let concurrentModel = concurrent.model()
        concurrentModel.paused = true
        let firstRefresh = Task { await concurrentModel.forceRefresh() }
        try await waitUntil { concurrentStarted[0].wait(timeout: .now()) == .success }
        let secondRefresh = Task { await concurrentModel.forceRefresh() }
        try await waitUntil { concurrentStarted[1].wait(timeout: .now()) == .success }
        try await waitUntil { concurrentModel.privileged != nil }
        await firstRefresh.value
        await secondRefresh.value
        try check(concurrentModel.snapshot.processes.keys.contains { $0.pid == 202 },
                  "A superseded helper failure published a local-only snapshot")
        try check(concurrentModel.privileged != nil && concurrentModel.actions.privileged != nil,
                  "A superseded helper failure changed the active provider")
        print("PASS: overlapping refreshes retry a superseded helper failure against the active provider")

        let install = Fixture()
        install.status = .notRegistered
        install.reject()
        let installModel = install.model()
        installModel.paused = true
        let failed = await installModel.installPrivilegedHelper()
        try check(!failed.ok && failed.message.contains("Peer rejected"), "Install reported success before helper verification")
        try check(installModel.helperInstalled, "Failed activation lost registered state")
        try await checkLocal(installModel, install)
        try install.accept()
        let retried = await installModel.installPrivilegedHelper()
        try check(retried.ok && installModel.privileged != nil, "Explicit retry did not recover")
        try check(install.registrations == 1, "Retry attempted to re-register an enabled helper")
        let removed = await installModel.uninstallPrivilegedHelper()
        try check(removed.ok && install.removals == 1, "Uninstall did not remain available")
        try check(!installModel.helperInstalled && !installModel.helperApprovalPending, "Removed state is incorrect")
        try await checkLocal(installModel, install)
        print("PASS: install verification, retry, and paused uninstall")

        let pending = Fixture()
        pending.status = .notRegistered
        pending.registerStatus = .requiresApproval
        let pendingModel = pending.model()
        let approval = await pendingModel.installPrivilegedHelper()
        try check(approval.ok && pendingModel.helperApprovalPending && pendingModel.privileged == nil,
                  "Awaiting approval was confused with reachable")
        try check(pending.providerCreations == 0, "Probed before approval")
        _ = await pendingModel.uninstallPrivilegedHelper()
        pendingModel.stop()
        print("PASS: approval-pending installation and removal")

        let cancelled = Fixture()
        let started = DispatchSemaphore(value: 0)
        cancelled.helper.onSnapshot = { _ in started.signal() }
        let cancelledModel = cancelled.model()
        await cancelledModel.start()
        try await waitUntil { started.wait(timeout: .now()) == .success }
        cancelledModel.stop()
        try await Task.sleep(for: .milliseconds(100))
        try check(cancelledModel.helperFailure == nil && cancelledModel.privileged == nil,
                  "Cancellation was treated as helper failure or activated a stale helper")
        print("PASS: stopping startup sampling cancels its helper probe")

        let stale = Fixture()
        stale.timeout = 1
        let staleStarted = DispatchSemaphore(value: 0)
        let lateData = try JSONEncoder().encode(ProcessSnapshotDTO(HelperStub.snapshot(pid: 202)))
        stale.helper.onSnapshot = { reply in
            staleStarted.signal()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reply(lateData, nil) }
        }
        let staleModel = stale.model()
        staleModel.paused = true
        let refresh = Task { await staleModel.forceRefresh() }
        try await waitUntil { staleStarted.wait(timeout: .now()) == .success }
        _ = await staleModel.uninstallPrivilegedHelper()
        await refresh.value
        try await checkLocal(staleModel, stale)
        try check(!staleModel.helperInstalled && staleModel.helperFailure == nil,
                  "A late activation response resurrected the removed helper")
        print("PASS: late activation response cannot resurrect an uninstalled helper")
        print("All helper-recovery regressions passed.")
    }
}
