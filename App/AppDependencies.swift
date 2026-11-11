import AppKit
import Darwin
import ServiceManagement
import ProcexpPrivileged

@MainActor
struct HelperConnection {
    var status: () -> SMAppService.Status
    var register: () async throws -> Void
    var unregister: () async throws -> Void
    var makeProvider: () -> PrivilegedDataProvider

    static var live: Self {
        Self(status: {
            SMAppService.daemon(plistName: HelperConstants.daemonPlistName).status
        }, register: {
            try await PrivilegedDataProvider.installHelper()
        }, unregister: {
            try await PrivilegedDataProvider.uninstallHelper()
        }, makeProvider: { PrivilegedDataProvider() })
    }
}

@MainActor
struct AppDependencies {
    var viewerUID: UInt32 = getuid()
    var chooseReportDestination: (URL?, String) -> URL? = AppModel.chooseReportDestination
    var writeReportFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var loginItem: LoginItemConnection = .live
}
