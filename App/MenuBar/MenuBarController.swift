//
//  MenuBarController.swift
//  Live resource-history icon in the macOS menu bar.
//
//  Owns an `NSStatusItem` showing the selected native resource history.
//

import AppKit
import Observation
import ProcexpModel

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Icon size in points. Rendered ~22×18 like Procexp's tray graph.
    private let iconSize = NSSize(width: 22, height: 18)

    private weak var model: AppModel?
    private(set) var statusItem: NSStatusItem?
    private let menu = NSMenu()
    var onShowMainWindow: (() -> Void)?

    // Dynamic menu header items, rebuilt each time the menu opens.
    private let metricHeaderItem = NSMenuItem(title: "CPU: —", action: nil, keyEquivalent: "")
    private let topProcessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        buildMenu()
    }

    /// Connect the shared `AppModel` and begin observing it. Called once from
    /// the SwiftUI scene's `.task` after the model exists.
    func attach(model: AppModel) {
        self.model = model
        renderLoop()
    }

    // MARK: - Observation-driven render loop

    /// Re-render whenever any observable the render reads (cpuHistory,
    /// snapshot, showMenuBarGraph) changes. Re-registers after each change.
    private func renderLoop() {
        withObservationTracking { [weak self] in
            self?.render()
        } onChange: { [weak self] in
            // Hop to the next runloop tick so the new value is committed.
            Task { @MainActor [weak self] in self?.renderLoop() }
        }
    }

    private func render() {
        guard let model else { return }

        // Respect the enable/disable setting: tear the item down when off.
        guard model.showMenuBarGraph else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }

        let item = ensureStatusItem()
        let values = model.menuBarMetric.values(in: model)
        let currentCPU = model.cpuHistory.latest ?? model.snapshot.system.cpuTotalPercent
        let busiest = busiestProcess(in: model)

        if let button = item.button {
            button.image = makeGraphImage(from: values, maximum: model.menuBarMetric.maximum(for: values))
            button.toolTip = model.menuBarMetric == .cpu
                ? tooltip(cpu: currentCPU, busiest: busiest)
                : model.menuBarMetric.readout(values.last)
            button.setAccessibilityLabel("\(model.menuBarMetric.title) history")
        }
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem { return statusItem }
        let item = NSStatusBar.system.statusItem(withLength: iconSize.width + 6)
        item.button?.setAccessibilityIdentifier("menu-bar-cpu-graph")
        item.button?.imageScaling = .scaleNone
        item.menu = menu
        statusItem = item
        return item
    }

    // MARK: - Icon drawing

    /// Draw a small green strip-chart of CPU history onto an `NSImage`.
    private func makeGraphImage(from history: [Double], maximum: Double) -> NSImage {
        let size = iconSize
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(origin: .zero, size: size)

        // Dark background, subtle border — Procexp's tray look.
        NSColor.black.setFill()
        bounds.fill()
        NSColor(white: 0.30, alpha: 1).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        guard !history.isEmpty else {
            image.isTemplate = false
            return image
        }

        // One bar per horizontal point; keep only the most recent samples.
        let maxBars = Int(size.width) - 2
        let samples = Array(history.suffix(maxBars))
        let inset: CGFloat = 1
        let plot = bounds.insetBy(dx: inset, dy: inset)
        let barWidth = plot.width / CGFloat(max(samples.count, 1))

        NSColor.systemGreen.setFill()
        for (i, value) in samples.enumerated() {
            guard value.isFinite else { continue }
            let clamped = min(max(value, 0), maximum) / maximum
            let barHeight = CGFloat(clamped) * plot.height
            let rect = NSRect(
                x: plot.minX + CGFloat(i) * barWidth,
                y: plot.minY,
                width: max(barWidth, 1),
                height: barHeight
            )
            NSBezierPath(rect: rect).fill()
        }

        image.isTemplate = false
        return image
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        metricHeaderItem.isEnabled = false
        topProcessItem.isEnabled = false

        menu.addItem(metricHeaderItem)
        menu.addItem(topProcessItem)
        menu.addItem(.separator())

        let show = NSMenuItem(
            title: "Show Sysinternals Process Explorer",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)

        let toggle = NSMenuItem(
            title: "Show Graph in Menu Bar",
            action: #selector(toggleMenuBarGraph),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)

        let graphItem = NSMenuItem(title: "Graph", action: nil, keyEquivalent: "")
        let graphMenu = NSMenu(title: "Graph")
        for metric in MenuBarMetric.allCases {
            let item = NSMenuItem(title: metric.title, action: #selector(selectMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            graphMenu.addItem(item)
        }
        graphItem.submenu = graphMenu
        menu.addItem(graphItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Sysinternals Process Explorer",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    /// Refresh the dynamic header/toggle each time the menu is opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        let currentCPU = model.cpuHistory.latest ?? model.snapshot.system.cpuTotalPercent
        metricHeaderItem.title = model.menuBarMetric.readout(
            model.menuBarMetric == .cpu ? currentCPU : model.menuBarMetric.values(in: model).last
        )

        if model.menuBarMetric == .cpu, let busiest = busiestProcess(in: model) {
            topProcessItem.title = String(format: "Busiest: %@ (%.1f%%)", busiest.name, busiest.cpuPercent)
            topProcessItem.isHidden = false
        } else {
            topProcessItem.isHidden = true
        }

        if let toggle = menu.item(withTitle: "Show Graph in Menu Bar") {
            toggle.state = model.showMenuBarGraph ? .on : .off
        }
        for item in menu.item(withTitle: "Graph")?.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == model.menuBarMetric.rawValue ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        onShowMainWindow?()
    }

    @objc private func toggleMenuBarGraph() {
        guard let model else { return }
        model.showMenuBarGraph.toggle()
    }

    @objc private func selectMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let metric = MenuBarMetric(rawValue: raw) else { return }
        model?.menuBarMetric = metric
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func busiestProcess(in model: AppModel) -> ProcessRecord? {
        model.snapshot.processes.values.max { $0.cpuPercent < $1.cpuPercent }
    }

    private func tooltip(cpu: Double, busiest: ProcessRecord?) -> String {
        var text = cpu.isFinite ? String(format: "CPU: %.1f%%", cpu) : "CPU: Unavailable"
        if let busiest {
            text += String(format: " — busiest: %@ (%.1f%%)", busiest.name, busiest.cpuPercent)
        }
        return text
    }
}
