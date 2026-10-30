import AppKit
import ProcexpModel
@testable import ProcexpMac

enum RegressionFailure: Error {
    case failed(String)
}

@main
struct ProcessOutlineRegression {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let model = AppModel()
        model.scrollToNewProcesses = false
        model.showProcessesFromAllUsers = true
        let columns: [Column] = [.name, .pid, .cpu, .privateBytes, .workingSet]
        model.columnWidths = Dictionary(uniqueKeysWithValues: columns.map { ($0.rawValue, 500.0) })
        let coordinator = ProcessOutlineView.Coordinator(model: model, onCommand: { _, _ in })
        let container = ProcessListContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        container.configure(coordinator: coordinator, processPaneWidth: 430)
        coordinator.containerView = container
        coordinator.processHeaderView = container.processHeaderView
        coordinator.metricsHeaderView = container.metricsHeaderView
        coordinator.processRowsView = container.processRowsView
        coordinator.metricsRowsView = container.metricsRowsView
        coordinator.processBodyScrollView = container.processBodyScrollView
        coordinator.metricsHeaderScrollView = container.metricsHeaderScrollView
        coordinator.metricsBodyScrollView = container.metricsBodyScrollView
        coordinator.installScrollSync()
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let root = ProcessID(pid: 1, startTime: 1)
        var records = [root: ProcessRecord(id: root, parent: nil, name: "launchd")]
        for pid: Int32 in 2...500 {
            let id = ProcessID(pid: pid, startTime: 1)
            let name = pid == 400 ? "Finder" : pid == 450 ? "ProcexpMac" : String(repeating: "worker", count: 40)
            records[id] = ProcessRecord(id: id, parent: root, name: name)
        }
        let tree = ProcessTreeBuilder.build(from: records)
        let snapshot = ProcessSnapshot(timestamp: Date(), interval: 1, processes: records,
                                       roots: tree.roots, children: tree.children, system: .zero)

        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw RegressionFailure.failed(message) }
        }
        func update(_ query: String, treeMode: Bool = false, displayedColumns: [Column]? = nil,
                    newSnapshot: ProcessSnapshot? = nil) {
            let currentSnapshot = newSnapshot ?? snapshot
            model.snapshot = currentSnapshot
            coordinator.update(snapshot: currentSnapshot, columns: displayedColumns ?? columns,
                               colorRules: [], treeMode: treeMode, treeSortResetToken: 0,
                               searchText: query)
            container.layoutSubtreeIfNeeded()
        }
        func scrollDown() throws {
            update("")
            container.metricsBodyScrollView.contentView.scroll(to: NSPoint(x: 300, y: 7000))
            container.metricsBodyScrollView.reflectScrolledClipView(container.metricsBodyScrollView.contentView)
            container.processBodyScrollView.contentView.scroll(to: NSPoint(x: 100, y: 7000))
            try check(container.metricsBodyScrollView.contentView.bounds.minY > 6000,
                      "Fixture did not establish a deeply scrolled viewport")
        }
        func checkViewport(_ message: String) throws {
            let process = container.processBodyScrollView.contentView.bounds
            let metrics = container.metricsBodyScrollView.contentView.bounds
            try check(abs(process.minY - metrics.minY) < 0.5, "\(message): panes lost vertical synchronization")
            try check(abs(container.metricsHeaderScrollView.contentView.bounds.minX - metrics.minX) < 0.5,
                      "\(message): metrics header lost horizontal synchronization")
            for scrollView in [container.processBodyScrollView, container.metricsBodyScrollView] {
                let clip = scrollView.contentView.bounds
                guard let document = scrollView.documentView?.bounds else {
                    throw RegressionFailure.failed("\(message): missing document view")
                }
                try check(clip.minY >= 0 && clip.minY <= max(0, document.height - clip.height) + 0.5,
                          "\(message): vertical viewport is outside the document")
                try check(clip.minX >= 0 && clip.minX <= max(0, document.width - clip.width) + 0.5,
                          "\(message): horizontal viewport is outside the document")
            }
        }

        for treeMode in [false, true] {
            for query in ["Finder", "fInDeR", "Proc", "PROC", "400", "no-matching-process"] {
                try scrollDown()
                update(query, treeMode: treeMode)
                try checkViewport("\(query), tree=\(treeMode)")
                try check(container.metricsBodyScrollView.contentView.bounds.minY == 0,
                          "\(query): short filtered list should start at the top")
                let report = try coordinator.reportTable()
                if query == "no-matching-process" {
                    try check(report.rows.isEmpty, "Unmatched query returned rows")
                } else {
                    let expected = query.lowercased().contains("proc") ? "ProcexpMac" : "Finder"
                    try check(report.rows.contains { $0.first?.trimmingCharacters(in: .whitespaces) == expected },
                              "\(query): matching process is absent from rendered rows")
                }
                update("")
                try checkViewport("Clearing \(query)")
                print("PASS: \(query), tree=\(treeMode)")
            }
        }

        try scrollDown()
        let original = container.metricsBodyScrollView.contentView.bounds.origin
        update("")
        try check(container.metricsBodyScrollView.contentView.bounds.origin == original,
                  "An unchanged snapshot moved a valid viewport")
        let newID = ProcessID(pid: 501, startTime: 1)
        var grownRecords = records
        grownRecords[newID] = ProcessRecord(id: newID, parent: root, name: "new-worker")
        let grownTree = ProcessTreeBuilder.build(from: grownRecords)
        let grownSnapshot = ProcessSnapshot(timestamp: Date(), interval: 1, processes: grownRecords,
                                            roots: grownTree.roots, children: grownTree.children, system: .zero)
        update("", newSnapshot: grownSnapshot)
        try checkViewport("Document growth")
        try check(container.metricsBodyScrollView.contentView.bounds.origin == original,
                  "Document growth moved a valid viewport")
        window.setContentSize(NSSize(width: 1200, height: 600))
        container.layoutSubtreeIfNeeded()
        try checkViewport("Resizing")
        try check(abs(container.metricsBodyScrollView.contentView.bounds.minY - original.y) < 0.5,
                  "Resizing moved a still-valid vertical viewport")
        update("", displayedColumns: [.name, .pid])
        try checkViewport("Removing metric columns")
        try check(container.metricsBodyScrollView.contentView.bounds.minX == 0,
                  "Narrowed metric document retained an invalid horizontal offset")
        print("PASS: unchanged refresh, document growth, resize, column removal, and synchronized scroll preservation")
        print("All process-outline regressions passed.")
    }
}
