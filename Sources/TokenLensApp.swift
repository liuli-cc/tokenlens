import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class TokenLensAppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()

    private var islandController: IslandPanelController?
    private var dashboardWindowController: NSWindowController?
    private var foregroundPollingTimer: Timer?

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
        if store.activeAssistant == terminatedAssistant { synchronizeActiveAssistant() }
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
        let selection = IslandAssistant.selected(
            frontmost: assistant(for: NSWorkspace.shared.frontmostApplication),
            previous: store.activeAssistant,
            running: runningAssistants
        )
        if let selection { store.setActiveAssistant(selection) }
    }

    private var runningAssistants: Set<IslandAssistant> {
        Set(NSWorkspace.shared.runningApplications.compactMap { application in
            // Background Electron helpers can survive their main app briefly.
            // They do not keep an island alive after the user quits that app.
            guard application.activationPolicy != .prohibited else { return nil }
            return assistant(for: application)
        })
    }

    private var isAssistantRunning: Bool {
        !runningAssistants.isEmpty
    }

    private func assistant(for application: NSRunningApplication?) -> IslandAssistant? {
        guard let application else { return nil }
        return IslandAssistant.matching(
            bundleIdentifier: application.bundleIdentifier,
            bundlePath: application.bundleURL?.standardizedFileURL.path,
            localizedName: application.localizedName
        )
    }

    private func openCurrentAssistant() {
        Self.openAssistant(store.activeAssistant)
    }

    static func openChatGPT() {
        let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.codex"
        })

        if let runningApplication {
            runningApplication.unhide()
            _ = restoreOrRaiseAssistantWindows(for: runningApplication)
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
                _ = restoreOrRaiseAssistantWindows(for: application)
                application.activate(options: [.activateAllWindows])
            }
        }
    }

    static func openDeepSeek() {
        openAssistant(.deepSeek)
    }

    static func openAssistant(_ assistant: IslandAssistant) {
        // Preserve the existing Codex reopen event for closed/minimized windows.
        if assistant == .chatGPT { openChatGPT(); return }
        let runningApplication = NSWorkspace.shared.runningApplications.first {
            assistant.bundleIdentifiers.contains($0.bundleIdentifier ?? "")
        }
        if let runningApplication {
            runningApplication.unhide()
            _ = restoreOrRaiseAssistantWindows(for: runningApplication)
            runningApplication.activate(options: [.activateAllWindows])
        }
        guard let applicationURL = runningApplication?.bundleURL
            ?? assistant.bundleIdentifiers.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, _ in
            Task { @MainActor in
                guard let application else { return }
                application.unhide()
                _ = restoreOrRaiseAssistantWindows(for: application)
                application.activate(options: [.activateAllWindows])
            }
        }
    }

    private static func restoreOrRaiseAssistantWindows(for application: NSRunningApplication) -> Bool {
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
