import AppKit
import ApplicationServices

@MainActor
struct ChatGPTContextTitleReader {
    private let chatGPTBundleIdentifier = "com.openai.codex"

    func requestAccessIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func currentTitle() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let applications = NSWorkspace.shared.runningApplications.filter(isChatGPT)

        for application in applications {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                var windowValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    appElement,
                    attribute as CFString,
                    &windowValue
                ) == .success,
                let windowValue,
                CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { continue }
                let window = unsafeDowncast(windowValue, to: AXUIElement.self)

                var titleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    window,
                    kAXTitleAttribute as CFString,
                    &titleValue
                ) == .success,
                let title = titleValue as? String,
                let normalized = normalizedTitle(title) else { continue }

                return normalized
            }
        }

        return nil
    }

    private func isChatGPT(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier == chatGPTBundleIdentifier
            || application.bundleURL?.standardizedFileURL.path == "/Applications/ChatGPT.app"
            || application.localizedName == "ChatGPT"
            || application.localizedName == "Codex"
    }

    private func normalizedTitle(_ raw: String) -> String? {
        let title = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let genericTitles = ["chatgpt", "codex", "tokenlens"]
        guard !title.isEmpty,
              !genericTitles.contains(title.lowercased()) else { return nil }
        return title
    }
}
