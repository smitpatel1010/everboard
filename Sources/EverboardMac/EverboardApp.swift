import AppKit
import EverboardCore
import SwiftUI

@main
struct EverboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(unread: model.unread, unhealthy: model.health.values.contains { !$0.isHealthy && $0 != .idle },
                         meeting: model.config.calendarEnabled ? model.calendar.menuBarLabel : nil)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let unread: Int
    let unhealthy: Bool
    var meeting: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: unhealthy ? "square.grid.2x2.fill" : "square.grid.2x2")
            if unread > 0 { Text("\(min(unread, 99))") }
            if let meeting { Text("· \(meeting)") }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started as a login item → stay quietly in the menu bar; opened by hand → show the dashboard.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        MainActor.assumeIsolated {
            AppModel.shared.start()
            if !launchedAtLogin && !DemoData.isDemo && !CommandLine.arguments.contains("--show-palette") { AppModel.shared.showDashboard() }
        }
    }

    /// Double-clicking the app (or clicking it in Spotlight/Launchpad) while it's running reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showDashboard() }
        return true
    }
}

/// AppKit-managed dashboard window so it can be opened from notifications and the menu bar alike.
/// While it's open the app shows in the Dock and Cmd-Tab; when it closes we go back to menu-bar only.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    static let shared = DashboardWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = AppInfo.name
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DashboardView().environment(model))
            w.setFrameAutosaveName("EverboardDashboard")
            if !w.setFrameUsingName("EverboardDashboard") { w.center() }
            w.delegate = self
            w.minSize = NSSize(width: 820, height: 520)
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
