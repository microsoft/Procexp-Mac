import Testing
import Foundation
@testable import ProcexpModel

@Suite("Coalition inference")
struct CoalitionTests {
    private static let launchd = ProcessID(pid: 1, startTime: 0)

    private static func record(
        _ pid: Int32, _ name: String, path: String?, parent: ProcessID? = launchd,
        jetsam: UInt64?, started: TimeInterval
    ) -> ProcessRecord {
        ProcessRecord(
            id: ProcessID(pid: pid, startTime: UInt64(started)),
            parent: parent,
            name: name,
            executablePath: path,
            coalition: jetsam.map { CoalitionMembership(resourceID: $0 - 1, jetsamID: $0) },
            startTimeDate: Date(timeIntervalSince1970: started)
        )
    }

    /// Safari-like app with two WebKit XPC services (spawned by launchd) and a
    /// forked shell + grandchild, plus a lone daemon and an XPC-only pool.
    private static func sample() -> [ProcessID: ProcessRecord] {
        let safari = record(100, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari",
                            jetsam: 865, started: 10)
        let shell = record(105, "zsh", path: "/bin/zsh", parent: safari.id, jetsam: 865, started: 12)
        let records = [
            record(1, "launchd", path: "/sbin/launchd", parent: nil, jetsam: 3, started: 0),
            safari,
            record(101, "com.apple.WebKit.GPU",
                   path: "/S/L/F/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                   jetsam: 865, started: 11),
            record(102, "Share",
                   path: "/Applications/Safari.app/Contents/PlugIns/Share.appex/Contents/MacOS/Share",
                   jetsam: 865, started: 11),
            shell,
            record(106, "claude", path: "/opt/claude", parent: shell.id, jetsam: 865, started: 13),
            record(200, "coreaudiod", path: "/usr/sbin/coreaudiod", jetsam: 504, started: 5),
            record(201, "DriverHelper",
                   path: "/S/L/F/CoreAudio.framework/XPCServices/DriverHelper.xpc/Contents/MacOS/DriverHelper",
                   jetsam: 504, started: 6),
            record(300, "Worker", path: "/S/L/ExtensionKit/Extensions/W.appex/Contents/MacOS/W",
                   jetsam: 1839, started: 7),
            record(301, "Worker2", path: "/S/L/ExtensionKit/Extensions/X.appex/Contents/MacOS/X",
                   jetsam: 1839, started: 8),
            record(400, "nocoal", path: "/usr/bin/nocoal", jetsam: nil, started: 9),
        ]
        var map: [ProcessID: ProcessRecord] = [:]
        for r in records { map[r.id] = r }
        CoalitionResolver.resolve(&map)
        return map
    }

    private static func find(_ map: [ProcessID: ProcessRecord], _ pid: Int32) -> ProcessRecord {
        map.values.first { $0.id.pid == pid }!
    }

    @Test("Role is inferred from the bundle the executable lives in")
    func roleFromPath() {
        #expect(CoalitionResolver.role(forPath: "/a/B.xpc/Contents/MacOS/B") == .xpcService)
        #expect(CoalitionResolver.role(forPath: "/a/B.appex/Contents/MacOS/B") == .appExtension)
        #expect(CoalitionResolver.role(forPath: "/a/B.app/Contents/MacOS/B") == .member)
        #expect(CoalitionResolver.role(forPath: nil) == .member)
    }

    @Test("Only a bundle's own main executable counts as an app")
    func appMainExecutable() {
        #expect(CoalitionResolver.isAppMainExecutable("/Applications/Safari.app/Contents/MacOS/Safari"))
        #expect(!CoalitionResolver.isAppMainExecutable("/Applications/X.app/Contents/MacOS/sub/tool"))
        #expect(!CoalitionResolver.isAppMainExecutable("/usr/bin/true"))
    }

    @Test("The app leads its coalition and its helpers get roles")
    func appLeadsCoalition() {
        let map = Self.sample()
        let safari = Self.find(map, 100)
        #expect(safari.coalition?.role == .leader)
        #expect(safari.coalition?.memberCount == 5)
        for pid: Int32 in [101, 102, 105, 106] {
            #expect(Self.find(map, pid).coalition?.leader == safari.id)
            #expect(Self.find(map, pid).coalition?.leaderName == "Safari")
        }
        #expect(Self.find(map, 101).coalition?.role == .xpcService)
        #expect(Self.find(map, 102).coalition?.role == .appExtension)
        #expect(Self.find(map, 105).coalition?.role == .member)
    }

    @Test("A daemon with XPC services leads when no app is present")
    func daemonLeads() {
        let map = Self.sample()
        let coreaudiod = Self.find(map, 200)
        #expect(coreaudiod.coalition?.role == .leader)
        #expect(Self.find(map, 201).coalition?.leader == coreaudiod.id)
    }

    @Test("An extension-only pool has no leader")
    func poolHasNoLeader() {
        let map = Self.sample()
        #expect(Self.find(map, 300).coalition?.leader == nil)
        #expect(Self.find(map, 300).coalition?.groupParent == nil)
        #expect(Self.find(map, 301).coalition?.role == .appExtension)
    }

    @Test("A lone process is not shared and stays top level")
    func singleton() {
        let map = Self.sample()
        let launchd = Self.find(map, 1)
        #expect(launchd.coalition?.isShared == false)
        #expect(launchd.coalition?.groupParent == nil)
        #expect(Column.coalitionRole.string(for: launchd) == "")
        #expect(Column.coalitionLeader.string(for: launchd) == "")
        #expect(Column.coalition.string(for: launchd) == "3")
    }

    @Test("Grouped tree nests helpers under the app and keeps forks under their forker")
    func groupedTree() {
        let map = Self.sample()
        let (roots, children) = CoalitionResolver.groupedTree(from: map)
        let safari = Self.find(map, 100).id
        let shell = Self.find(map, 105).id
        #expect(Set(children[safari]?.map(\.pid) ?? []) == [101, 102, 105])
        #expect(children[shell]?.map(\.pid) == [106])
        #expect(children[Self.find(map, 200).id]?.map(\.pid) == [201])
        let rootPIDs = Set(roots.map(\.pid))
        #expect(rootPIDs == [1, 100, 200, 300, 301, 400])
    }

    @Test("Coalition columns show leader and role for shared coalitions")
    func columns() {
        let map = Self.sample()
        let gpu = Self.find(map, 101)
        #expect(Column.coalition.string(for: gpu) == "865")
        #expect(Column.coalitionRole.string(for: gpu) == "XPC Service")
        #expect(Column.coalitionLeader.string(for: gpu) == "Safari (100)")
        if case .number(let value) = Column.coalition.sortValue(for: gpu) {
            #expect(value == 865)
        } else {
            Issue.record("Coalition column should sort numerically")
        }
        #expect(Column.coalition.string(for: Self.find(map, 400)) == "")
    }
}
