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
        if CommandLine.arguments.contains("--click-self-test") {
            do {
                try runClickSelfTest()
                NSApp.terminate(nil)
            } catch {
                print("Synthetic camera click self-test failed: \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
            return
        }
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

    private func runClickSelfTest() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "IslandClickSelfTest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw NSError(domain: "IslandClickSelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No AppKit screen is available"])
        }
        let suiteName = "cn.liuli.tokenlens.preview.click." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IslandPreferences(defaults: defaults)
        preferences.followSystemMotion = false
        var opened: [IslandAssistant] = []
        let controller = IslandPanelController(store: store, onOpenDetails: {},
            onOpenAssistant: { opened.append($0) }, preferences: preferences)
        controller.start()
        defer { controller.stop() }

        // Geometry stays deterministic even on an external display. This is a
        // synthetic cutout, not a claim that the hardware has been clicked.
        let band: CGFloat = 33.5
        let camera = CGRect(x: screen.frame.midX - 92.5,
                            y: screen.frame.maxY - band, width: 185, height: band)
        let layout = IslandLayout(screen: screen.frame, camera: camera,
            bandHeight: band, anchorX: camera.midX, leftWing: 108, rightWing: 82)
        controller.previewSetLayout(layout)
        let center = CGPoint(x: camera.midX, y: camera.midY)

        func event(_ type: CGEventType, at point: CGPoint) throws -> NSEvent {
            let quartz = CGPoint(x: point.x - primary.frame.minX,
                                 y: primary.frame.maxY - point.y)
            let button: CGMouseButton = type == .rightMouseDown ? .right : .left
            guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: quartz, mouseButton: button),
                let event = NSEvent(cgEvent: cgEvent) else {
                throw NSError(domain: "IslandClickSelfTest", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not construct a synthetic mouse event"])
            }
            return event
        }
        var cases = 0
        func route(_ type: CGEventType, at point: CGPoint,
                   expected: IslandAssistant?, label: String) throws {
            let previousCount = opened.count
            let handled = controller.previewHandlePointerEvent(try event(type, at: point))
            try check(handled == (expected != nil), "Unexpected event handling: " + label)
            try check(opened.count == previousCount + (expected != nil ? 1 : 0),
                      "Activation count is not exactly one or zero: " + label)
            if let expected {
                try check(opened.last == expected, "Wrong assistant opened: " + label)
            }
            cases += 1
        }

        store.setActiveAssistant(.chatGPT)
        for (point, label) in [
            (center, "camera center"),
            (CGPoint(x: camera.midX, y: camera.maxY), "screen upper edge"),
            (CGPoint(x: camera.minX, y: camera.midY), "camera left boundary"),
            (CGPoint(x: camera.maxX, y: camera.midY), "camera right boundary"),
            (CGPoint(x: camera.midX, y: camera.minY), "camera bottom boundary")
        ] {
            try route(.leftMouseDown, at: point, expected: .chatGPT, label: label)
        }
        for (point, label) in [
            (CGPoint(x: camera.midX, y: camera.minY - 0.25), "below camera"),
            (CGPoint(x: camera.minX - 0.25, y: camera.midY), "left wing"),
            (CGPoint(x: camera.maxX + 0.25, y: camera.midY), "right wing"),
            (CGPoint(x: camera.midX, y: camera.maxY + 0.25), "above screen")
        ] {
            try route(.leftMouseDown, at: point, expected: nil, label: label)
        }
        for (type, label) in [(CGEventType.mouseMoved, "mouse move"),
                              (.rightMouseDown, "right click"),
                              (.leftMouseDragged, "drag"), (.leftMouseUp, "mouse release")] {
            try route(type, at: center, expected: nil, label: label)
        }
        for assistant in IslandAssistant.allCases {
            store.setActiveAssistant(assistant)
            try route(.leftMouseDown, at: center, expected: assistant,
                      label: "current assistant " + assistant.rawValue)
        }

        store.setActiveAssistant(.chatGPT)
        let notice = TaskCompletionNotice(
            id: "synthetic-camera-routing-dsh", sessionID: "synthetic", turnID: "synthetic",
            title: "本地合成 · 摄像头点击路由检查", provider: "Preview", model: "Preview",
            source: "DeepSeek Harness", usage: TokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12),
            quotaUsedPercent: nil, costUSD: nil, startedAt: Date().addingTimeInterval(-1), completedAt: Date()
        )
        controller.presentCompletionNotice(notice)
        try check(controller.previewCompletionNoticeID == notice.id, "Synthetic DSH notice was not presented")
        try route(.mouseMoved, at: center, expected: nil, label: "mouse move while DSH notice is present")
        try route(.rightMouseDown, at: center, expected: nil, label: "right click while DSH notice is present")
        try check(controller.previewCompletionNoticeID == notice.id,
                  "A non-activation event dismissed the completion notice")
        try route(.leftMouseDown, at: center, expected: .deepSeek, label: "DSH completion while GPT is current")
        try check(controller.previewCompletionNoticeID == nil, "Camera click did not dismiss the completion notice")
        try route(.leftMouseDown, at: center, expected: .chatGPT, label: "current assistant after notice dismissal")

        let external = IslandGeometry.layout(screen: screen.frame, safeTopInset: 0,
            leftAux: nil, rightAux: nil)
        controller.previewSetLayout(external)
        try route(.leftMouseDown, at: center, expected: nil, label: "no-camera display")
        print("Synthetic native camera click self-test passed: \(cases) routing cases, camera edges, five assistants, DSH notice priority and no-camera display. No events posted; no hardware click claimed.")
        fflush(stdout)
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
