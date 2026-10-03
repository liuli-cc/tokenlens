import Foundation
import CoreGraphics

struct IslandLayout: Equatable, Sendable {
    let screen: CGRect
    let camera: CGRect?
    let bandHeight: CGFloat
    let anchorX: CGFloat
    let leftWing: CGFloat
    let rightWing: CGFloat
    var gapWidth: CGFloat { camera?.width ?? 0 }
    var crownFrame: CGRect {
        CGRect(x: anchorX - gapWidth / 2 - leftWing, y: screen.maxY - bandHeight,
               width: leftWing + gapWidth + rightWing, height: bandHeight)
    }
    var leftContent: CGRect { CGRect(x: crownFrame.minX, y: crownFrame.minY, width: leftWing, height: bandHeight) }
    var rightContent: CGRect { CGRect(x: anchorX + gapWidth / 2, y: crownFrame.minY, width: rightWing, height: bandHeight) }
    // Menu avoidance can make the wings unequal. Center the body on the visible
    // crown, while keeping the actual camera and its hover region unchanged.
    var bodyAnchorX: CGFloat { crownFrame.midX }
    var bodyBaseWidth: CGFloat { max(1, crownFrame.width) }
    var bodyMaximumWidth: CGFloat {
        max(1, 2 * min(bodyAnchorX - screen.minX, screen.maxX - bodyAnchorX))
    }
    var expandedWidth: CGFloat {
        min(max(bodyBaseWidth, 446), max(bodyBaseWidth, bodyMaximumWidth - 20))
    }
    func bodyFrame(width: CGFloat, height: CGFloat) -> CGRect {
        let visibleWidth = min(max(1, width), bodyMaximumWidth)
        return CGRect(x: bodyAnchorX - visibleWidth / 2, y: screen.maxY - bandHeight - height, width: visibleWidth, height: height)
    }
    func crownContains(_ point: CGPoint) -> Bool {
        leftContent.contains(point) || rightContent.contains(point)
    }
    /// The cursor can enter the physical camera cutout even though it is hidden.
    /// Include the screen's upper edge, where CGRect.contains is exclusive.
    func cameraContains(_ point: CGPoint) -> Bool {
        guard let camera else { return false }
        return point.x >= camera.minX && point.x <= camera.maxX
            && point.y >= camera.minY && point.y <= camera.maxY
    }
    func crownHoverContains(_ point: CGPoint) -> Bool {
        cameraContains(point) || crownContains(point)
    }
}

/// The compact island belongs to the camera/menu band. Menus take precedence:
/// crowded wings shrink or disappear; the island never moves into the work area.
enum IslandGeometry {
    static func screenPoint(fromQuartz point: CGPoint, primaryScreen: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreen.maxY - point.y)
    }

    static func layout(screen: CGRect, safeTopInset: CGFloat, leftAux: CGRect?, rightAux: CGRect?,
                       menuBarHeight: CGFloat = 24, occupied: [CGRect] = [], conservativeWings: Bool = false) -> IslandLayout {
        let camera: CGRect?
        let band: CGFloat
        if let left = leftAux, let right = rightAux,
           !left.isEmpty, !right.isEmpty, right.minX > left.maxX, safeTopInset > 0 {
            band = safeTopInset
            camera = CGRect(x: left.maxX, y: screen.maxY - band, width: right.minX - left.maxX, height: band)
        } else {
            camera = nil
            band = min(26, max(20, menuBarHeight))
        }
        let center = camera?.midX ?? screen.midX
        let gap = camera?.width ?? 0
        let leftEdge = center - gap / 2
        let rightEdge = center + gap / 2
        var left = min(camera == nil ? 96 : 108, leftEdge - screen.minX)
        var right = min(camera == nil ? 78 : 82, screen.maxX - rightEdge)
        if conservativeWings {
            left = min(left, 72)
            right = min(right, 42)
        }
        let menuBand = CGRect(x: screen.minX, y: screen.maxY - band, width: screen.width, height: band)
        for rect in occupied where rect.intersects(menuBand) {
            if rect.minX < leftEdge && rect.maxX > leftEdge - left - 6 {
                left = max(0, leftEdge - rect.maxX - 6)
            }
            if rect.maxX > rightEdge && rect.minX < rightEdge + right + 6 {
                right = max(0, rect.minX - rightEdge - 6)
            }
        }
        let capacity = max(0, min(440, screen.width * 0.34) - gap)
        if left + right > capacity {
            let scale = capacity / (left + right)
            left *= scale
            right *= scale
        }
        return IslandLayout(screen: screen, camera: camera, bandHeight: band, anchorX: center,
                            leftWing: left, rightWing: right)
    }
}

/// Closed-form damped oscillator. Retargeting changes the force, never the
/// current position or velocity, so interrupted gestures remain continuous.
struct IslandSpring: Sendable {
    var position: Double
    var velocity: Double = 0
    var target: Double
    var frequency: Double = 18
    var damping: Double = 0.62

    var isSettled: Bool { abs(position - target) < 0.05 && abs(velocity) < 0.15 }
    mutating func advance(by dt: Double) {
        guard dt > 0 else { return }
        let x = position - target
        let w = frequency
        let z = damping
        if z < 1 {
            let wd = w * sqrt(1 - z * z)
            let b = (velocity + z * w * x) / wd
            let c = cos(wd * dt), s = sin(wd * dt), decay = exp(-z * w * dt)
            let displacement = x * c + b * s
            position = target + decay * displacement
            velocity = decay * (-z * w * displacement - x * wd * s + b * wd * c)
        } else {
            let b = velocity + w * x
            let decay = exp(-w * dt)
            position = target + (x + b * dt) * decay
            velocity = (b - w * (x + b * dt)) * decay
        }
    }
    mutating func settle() { position = target; velocity = 0 }
}
