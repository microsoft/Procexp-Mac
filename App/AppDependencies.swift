import AppKit
import Darwin

@MainActor
struct AppDependencies {
    var viewerUID: UInt32 = getuid()
    var chooseReportDestination: (URL?, String) -> URL? = AppModel.chooseReportDestination
    var writeReportFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var loginItem: LoginItemConnection = .live
}
