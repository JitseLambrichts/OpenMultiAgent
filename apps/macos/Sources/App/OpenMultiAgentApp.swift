import AppKit
import SwiftUI

/// Gives the sidecar a chance to exit cleanly; tmux sessions are untouched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (() async -> Void)?
    private var isShuttingDown = false

    /// Clicking the Dock icon with no window open creates a fresh main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// State restoration after an abnormal exit can finish without a visible
    /// window. Fall back to the "Nieuw venster" command so the app never
    /// launches into an empty menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            guard !hasVisibleWindow, let item = Self.menuItem(titled: "Nieuw venster", in: NSApp.mainMenu) else { return }
            _ = NSApp.sendAction(item.action ?? #selector(NSApplication.arrangeInFront(_:)), to: item.target, from: item)
        }
    }

    private static func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == title { return item }
            if let found = menuItem(titled: title, in: item.submenu) { return found }
        }
        return nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown, !isShuttingDown else { return .terminateNow }
        isShuttingDown = true
        Task { @MainActor in
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct OpenMultiAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { delegate.shutdown = { await model.shutdownSidecar() } }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(app: model)
        }
    }
}

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            Tab("Agents", systemImage: "terminal") {
                ScrollView {
                    AgentsSettingsView(app: app)
                        .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
        .frame(width: 560, height: 520)
    }
}
