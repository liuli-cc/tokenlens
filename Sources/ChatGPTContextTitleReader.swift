import AppKit
import ApplicationServices
import CoreGraphics

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

            if let sidebarTitle = sidebarConversationTitle(in: appElement) {
                return sidebarTitle
            }

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

            if let chromeTitle = chromeConversationTitle(in: appElement) {
                return chromeTitle
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

    /// ChatGPT's native window title is often just "ChatGPT". The desktop
    /// client exposes the conversation name as a static text element in its
    /// top toolbar, so inspect only that small chrome region and never the
    /// message body.
    private func chromeConversationTitle(in appElement: AXUIElement) -> String? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }

        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        guard let windowFrame = frame(of: window) else { return nil }
        var best: (title: String, distance: CGFloat)?
        collectChromeTitles(
            in: window,
            windowFrame: windowFrame,
            depth: 0,
            best: &best
        )
        return best?.title
    }

    /// The active conversation is exposed by ChatGPT's left navigation rail.
    /// Prefer an AX-selected row and constrain traversal to the left 380pt of
    /// the window so message content can never become a title candidate.
    private func sidebarConversationTitle(in appElement: AXUIElement) -> String? {
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
            guard let windowFrame = frame(of: window) else { continue }
            let sidebarMaxX = windowFrame.minX + min(380, max(280, windowFrame.width * 0.36))
            var selectedBest: (title: String, y: CGFloat)?
            var fallbackBest: (title: String, y: CGFloat)?
            collectSidebarTitles(
                in: window,
                windowFrame: windowFrame,
                sidebarMaxX: sidebarMaxX,
                depth: 0,
                selectedAncestor: false,
                selectedBest: &selectedBest,
                fallbackBest: &fallbackBest
            )
            if let selectedBest { return selectedBest.title }
            if let fallbackBest { return fallbackBest.title }
        }
        return nil
    }

    private func collectSidebarTitles(
        in element: AXUIElement,
        windowFrame: CGRect,
        sidebarMaxX: CGFloat,
        depth: Int,
        selectedAncestor: Bool,
        selectedBest: inout (title: String, y: CGFloat)?,
        fallbackBest: inout (title: String, y: CGFloat)?
    ) {
        guard depth <= 8 else { return }

        let elementFrame = frame(of: element)
        if let elementFrame,
           (elementFrame.minX > sidebarMaxX || elementFrame.maxX > sidebarMaxX + 24) {
            return
        }

        let selected = selectedAncestor || boolAttribute(kAXSelectedAttribute, from: element)
        if let role = stringAttribute(kAXRoleAttribute, from: element),
           ["AXRow", "AXCell", "AXStaticText", "AXLink", "AXButton"].contains(role),
           let rawTitle = stringAttribute(kAXTitleAttribute, from: element) ?? stringAttribute(kAXValueAttribute, from: element),
           let title = normalizedSidebarTitle(rawTitle),
           let elementFrame,
           elementFrame.minY > windowFrame.minY + 48 {
            if selected {
                if selectedBest == nil || elementFrame.minY > selectedBest!.y {
                    selectedBest = (title, elementFrame.minY)
                }
            } else if fallbackBest == nil || elementFrame.minY > fallbackBest!.y {
                fallbackBest = (title, elementFrame.minY)
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else { return }

        for child in children {
            collectSidebarTitles(
                in: child,
                windowFrame: windowFrame,
                sidebarMaxX: sidebarMaxX,
                depth: depth + 1,
                selectedAncestor: selected,
                selectedBest: &selectedBest,
                fallbackBest: &fallbackBest
            )
        }
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    private func normalizedSidebarTitle(_ raw: String) -> String? {
        let title = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let navigationLabels = [
            "chatgpt", "codex", "tokenlens", "openai", "新对话", "new chat",
            "拉取请求", "站点", "已安排", "插件", "项目", "设置", "帮助",
            "搜索", "通知", "展开显示", "展开", "收起", "更多"
        ]
        guard title.count >= 2,
              title.count <= 120,
              !navigationLabels.contains(title.lowercased()) else { return nil }
        return title
    }

    private func collectChromeTitles(
        in element: AXUIElement,
        windowFrame: CGRect,
        depth: Int,
        best: inout (title: String, distance: CGFloat)?
    ) {
        guard depth <= 5 else { return }

        if let elementFrame = frame(of: element) {
            let distanceFromTop = windowFrame.maxY - elementFrame.maxY
            if distanceFromTop >= -12 && distanceFromTop <= 140,
               let role = stringAttribute(kAXRoleAttribute, from: element),
               ["AXStaticText", "AXButton", "AXLink"].contains(role),
               let rawTitle = stringAttribute(kAXTitleAttribute, from: element) ?? stringAttribute(kAXValueAttribute, from: element),
               let title = normalizedChromeTitle(rawTitle),
               best == nil || distanceFromTop < best!.distance {
                best = (title, distanceFromTop)
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else { return }

        for child in children {
            collectChromeTitles(
                in: child,
                windowFrame: windowFrame,
                depth: depth + 1,
                best: &best
            )
        }
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func normalizedChromeTitle(_ raw: String) -> String? {
        let title = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let genericTitles = [
            "chatgpt", "codex", "tokenlens", "openai", "new chat", "新对话",
            "chatgpt desktop", "制作 codex ai 使用监测助手"
        ]
        guard title.count >= 2,
              title.count <= 100,
              !genericTitles.contains(title.lowercased()) else { return nil }
        return title
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
