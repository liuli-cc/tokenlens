import AppKit
import ApplicationServices

struct MenuBarOccupancySnapshot: Sendable {
    let rectangles: [CGRect]
    let accessibilityTrusted: Bool
    let windowItems: Int
    let accessibilityItems: Int
    var needsConservativeWings: Bool { !accessibilityTrusted || accessibilityItems == 0 }
}

struct MenuBarOccupancy: Sendable {
    /// Read only, never requests Accessibility or Screen Recording permission.
    /// AppKit and AX use opposite Y axes; both share the primary display origin.
    static func read(processIDs: [pid_t], frontmostPID: pid_t?, primaryTop: CGFloat, excludedPIDs: Set<pid_t>) -> MenuBarOccupancySnapshot {
        var rects: [CGRect] = []
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for row in windows {
                guard let layer = row[kCGWindowLayer as String] as? Int,
                      let ownerPID = row[kCGWindowOwnerPID as String] as? pid_t,
                      let raw = row[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                      isCandidate(bounds: rect, layer: layer, ownerPID: ownerPID, excludedPIDs: excludedPIDs),
                      !(row[kCGWindowOwnerName as String] as? String ?? "").hasPrefix("TokenLens") else { continue }
                rects.append(flip(rect, primaryTop: primaryTop))
            }
        }
        let windowItems = rects.count
        guard AXIsProcessTrusted() else {
            return .init(rectangles: rects, accessibilityTrusted: false, windowItems: windowItems, accessibilityItems: 0)
        }
        for pid in processIDs.prefix(64) where !excludedPIDs.contains(pid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.025)
            let keys = pid == frontmostPID ? ["AXExtrasMenuBar", "AXMenuBar"] : ["AXExtrasMenuBar"]
            for key in keys {
                var raw: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, key as CFString, &raw) == .success,
                      let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
                let menu = unsafeDowncast(raw, to: AXUIElement.self)
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &children) == .success,
                      let items = children as? [AXUIElement] else { continue }
                for item in items.prefix(64) {
                    AXUIElementSetMessagingTimeout(item, 0.025)
                    var position: CFTypeRef?, size: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
                          AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                          let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                    var point = CGPoint.zero, dimensions = CGSize.zero
                    guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
                          AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
                          dimensions.width > 0, dimensions.height > 0, dimensions.height < 70 else { continue }
                    rects.append(flip(CGRect(origin: point, size: dimensions), primaryTop: primaryTop))
                }
            }
        }
        return .init(rectangles: rects, accessibilityTrusted: true, windowItems: windowItems, accessibilityItems: rects.count - windowItems)
    }
    static func isCandidate(bounds: CGRect, layer: Int, ownerPID: pid_t, excludedPIDs: Set<pid_t>) -> Bool {
        !excludedPIDs.contains(ownerPID) && (24...26).contains(layer)
            && bounds.width > 0 && bounds.width < 600 && bounds.height > 0 && bounds.height < 60
    }
    private static func flip(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}
