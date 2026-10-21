import Darwin
import Foundation
import IOKit
import os

public enum CPUCoreKind: String, Sendable {
    case performance = "P"
    case efficiency = "E"
}

public enum CPUCoreTopology {
    private static let log = Logger(subsystem: "com.sysinternals.procexpmac", category: "CPUTopology")

    public static func coreKinds() -> [CPUCoreKind]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_BASIC_INFO, &cores, &info, &count) == KERN_SUCCESS,
              let info else { return unavailable("Cannot read native CPU identities") }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        let width = MemoryLayout<processor_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride
        guard cores > 0, Int(count) == Int(cores) * width else {
            return unavailable("Incomplete native CPU identities")
        }
        // Basic identities and load statistics use the same kernel processor array.
        let slots = info.withMemoryRebound(to: processor_basic_info_data_t.self, capacity: Int(cores)) { entries in
            (0..<Int(cores)).map { entries[$0].slot_num }
        }
        var kinds: [Int32: CPUCoreKind] = [:]
        for physical in 0..<Int(cores) {
            guard let matching = IOServiceNameMatching("cpu\(physical)") else {
                return unavailable("CPU service matching is unavailable")
            }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else { return unavailable("Indexed CPU services are unavailable") }
            defer { IOObjectRelease(service) }
            let logicalID = IORegistryEntryCreateCFProperty(service, "logical-cpu-id" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            let clusterType = IORegistryEntryCreateCFProperty(service, "cluster-type" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
            guard let identity = decode(logicalID: logicalID, clusterType: clusterType) else {
                return unavailable("Indexed CPU classification is unavailable")
            }
            guard kinds.updateValue(identity.kind, forKey: identity.slot) == nil else {
                return unavailable("Duplicate logical CPU identity")
            }
        }
        guard let ordered = orderedKinds(slots: slots, kinds: kinds) else {
            return unavailable("CPU classifications do not match native load identities")
        }
        return ordered
    }

    private static func decode(logicalID: NSNumber?, clusterType: Data?) -> (slot: Int32, kind: CPUCoreKind)? {
        guard let logicalID, CFGetTypeID(logicalID) == CFNumberGetTypeID(), logicalID.doubleValue.isFinite,
              let slot = Int32(exactly: logicalID.int64Value), slot >= 0,
              logicalID.doubleValue == Double(slot), let clusterType else { return nil }
        let raw = String(decoding: clusterType.prefix { $0 != 0 }, as: UTF8.self)
        guard let kind = CPUCoreKind(rawValue: raw) else { return nil }
        return (slot, kind)
    }

    private static func orderedKinds(slots: [Int32], kinds: [Int32: CPUCoreKind]) -> [CPUCoreKind]? {
        guard !slots.isEmpty, Set(slots).count == slots.count, slots.allSatisfy({ $0 >= 0 }),
              kinds.count == slots.count, slots.allSatisfy({ kinds[$0] != nil }) else { return nil }
        return slots.compactMap { kinds[$0] }
    }

    private static func unavailable(_ reason: String) -> [CPUCoreKind]? {
        log.notice("Per-core classification unavailable: \(reason, privacy: .public)")
        return nil
    }
}
