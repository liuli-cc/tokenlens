// Standalone QA executable. It disables real refresh and never alters live
// notice state, preferences, sessions, credentials, or the installed app.
import AppKit
import Foundation

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore(refreshEnabled: false)
    private var controller: IslandPanelController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--deepseek") { store.setActiveAssistant(.deepSeek) }
        let controller = IslandPanelController(store: store, onOpenDetails: {}, onOpenCurrentAssistant: {})
        self.controller = controller
        controller.start()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let notice = TaskCompletionNotice(
                id: "preview-only", sessionID: "synthetic", turnID: "synthetic",
                title: "动画预览 · 本地合成样例", provider: "Preview", model: "Preview",
                source: self.store.activeAssistant == .deepSeek ? "DeepSeek Harness" : "Codex",
                usage: TokenUsage(inputTokens: 1000, outputTokens: 240, totalTokens: 1240),
                quotaUsedPercent: 0, costUSD: nil, startedAt: Date().addingTimeInterval(-10), completedAt: Date()
            )
            // Keep this unmistakably synthetic notice available through tool
            // round trips, without changing production's four-second timeout.
            for cycle in 0..<7 {
                controller.presentCompletionNotice(notice)
                if cycle < 6 { try? await Task.sleep(for: .seconds(3)) }
            }
            // The last presentation finishes naturally, leaving enough time
            // to inspect the return to the compact island before exit at 30 s.
            try? await Task.sleep(for: .seconds(10))
            controller.stop()
            NSApp.terminate(nil)
        }
    }
}

@main
struct IslandPreview {
    @MainActor static func main() {
        let delegate = PreviewDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
