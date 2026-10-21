//
//  AppDelegate.swift
//  W10 — hosts the menu-bar CPU-history status item alongside the SwiftUI
//  scenes. Attached via `@NSApplicationDelegateAdaptor` in `ProcexpApp`.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the live CPU-history `NSStatusItem`. Wired to the shared model by
    /// the main scene once it exists (see `ProcexpApp`).
    let menuBar = MenuBarController()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = ProcexpApp.sharedModel
        attach(model: model)
        showMainWindow()
        removeHelpMenu()
        Task { await model.start() }
    }

    /// AppKit injects a top-level "Help" menu automatically. Remove it so the
    /// menu bar matches Windows Process Explorer, which has no Help menu.
    private func removeHelpMenu() {
        NSApp.helpMenu = nil
        if let help = NSApp.mainMenu?.items.first(where: { $0.title == "Help" }) {
            NSApp.mainMenu?.removeItem(help)
        }
    }

    /// SwiftUI re-adds the default Help menu whenever it rebuilds the menu bar,
    /// so strip it on every update cycle to keep it hidden.
    func applicationDidUpdate(_ notification: Notification) {
        if let help = NSApp.mainMenu?.items.first(where: { $0.title == "Help" }) {
            NSApp.mainMenu?.removeItem(help)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Called from the SwiftUI scene's `.task` to hand the delegate the shared
    /// `AppModel`, which it then observes to drive the menu-bar graph.
    func attach(model: AppModel) {
        menuBar.onShowMainWindow = { [weak self] in self?.showMainWindow() }
        menuBar.attach(model: model)
    }

    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        window.isReleasedWhenClosed = false
        mainWindow = window
        Task { @MainActor [weak self] in self?.showMainWindow() }
    }

    private func showMainWindow() {
        guard let mainWindow else { return }
        if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
