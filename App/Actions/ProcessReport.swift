import AppKit
import ProcexpModel
import UniformTypeIdentifiers

struct ProcessReportTable: Equatable {
    var headers: [String]
    var rows: [[String]]

    var text: String {
        ([headers] + rows).map { $0.joined(separator: "\t") + "\n" }.joined()
    }
}

struct ProcessReport {
    var processes: ProcessReportTable
    var lowerPane: (name: String, pid: Int32, table: ProcessReportTable)?

    var data: Data {
        var text = processes.text + "\n"
        if let lowerPane {
            text += "Process: \(lowerPane.name) Pid: \(lowerPane.pid)\n\n"
            text += lowerPane.table.text
        }
        // Windows CRT text mode expands every LF, including LFs inside cells.
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
}

enum ProcessReportError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

@MainActor
protocol ProcessReportProviding: AnyObject {
    func reportTable() throws -> ProcessReportTable
}

@MainActor
protocol LowerPaneReportProviding: ProcessReportProviding {
    var reportProcessID: ProcessID? { get }
    var reportMode: LowerPaneMode { get }
    var reportError: String? { get }
    var tableView: NSTableView? { get }
    var reportRowCount: Int { get }
    func reportCell(column: String, row: Int) -> String
}

extension LowerPaneReportProviding {
    func reportTable() throws -> ProcessReportTable {
        if let reportError { throw ProcessReportError.unavailable(reportError) }
        guard let tableView, tableView.window != nil else {
            throw ProcessReportError.unavailable("The lower pane is not ready to save.")
        }
        let columns = tableView.tableColumns
        return ProcessReportTable(
            headers: columns.map(\.title),
            rows: (0..<reportRowCount).map { row in
                columns.map { reportCell(column: $0.identifier.rawValue, row: row) }
            }
        )
    }
}

extension AppModel {
    func captureProcessReport() throws -> ProcessReport {
        guard let processReportSource else {
            throw ProcessReportError.unavailable("Open the main process window before saving.")
        }
        var report = ProcessReport(processes: try processReportSource.reportTable())
        if showLowerPane, let selection {
            guard let record = snapshot.info(selection),
                  let source = lowerPaneReportSource,
                  source.reportProcessID == selection, source.reportMode == lowerPaneMode else {
                throw ProcessReportError.unavailable(
                    "The selected process's lower pane is still refreshing. Wait for it to load, or hide the lower pane to save only the process list."
                )
            }
            report.lowerPane = (record.name, selection.pid, try source.reportTable())
        }
        return report
    }

    func saveProcessReport(alwaysPrompt: Bool = false) {
        do {
            // Freeze the displayed report before the modal panel can run another refresh.
            let report = try captureProcessReport()
            let name = selection.flatMap { snapshot.info($0)?.name } ?? "Procexp"
            let suggestedName = name.hasPrefix("<") ? "Procexp" : name.replacingOccurrences(of: "/", with: "_")
            let destination: URL
            if !alwaysPrompt, let reportDestination {
                destination = reportDestination
            } else {
                guard let chosen = dependencies.chooseReportDestination(reportDestination, "\(suggestedName).txt") else { return }
                destination = chosen
            }
            try dependencies.writeReportFile(report.data, destination)
            reportDestination = destination
        } catch {
            processActionAlert = ProcessActionAlert(
                title: "Could Not Save Process Explorer Data",
                message: error.localizedDescription
            )
        }
    }

    static func chooseReportDestination(previous: URL?, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Process Explorer Data"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = previous?.lastPathComponent ?? suggestedName
        panel.directoryURL = previous?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
