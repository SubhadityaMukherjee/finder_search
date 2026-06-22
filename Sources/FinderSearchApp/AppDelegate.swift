import AppKit
import SwiftUI
import SwiftData

/// Side channel for the SwiftUI `App` to hand the freshly constructed `AppState` to the
/// AppKit `AppDelegate`. SwiftUI instantiates the `AppDelegate` before the `App.init()`
/// body runs, so we cannot pass it through a constructor argument.
@MainActor
enum AppStateHolder {
    static var instance: AppState?
}

/// Owns the menu-bar status item outside SwiftUI's `MenuBarExtra` scene graph. On
/// macOS 27 the SwiftUI `MenuBarExtra` scene fails to deliver its status-item content
/// to the out-of-process `MenuBarAgent` (logged as
/// "No server elements for status item: nil"), so the icon never renders. Holding the
/// `NSStatusItem` ourselves and hosting the SwiftUI panel inside an `NSPopover`
/// sidesteps that bridge entirely.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState = AppStateHolder.instance else { return }
        setupStatusItem(appState: appState)
        // Bootstrap outside the SwiftUI scene tree so VectorStore / watcher are ready even
        // if the main window is never opened (e.g., user only uses the menu bar popover).
        Task { @MainActor in
            await appState.bootstrap()
        }
    }

    private func setupStatusItem(appState: AppState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "FinderSearch"
        )
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanel()
                .environment(appState)
                .modelContainer(appState.store.modelContainer)
        )

        self.statusItem = item
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover, button.window != nil else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
