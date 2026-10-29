import SwiftUI

struct ProcessExplorerHelpView: View {
    static let windowID = "process-explorer-help"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sysinternals Process Explorer Help").font(.title2.bold())
                topic("Find and inspect a process", """
                Filter by name or PID using the toolbar, or choose Find > Filter Processes. \
                Show Process Tree switches between a hierarchy and a flat list; sorting a column switches to a flat list. \
                View > Show Processes From All Users controls visibility, not access permissions.

                Find Window's Process on the toolbar lets you click another app's window. \
                It selects and reveals its process, clearing filters when needed. macOS may require Accessibility approval.
                """)
                topic("Save a report or export CSV", """
                File > Save (Command-S) writes the displayed columns and rows, including offscreen rows but excluding \
                filtered-out rows and collapsed descendants. It uses a tab-separated UTF-8 text report with a BOM and \
                CRLF line endings. When the lower pane is visible, the report also contains its current rows and columns. \
                Threads mode exports threads, not mapped images.

                The first Save asks for a filename. Later saves replace that file; Save As (Shift-Command-S) always \
                asks for a destination. The remembered destination lasts only for this app session. \
                A report captures the displayed data when Save is invoked, before the filename dialog.

                Export Process List as CSV is separate: it exports all sampled processes in PID order with fixed \
                raw-metric columns. Neither format is a reloadable snapshot. Reports may contain sensitive process names and paths.
                """)
                topic("Inspect the lower pane", """
                View > Lower Pane View selects mapped images/files, file descriptors, or threads. \
                Use its filter and column headers to configure the display. Double-click an image or descriptor \
                for details. The Lower Pane menu exposes existing actions for the selected row while the main window is active.

                Unavailable information is not a measured zero. Protected or exited processes can prevent enumeration. \
                A report cannot include a lower pane that has not loaded or has failed; hide it to save only the process list.
                """)
                topic("Control refresh and highlighting", """
                View > Update Speed controls sampling or pauses it. Refresh Now performs a single refresh. \
                Show Column Heatmaps controls resource shading independently of process row colors, which are in Settings > Colors.

                Scroll to New Processes is off by default. When enabled it reveals the first newly visible process \
                on a refresh without changing the selection. It does not repeatedly jump to the same process.
                """)
                topic("Menu-bar graphs and login", """
                Options > Menu Bar Graph selects CPU, physical memory, I/O, disk, network, or GPU history. \
                Only one graph is shown at a time. Throughput graphs scale to recent samples; CPU, memory, and GPU \
                use 0-100%. Unavailable data is shown as unavailable, not zero. GPU metrics depend on hardware and macOS support.

                Launch at Login registers only this app and only when you enable it. \
                macOS may require approval in System Settings > General > Login Items & Extensions. \
                Signing and installation restrictions may prevent registration in development builds.
                """)
                topic("Process actions and permissions", """
                Force Quit sends SIGKILL and can lose unsaved work. Suspend pauses a process until Resume. \
                Set Nice Value changes POSIX scheduling preference, not QoS or Windows priority classes. \
                Sample Process saves a ten-second text stack sample, not a memory dump.

                Install Privileged Helper is in the application menu. It requires a packaged, appropriately signed \
                app and macOS approval. The helper does not bypass all macOS process protections. \
                VirusTotal commands perform hash lookups; they do not upload executables.
                """)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func topic(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.body)
        }
    }
}
