import AppKit
import ApplicationServices
import Foundation
import CryptoKit

/// Reads only the model/usage controls that Claude itself displays in any of its windows. Never
/// requests permission, activates Claude, clicks controls or reads text values.
enum ClaudeDesktopTelemetry {
    struct Visible: Sendable {
        var model: String?
        var usedPercent: Double?
        var weeklyUsedPercent: Double?
        var surfaceKey: String?
        var accessibilityTrusted = false
    }

    @MainActor
    static func read() async -> Visible {
        guard AXIsProcessTrusted() else { return Visible() }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == "com.anthropic.claudefordesktop" && $0.activationPolicy != .prohibited
              }) else { return Visible(accessibilityTrusted: true) }
        let pid = app.processIdentifier
        return await Task.detached(priority: .utility) { read(processID: pid) }.value
    }

    private static func read(processID: pid_t) -> Visible {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.025)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        // The usage control can sit in a background window (for example a chat
        // window while a Code tab is focused), so every window is scanned with
        // the focused one first. Values from one window keep that window's key.
        var windows: [AXUIElement] = []
        if let raw = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            windows.append(unsafeDowncast(raw, to: AXUIElement.self))
        }
        for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            where !windows.contains(where: { CFEqual($0, window) }) {
            windows.append(window)
        }
        let deadline = Date().addingTimeInterval(1.0)
        var result = Visible(accessibilityTrusted: true)
        for window in windows.prefix(8) where Date() < deadline {
            let found = scan(window, deadline: deadline, attribute: attribute)
            if result.model == nil { result.model = found.model }
            if result.surfaceKey == nil { result.surfaceKey = found.surfaceKey }
            guard found.usedPercent != nil || found.weeklyUsedPercent != nil,
                  result.usedPercent == nil && result.weeklyUsedPercent == nil else { continue }
            result.usedPercent = found.usedPercent
            result.weeklyUsedPercent = found.weeklyUsedPercent
            result.surfaceKey = found.surfaceKey
        }
        return result
    }

    private static func scan(_ window: AXUIElement, deadline: Date,
                             attribute: (AXUIElement, String) -> CFTypeRef?) -> Visible {
        var pending = [window]
        var visited = 0
        var result = Visible(accessibilityTrusted: true)
        while let element = pending.popLast(), visited < 800, Date() < deadline {
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            // Do not inspect message text, prompts, file contents or tool output.
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(role) { continue }
            if role == "AXWebArea", let url = attribute(element, kAXURLAttribute) as? URL,
               url.host == "claude.ai" {
                // Cache scope changes with the visible conversation. Only an
                // opaque digest is kept; no account or conversation URL is saved.
                result.surfaceKey = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            if role == "AXLevelIndicator" {
                for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let label = attribute(element, key) as? String else { continue }
                    if let weekly = weeklyPercentage(label: label, value: attribute(element, kAXValueAttribute)) {
                        result.weeklyUsedPercent = weekly
                    }
                }
            }
            if role == kAXPopUpButtonRole {
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                    guard let label = attribute(element, key) as? String else { continue }
                    let parsed = parseControl(label)
                    if let model = parsed.model { result.model = model }
                    if let used = parsed.usedPercent { result.usedPercent = used }
                }
                if result.model != nil && result.usedPercent != nil && result.weeklyUsedPercent != nil { break }
            }
            if role == kAXGroupRole {
                let label = attribute(element, kAXDescriptionAttribute) as? String ?? ""
                if ["对话消息", "Chat messages", "Conversation messages"].contains(label) { continue }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(800))
            }
        }
        return result
    }

    static func weeklyPercentage(label: String, value: Any?) -> Double? {
        // Model-specific weekly limits (e.g. Sonnet) are different buckets.
        guard label.range(of: #"^(?:每周\s*[·•]?\s*所有模型|Weekly\s*[·•:—-]?\s*All models)$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil,
              let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }

    static func parseControl(_ label: String) -> Visible {
        guard label.count <= 300 else { return Visible() }
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let range = Range(match.range(at: 1), in: label) else { return nil }
            return String(label[range])
        }
        let model = capture(#"^(?:模型[：:]|Model:)\s*((?:Claude\s+)?(?:Opus|Sonnet|Haiku)\s+\d+(?:\.\d+)*(?:\s*\([^)]*\))?)"#)
        let used = capture(#"^(?:用量[：:]已使用会话限额的\s*|Usage:\s*(?:You have used\s*)?)(\d+(?:\.\d+)?)%"#).flatMap(Double.init)
        return Visible(model: model, usedPercent: used.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil })
    }
}
