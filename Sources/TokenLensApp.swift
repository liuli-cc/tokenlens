import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class TokenLensAppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()

    private var islandController: IslandPanelController?
    private var dashboardWindowController: NSWindowController?
    private var foregroundPollingTimer: Timer?
    private let chatGPTBundleIdentifier = "com.openai.codex"
    private let deepSeekBundleIdentifier = "com.deepseek.dsh"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard isAssistantRunning else {
            NSApp.terminate(nil)
            return
        }

        synchronizeActiveAssistant()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        foregroundPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.synchronizeActiveAssistant()
            }
        }

        let controller = IslandPanelController(
            store: store,
            onOpenDetails: { [weak self] in
                self?.showDashboard()
            },
            onOpenCurrentAssistant: { [weak self] in
                self?.openCurrentAssistant()
            }
        )
        islandController = controller
        controller.start()
        store.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        foregroundPollingTimer?.invalidate()
        foregroundPollingTimer = nil
        islandController?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceApplicationTerminated(_ notification: Notification) {
    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let terminatedAssistant = assistant(for: application) else { return }
        guard isAssistantRunning else {
            NSApp.terminate(nil)
            return
        }
        if store.activeAssistant == terminatedAssistant {
            store.setActiveAssistant(terminatedAssistant == .chatGPT ? .deepSeek : .chatGPT)
        }
    }

    @objc private func workspaceApplicationActivated(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let activeAssistant = assistant(for: application) {
            store.setActiveAssistant(activeAssistant)
        } else {
            synchronizeActiveAssistant()
        }
    }

    private func synchronizeActiveAssistant() {
        if let frontmostAssistant = assistant(for: NSWorkspace.shared.frontmostApplication) {
            store.setActiveAssistant(frontmostAssistant)
        } else if isDeepSeekRunning && !isChatGPTRunning {
            store.setActiveAssistant(.deepSeek)
        } else if isChatGPTRunning && !isDeepSeekRunning {
            store.setActiveAssistant(.chatGPT)
        }
    }

    private var isChatGPTRunning: Bool {
        NSWorkspace.shared.runningApplications.contains(where: isChatGPT)
    }

    private var isDeepSeekRunning: Bool {
        NSWorkspace.shared.runningApplications.contains(where: isDeepSeek)
    }

    private var isAssistantRunning: Bool {
        isChatGPTRunning || isDeepSeekRunning
    }

    private func isChatGPT(_ application: NSRunningApplication) -> Bool {
        let bundlePath = application.bundleURL?.standardizedFileURL.path ?? ""
        return application.bundleIdentifier == chatGPTBundleIdentifier
            || bundlePath.hasPrefix("/Applications/ChatGPT.app/")
            || application.localizedName?.hasPrefix("ChatGPT") == true
    }

    private func isDeepSeek(_ application: NSRunningApplication) -> Bool {
        let bundlePath = application.bundleURL?.standardizedFileURL.path ?? ""
        return application.bundleIdentifier == deepSeekBundleIdentifier
            || bundlePath.hasPrefix("/Applications/DeepSeek Harness.app/")
            || application.localizedName?.hasPrefix("DeepSeek Harness") == true
    }

    private func assistant(for application: NSRunningApplication?) -> IslandAssistant? {
        guard let application else { return nil }
        if isChatGPT(application) { return .chatGPT }
        if isDeepSeek(application) { return .deepSeek }
        return nil
    }

    private func openCurrentAssistant() {
        switch store.activeAssistant {
        case .chatGPT:
            Self.openChatGPT()
        case .deepSeek:
            Self.openDeepSeek()
        }
    }

    static func openChatGPT() {
        let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.codex"
        })

        if let runningApplication {
            runningApplication.unhide()
            _ = restoreOrRaiseChatGPTWindows(for: runningApplication)
            runningApplication.activate(options: [.activateAllWindows])
        }

        guard let applicationURL = runningApplication?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = true
        if let runningApplication {
            let target = NSAppleEventDescriptor(processIdentifier: runningApplication.processIdentifier)
            let reopenEvent = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            _ = try? reopenEvent.sendEvent(options: [.noReply], timeout: 1)
            configuration.appleEvent = reopenEvent
        }
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { application, _ in
            Task { @MainActor in
                guard let application else { return }
                application.unhide()
                _ = restoreOrRaiseChatGPTWindows(for: application)
                application.activate(options: [.activateAllWindows])
            }
        }
    }

    static func openDeepSeek() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.deepseek.dsh") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, _ in
            application?.unhide()
            application?.activate(options: [.activateAllWindows])
        }
    }

    private static func restoreOrRaiseChatGPTWindows(for application: NSRunningApplication) -> Bool {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement],
        !windows.isEmpty else { return false }

        for window in windows {
            var rawMinimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                &rawMinimized
            ) == .success,
            let isMinimized = rawMinimized as? Bool,
            isMinimized {
                AXUIElementSetAttributeValue(
                    window,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
            }
        }

        if let firstWindow = windows.first {
            AXUIElementSetAttributeValue(
                firstWindow,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
        }
        return true
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
