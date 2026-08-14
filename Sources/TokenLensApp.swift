import AppKit
import SwiftUI

@MainActor
final class TokenLensAppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()

    private var islandController: IslandPanelController?
    private var dashboardWindowController: NSWindowController?
    private let chatGPTBundleIdentifier = "com.openai.codex"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard isChatGPTRunning else {
            NSApp.terminate(nil)
            return
        }

        ChatGPTContextTitleReader().requestAccessIfNeeded()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        let controller = IslandPanelController(store: store) { [weak self] in
            self?.showDashboard()
        }
        islandController = controller
        controller.start()
        store.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        islandController?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceApplicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isChatGPT(application) else { return }
        NSApp.terminate(nil)
    }

    private var isChatGPTRunning: Bool {
        NSWorkspace.shared.runningApplications.contains(where: isChatGPT)
    }

    private func isChatGPT(_ application: NSRunningApplication) -> Bool {
        guard application.bundleIdentifier == chatGPTBundleIdentifier else { return false }
        return application.bundleURL?.standardizedFileURL.path == "/Applications/ChatGPT.app"
            || application.localizedName == "ChatGPT"
    }

    func showDashboard() {
        let windowController: NSWindowController

        if let existing = dashboardWindowController {
            windowController = existing
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "TokenLens"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 960, height: 660)
            window.center()
            window.setFrameAutosaveName("TokenLensDashboardWindow")
            window.contentView = NSHostingView(rootView: DashboardWindowRoot(store: store))

            let created = NSWindowController(window: window)
            dashboardWindowController = created
            windowController = created
        }

        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
}

private struct DashboardWindowRoot: View {
    @ObservedObject var store: UsageStore
    @AppStorage("appearance") private var appearance = "dark"

    var body: some View {
        DashboardView(appearance: $appearance)
            .environmentObject(store)
            .preferredColorScheme(appearance == "light" ? .light : .dark)
    }
}

@main
struct TokenLensApp: App {
    @NSApplicationDelegateAdaptor(TokenLensAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
