import Foundation
import ProcexpModel
@testable import ProcexpPrivileged

final class HelperStub: NSObject, ProcexpHelperProtocol, @unchecked Sendable {
    var onSnapshot: (@escaping (Data?, Error?) -> Void) -> Void = { _ in }
    var onString: (@escaping (String?, Error?) -> Void) -> Void = { _ in }
    var onAction: (@escaping (Error?) -> Void) -> Void = { _ in }

    func snapshot(withReply reply: @escaping (Data?, Error?) -> Void) { onSnapshot(reply) }
    func threads(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func modules(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func fileDescriptors(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func commandLine(pid: Int32, withReply reply: @escaping (String?, Error?) -> Void) { onString(reply) }
    func currentDirectory(pid: Int32, withReply reply: @escaping (String?, Error?) -> Void) { onString(reply) }
    func environment(pid: Int32, withReply reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func strings(pid: Int32, withReply reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func sendSignal(pid: Int32, startTime: UInt64, signal: Int32, withReply reply: @escaping (Error?) -> Void) { onAction(reply) }
    func setNice(pid: Int32, startTime: UInt64, nice: Int32, withReply reply: @escaping (Error?) -> Void) { onAction(reply) }

    func provider(timeout: TimeInterval = 0.05) -> PrivilegedDataProvider {
        PrivilegedDataProvider(requestTimeout: timeout, proxyProvider: { _ in self })
    }

    static func snapshot(pid: Int32, interval: TimeInterval = 1) -> ProcessSnapshot {
        let id = ProcessID(pid: pid, startTime: 1)
        return ProcessSnapshot(timestamp: Date(), interval: interval,
                               processes: [id: ProcessRecord(id: id, name: "fixture")],
                               roots: [id], children: [:], system: .zero)
    }
}
