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
        for assistant in IslandAssistant.allCases {
            if CommandLine.arguments.contains("--\(assistant.rawValue.lowercased())") { store.setActiveAssistant(assistant) }
        }
        let preferences = IslandPreferences(defaults: UserDefaults(suiteName: "cn.liuli.tokenlens.preview.ephemeral")!)
        preferences.followSystemMotion = CommandLine.arguments.contains("--reduce-motion")
        let controller = IslandPanelController(store: store, onOpenDetails: {}, onOpenAssistant: { _ in }, preferences: preferences)
        self.controller = controller
        controller.start()
        Task { @MainActor in
            let args = CommandLine.arguments
            let export = args.firstIndex(of: "--export").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil }
            if let export { try? FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
            try? await Task.sleep(for: .milliseconds(600))
            let sequence: [IslandAssistant] = args.contains("--all") ? IslandAssistant.allCases : [self.store.activeAssistant]
            var frame = 0
            var diagnostics: [[String: Any]] = []
            for assistant in sequence {
                self.store.setActiveAssistant(assistant)
                let notice = TaskCompletionNotice(
                    id: "preview-" + assistant.rawValue, sessionID: "synthetic", turnID: "synthetic",
                    title: "本地合成 · 果冻动效预览", provider: "Preview", model: "Preview",
                    source: assistant == .chatGPT ? "Codex" : assistant.displayName,
                    usage: TokenUsage(inputTokens: 1000, outputTokens: 240, totalTokens: 1240),
                    quotaUsedPercent: nil, costUSD: nil, startedAt: Date().addingTimeInterval(-10), completedAt: Date()
                )
                controller.presentCompletionNotice(notice)
                for tick in 0..<96 {
                    if export != nil { controller.previewStep(elapsed: Double(tick) / 30, by: 1 / 30) }
                    if let export {
                        var state = controller.previewDiagnostics()
                        state["assistant"] = assistant.rawValue
                        state["elapsed"] = Double(tick) / 30
                        diagnostics.append(state)
                        try? controller.previewCapture(to: export.appendingPathComponent(String(format: "frame-%04d.png", frame)))
                        if tick == 22 { try? controller.previewCapture(to: export.appendingPathComponent(assistant.rawValue + ".png")) }
                    }
                    if let export, tick == 80 {
                        try? controller.previewCapture(to: export.appendingPathComponent(assistant.rawValue + "-held.png"))
                    }
                    frame += 1
                    try? await Task.sleep(for: .milliseconds(export != nil ? 16 : 33))
                }
                // Preview test code operates only its synthetic controller.
                // The production FIFO is never filled with sample events.
                if export != nil {
                    controller.previewCloseNotice()
                    controller.previewReset()
                    // A unique next sample is allowed to replace this synthetic
                    // presentation, while production notices are serialized.
                }
            }
            if let export {
                if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: export.appendingPathComponent("motion-diagnostics.json"))
                }
                // Let the final notice close naturally before capturing tools.
                try? await Task.sleep(for: .milliseconds(600))
                for (page, name) in [(IslandPage.overview, "overview"), (.history, "history"), (.settings, "settings")] {
                    controller.previewPage(page)
                    try? await Task.sleep(for: .milliseconds(800))
                    try? controller.previewCapture(to: export.appendingPathComponent(name + ".png"))
                }
                print("Synthetic native preview exported: \(frame) frames, five palettes and three panels")
                fflush(stdout)
            } else {
                try? await Task.sleep(for: .seconds(8))
            }
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
