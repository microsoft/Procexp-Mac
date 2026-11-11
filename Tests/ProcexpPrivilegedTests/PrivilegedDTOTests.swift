import Testing
import Foundation
import ProcexpModel
@testable import ProcexpPrivileged

@Suite("W2 Privileged DTOs")
struct PrivilegedDTOTests {
    @Test("ProcessRecordDTO preserves extended process details")
    func processRecordDTOPreservesExtendedDetails() {
        let id = ProcessID(pid: 123, startTime: 456)
        let record = ProcessRecord(
            id: id,
            name: "proc",
            sessionTTY: "ttys001",
            bsdFlagsRaw: 0x50,
            bsdStatusRaw: 2,
            hasControllingTTY: true,
            isSessionLeader: true,
            is64Bit: true,
            runningThreadCount: 2,
            threadUserTime: 3,
            threadSystemTime: 4,
            taskPolicy: 5,
            pageIns: 6,
            copyOnWriteFaults: 7,
            machMessagesSent: 8,
            machMessagesReceived: 9,
            machSyscalls: 10,
            unixSyscalls: 11
        )

        let roundTrip = ProcessRecordDTO(record).model

        #expect(roundTrip.sessionTTY == "ttys001")
        #expect(roundTrip.bsdFlagsRaw == 0x50)
        #expect(roundTrip.bsdStatusRaw == 2)
        #expect(roundTrip.hasControllingTTY)
        #expect(roundTrip.isSessionLeader)
        #expect(roundTrip.is64Bit == true)
        #expect(roundTrip.runningThreadCount == 2)
        #expect(roundTrip.threadUserTime == 3)
        #expect(roundTrip.threadSystemTime == 4)
        #expect(roundTrip.taskPolicy == 5)
        #expect(roundTrip.pageIns == 6)
        #expect(roundTrip.copyOnWriteFaults == 7)
        #expect(roundTrip.machMessagesSent == 8)
        #expect(roundTrip.machMessagesReceived == 9)
        #expect(roundTrip.machSyscalls == 10)
        #expect(roundTrip.unixSyscalls == 11)
    }

    @Test("ProcessRecordDTO carries coalition membership, and old payloads without it still decode")
    func processRecordDTOCoalition() throws {
        let leader = ProcessID(pid: 100, startTime: 1)
        let record = ProcessRecord(
            id: ProcessID(pid: 101, startTime: 2),
            name: "svc",
            coalition: CoalitionMembership(resourceID: 864, jetsamID: 865, role: .xpcService,
                                           leader: leader, leaderName: "Safari",
                                           memberCount: 3, groupParent: leader)
        )
        let data = try JSONEncoder().encode(ProcessRecordDTO(record))
        let decoded = try JSONDecoder().decode(ProcessRecordDTO.self, from: data).model
        #expect(decoded.coalition == record.coalition)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "coalition")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ProcessRecordDTO.self, from: legacy).coalition == nil)
    }

    @Test("ThreadInfoDTO preserves extended thread details")
    func threadInfoDTOPreservesExtendedDetails() {
        let thread = ThreadInfo(
            id: 42,
            name: "worker",
            cpuPercent: 1.5,
            cpuTime: 99,
            userTime: 44,
            kernelTime: 55,
            state: "running",
            currentPriority: 31,
            basePriority: 30,
            maxPriority: 63,
            schedulerPolicy: 1,
            sleepTimeSeconds: 2,
            flags: 3,
            dispatchQueueAddress: 0xfeed
        )

        let roundTrip = ThreadInfoDTO(thread).model

        #expect(roundTrip.name == "worker")
        #expect(roundTrip.userTime == 44)
        #expect(roundTrip.kernelTime == 55)
        #expect(roundTrip.currentPriority == 31)
        #expect(roundTrip.basePriority == 30)
        #expect(roundTrip.maxPriority == 63)
        #expect(roundTrip.schedulerPolicy == 1)
        #expect(roundTrip.sleepTimeSeconds == 2)
        #expect(roundTrip.flags == 3)
        #expect(roundTrip.dispatchQueueAddress == 0xfeed)
    }
}