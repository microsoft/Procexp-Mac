//
//  Coalition.swift
//  ProcexpModel — W0 shared contracts
//
//  macOS groups an app and the XPC services / extensions it launches into a
//  "jetsam coalition" (the kernel uses it for memory-pressure decisions). XPC
//  services are spawned by launchd, so in the BSD parent tree they hang off
//  pid 1 and look unrelated to the app they work for. The coalition is the
//  link back to that app.
//
//  The kernel hands out the coalition IDs to any process via
//  `proc_pidinfo(PROC_PIDCOALITIONINFO)`. The task *role* (leader / XPC /
//  extension) is only published through Endpoint Security (macOS 27.3+), which
//  this app is not, so the role and leader here are inferred from the image
//  path and start order. UI labels them "(inferred)".
//

import Foundation

/// The role a process plays inside its jetsam coalition. Mirrors
/// `es_coalition_task_role_t`, but here it is inferred, never read from ES.
public enum CoalitionRole: String, Sendable, Codable, Hashable {
    /// The process the coalition is "for" — typically the app.
    case leader
    /// An XPC service (`*.xpc` bundle) working for the leader.
    case xpcService
    /// An app extension (`*.appex` bundle) working for the leader.
    case appExtension
    /// Anything else in the coalition, e.g. a child the leader forked.
    case member

    public var title: String {
        switch self {
        case .leader:       return "Leader"
        case .xpcService:   return "XPC Service"
        case .appExtension: return "Extension"
        case .member:       return "Member"
        }
    }
}

/// One process's coalition membership.
public struct CoalitionMembership: Sendable, Codable, Hashable {
    /// Resource-coalition ID (accounting group).
    public var resourceID: UInt64
    /// Jetsam-coalition ID (app + its helpers). This is the grouping key.
    public var jetsamID: UInt64
    /// Inferred role. `nil` until `CoalitionResolver` has run.
    public var role: CoalitionRole?
    /// Inferred leader of the jetsam coalition. `nil` when no member looks like
    /// a leader (e.g. the shared ExtensionKit pool).
    public var leader: ProcessID?
    /// Display name of `leader`, captured at resolve time for columns.
    public var leaderName: String?
    /// Number of live processes in the same jetsam coalition (including self).
    public var memberCount: Int
    /// Parent to use in the "Group by Coalition" tree: the real parent when it
    /// is in the same coalition (so forks stay under their forker), otherwise
    /// the leader. `nil` means "top level".
    public var groupParent: ProcessID?

    public init(resourceID: UInt64,
                jetsamID: UInt64,
                role: CoalitionRole? = nil,
                leader: ProcessID? = nil,
                leaderName: String? = nil,
                memberCount: Int = 1,
                groupParent: ProcessID? = nil) {
        self.resourceID = resourceID
        self.jetsamID = jetsamID
        self.role = role
        self.leader = leader
        self.leaderName = leaderName
        self.memberCount = memberCount
        self.groupParent = groupParent
    }

    /// True when this process shares its coalition with at least one other.
    public var isShared: Bool { memberCount > 1 }
}

public enum CoalitionResolver {

    /// Infer the role from where the executable lives.
    public static func role(forPath path: String?) -> CoalitionRole {
        guard let path else { return .member }
        if path.contains(".xpc/Contents/MacOS/") { return .xpcService }
        if path.contains(".appex/Contents/MacOS/") { return .appExtension }
        return .member
    }

    /// Fill `role`, `leader`, `memberCount` and `groupParent` for every record
    /// that has a coalition. Records without one are left alone.
    ///
    /// Leader choice per jetsam coalition, among members that are not XPC
    /// services or extensions:
    /// 1. a `.app` main executable, earliest started;
    /// 2. otherwise the earliest started member (e.g. `coreaudiod` leading its
    ///    audio XPC services).
    /// A coalition made only of XPC services / extensions has no leader.
    public static func resolve(_ records: inout [ProcessID: ProcessRecord]) {
        var groups: [UInt64: [ProcessID]] = [:]
        for (id, record) in records {
            guard let jetsam = record.coalition?.jetsamID else { continue }
            groups[jetsam, default: []].append(id)
        }

        for (_, members) in groups {
            let candidates = members.filter {
                role(forPath: records[$0]?.executablePath) == .member
            }
            let leader = pickLeader(candidates, in: records)
            let leaderName = leader.flatMap { records[$0]?.name }
            let memberSet = Set(members)

            for id in members {
                guard var record = records[id], var coalition = record.coalition else { continue }
                coalition.memberCount = members.count
                coalition.leader = leader
                coalition.leaderName = leaderName
                if id == leader {
                    coalition.role = .leader
                } else {
                    coalition.role = role(forPath: record.executablePath)
                }
                if members.count < 2 || leader == nil || id == leader {
                    coalition.groupParent = nil
                } else if let parent = record.parent, parent != id, memberSet.contains(parent) {
                    coalition.groupParent = parent
                } else {
                    coalition.groupParent = leader
                }
                record.coalition = coalition
                records[id] = record
            }
        }
    }

    private static func pickLeader(_ candidates: [ProcessID],
                                   in records: [ProcessID: ProcessRecord]) -> ProcessID? {
        func earlier(_ a: ProcessID, _ b: ProcessID) -> Bool {
            let da = records[a]?.startTimeDate ?? .distantFuture
            let db = records[b]?.startTimeDate ?? .distantFuture
            return da != db ? da < db : a.pid < b.pid
        }
        let apps = candidates.filter { isAppMainExecutable(records[$0]?.executablePath) }
        if let app = apps.min(by: earlier) { return app }
        return candidates.min(by: earlier)
    }

    /// `/…/Foo.app/Contents/MacOS/Foo`, not nested inside an `.xpc`/`.appex`.
    static func isAppMainExecutable(_ path: String?) -> Bool {
        guard let path, let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else {
            return false
        }
        return !path[range.upperBound...].contains("/")
    }

    /// `(roots, children)` for the "Group by Coalition" view. Every process
    /// keeps its own row; only the parent used for nesting changes.
    public static func groupedTree(
        from processes: [ProcessID: ProcessRecord]
    ) -> (roots: [ProcessID], children: [ProcessID: [ProcessID]]) {
        var regrouped = processes
        for (id, record) in processes {
            regrouped[id]?.parent = groupParent(of: record)
        }
        return ProcessTreeBuilder.build(from: regrouped)
    }

    /// Parent used for nesting in the coalition view (falls back to "top level"
    /// for processes without coalition data).
    public static func groupParent(of record: ProcessRecord) -> ProcessID? {
        record.coalition?.groupParent
    }
}
