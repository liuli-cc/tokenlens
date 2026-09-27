import Foundation
import CoreGraphics

@main
struct IslandSelfTest {
    static func main() async throws {
        try testGeometry()
        try testBodyCentering()
        try testCompactText()
        try testSpring()
        try testDeepSeekEvents()
        try await testCompressedReader()
        print("Island self-tests passed: camera-attached geometry, menu exclusions, interruptible spring, DSH lifecycle and compressed reader")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "IslandSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func testGeometry() throws {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let left = CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5)
        let right = CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
        let layout = IslandGeometry.layout(screen: screen, safeTopInset: 33.5, leftAux: left, rightAux: right)
        try check(layout.camera?.width == 185 && layout.bandHeight == 33.5, "Physical notch dimensions were changed")
        try check(layout.crownFrame.maxY == screen.maxY && layout.crownFrame.height == 33.5, "Compact island detached from camera band")
        try check(layout.leftWing == 108 && layout.rightWing == 82, "Unexpected default wing sizes")
        try check(!layout.crownContains(CGPoint(x: 855, y: 1090)), "Physical camera region accepts clicks")
        for point in [CGPoint(x: 855, y: 1090), CGPoint(x: 855, y: 1107),
                      CGPoint(x: 762.5, y: 1107), CGPoint(x: 947.5, y: 1107)] {
            try check(layout.cameraContains(point) && layout.crownHoverContains(point), "Invisible camera cursor failed to trigger hover")
        }
        try check(!layout.cameraContains(CGPoint(x: 855, y: 1073.4)), "Camera hover leaked below camera band")
        try check(!layout.crownHoverContains(CGPoint(x: 1100, y: 1100)), "Camera hover leaked into system icons")
        for height in [CGFloat(0), 12, 88, 152, 168] {
            let body = layout.bodyFrame(width: 446, height: height)
            try check(body.maxY == layout.camera?.minY, "Animated body moved the camera-bottom anchor")
            try check(layout.crownFrame.maxY == 1107, "Spring moved the crown off screen top")
        }
        let crowded = IslandGeometry.layout(screen: screen, safeTopInset: 33.5, leftAux: left, rightAux: right,
            occupied: [CGRect(x: 670, y: 1074, width: 65, height: 28), CGRect(x: 971, y: 1074, width: 30, height: 28)])
        try check(crowded.leftWing == 21.5 && crowded.rightWing == 17.5, "Crowded wings did not leave six-point icon clearance")
        try check(crowded.crownFrame.maxY == 1107, "Crowded island was moved down into work area")
        let blocked = IslandGeometry.layout(screen: screen, safeTopInset: 33.5, leftAux: left, rightAux: right,
            occupied: [CGRect(x: 947.5, y: 1074, width: 50, height: 28)])
        try check(blocked.rightWing == 0 && blocked.leftWing == 108, "Obstructed wing should disappear without shifting camera")
        try check(blocked.crownHoverContains(CGPoint(x: 855, y: 1107)), "Menu avoidance disabled camera hover")
        let noPermission = IslandGeometry.layout(screen: screen, safeTopInset: 33.5, leftAux: left, rightAux: right, conservativeWings: true)
        try check(noPermission.leftWing == 72 && noPermission.rightWing == 42 && noPermission.crownFrame.maxY == 1107,
                  "No-permission fallback should retain text-capable top-attached wings")
        let external = IslandGeometry.layout(screen: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
            safeTopInset: 0, leftAux: nil, rightAux: nil)
        try check(external.crownFrame.maxY == 980 && external.bandHeight <= 26 && external.camera == nil, "External display fallback is not top-attached")
        try check(!external.cameraContains(CGPoint(x: -960, y: 980)), "External display invented a camera hover region")
        let narrow = IslandGeometry.layout(screen: CGRect(x: 0, y: 0, width: 320, height: 600), safeTopInset: 0, leftAux: nil, rightAux: nil)
        try check(narrow.crownFrame.width <= 320 * 0.34, "Small-screen compact width is not restrained")
        try check(!MenuBarOccupancy.isCandidate(bounds: layout.crownFrame, layer: 25, ownerPID: 42, excludedPIDs: [42]), "Island mistakenly treats itself as a menu icon")
        try check(!MenuBarOccupancy.isCandidate(bounds: CGRect(x: 0, y: 0, width: 1710, height: 34), layer: 24, ownerPID: 7, excludedPIDs: []), "Full menu bar mistakenly treated as an icon")
    }

    private static func testBodyCentering() throws {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let camera = CGRect(x: 762.5, y: 1073.5, width: 185, height: 33.5)
        var layouts = [(CGFloat(72), CGFloat(42)), (108, 0), (0, 82), (21.5, 17.5)].map { left, right in
            IslandLayout(screen: screen, camera: camera, bandHeight: 33.5, anchorX: 855, leftWing: left, rightWing: right)
        }
        layouts.append(IslandLayout(screen: CGRect(x: -320, y: -100, width: 320, height: 600),
                                    camera: nil, bandHeight: 24, anchorX: -160, leftWing: 96, rightWing: 0))
        for layout in layouts {
            try check(layout.bodyBaseWidth == max(1, layout.crownFrame.width), "Collapsed body neck differs from the crown")
            for width in [layout.bodyBaseWidth, layout.expandedWidth, layout.expandedWidth + 12, layout.screen.width * 2] {
                for height in [CGFloat(0.5), 12, 88, 152, 168] {
                    let body = layout.bodyFrame(width: width, height: height)
                    try check(abs(body.midX - layout.crownFrame.midX) < 0.000001, "Expanded body and crown have different centerlines")
                    let leftShoulder = layout.crownFrame.minX - body.minX
                    let rightShoulder = body.maxX - layout.crownFrame.maxX
                    try check(abs(leftShoulder - rightShoulder) < 0.000001, "Menu avoidance made expanded shoulders asymmetric")
                    try check(body.minX >= layout.screen.minX && body.maxX <= layout.screen.maxX, "Centered body or spring overshoot escaped the screen")
                    try check(body.maxY == layout.crownFrame.minY, "Centering detached the body from the crown")
                }
            }
            if layout.camera != nil {
                try check(layout.cameraContains(CGPoint(x: 855, y: 1107)), "Visual centering moved the real camera hover region")
            }
        }
    }

    private static func testCompactText() throws {
        let gpt = IslandCompactText.model("gpt-6-astra")
        try check(gpt.primary == "GPT-6" && gpt.secondary == "ASTRA", "Compact GPT model lost version or family")
        let ultra = IslandCompactText.model("gpt-5.6-ultra")
        try check(ultra.primary == "GPT-5.6" && ultra.secondary == "ULTRA", "Compact model lost Ultra identifier")
        let deepSeek = IslandCompactText.model("DeepSeek-V4-Flash")
        try check(deepSeek.primary == "DeepSeek" && deepSeek.secondary == "V4-Flash", "Compact DSH model lost variant")
        try check(IslandCompactText.model("unrecognized-model").primary == "unrecognized-model", "Unknown model name was invented")
        try check(IslandCompactText.metric("93.5%") == "93.5%" && IslandCompactText.metric("100.0%") == "100%", "Quota percent was changed to balance or lost precision")
        try check(IslandCompactText.metric("0.4%", characterBudget: 4) == "<1%", "Small nonzero quota was shown as exhausted")
        try check(IslandCompactText.metric("¥12,345.67") == "¥12.3K", "Large CNY balance did not retain currency")
        try check(IslandCompactText.metric("$2500000.00") == "$2.5M", "Large USD balance did not retain currency")
        try check(IslandCompactText.metric("¥0.0001") == "¥0.0001", "Small nonzero balance was rounded to zero")
        try check(IslandCompactText.metric("未登录") == "未登录" && IslandCompactText.metric("暂不可读") == "暂不可读", "Unavailable account state was fabricated as a numeric value")
    }

    private static func testSpring() throws {
        var spring = IslandSpring(position: 0, target: 152)
        var peak = 0.0
        for _ in 0..<240 { spring.advance(by: 1 / 120); peak = max(peak, spring.position) }
        try check(peak > 157 && peak < 180 && spring.isSettled, "Spring lacks controlled visible overshoot or convergence")
        var interrupted = IslandSpring(position: 0, target: 152)
        interrupted.advance(by: 0.13)
        let position = interrupted.position, velocity = interrupted.velocity
        interrupted.target = 0
        try check(interrupted.position == position && interrupted.velocity == velocity, "Retargeting discontinuously reset spring state")
        interrupted.advance(by: 0.001)
        try check(interrupted.position > position, "Retargeting discarded existing outward velocity")
        interrupted.advance(by: 2)
        try check(interrupted.isSettled, "Interrupted spring failed to settle")
        var at60 = IslandSpring(position: 0, target: 152), at120 = at60
        for _ in 0..<60 { at60.advance(by: 1 / 60) }
        for _ in 0..<120 { at120.advance(by: 1 / 120) }
        try check(abs(at60.position - at120.position) < 0.000001 && abs(at60.velocity - at120.velocity) < 0.000001, "Spring depends on display frame rate")
        var critical = IslandSpring(position: 0, target: 152, damping: 1)
        for _ in 0..<240 { critical.advance(by: 1 / 120); try check(critical.position <= 152, "Critical damping overshot") }
        try check(critical.isSettled, "Critical spring did not settle")
    }

    private static func testDeepSeekEvents() throws {
        for reason in ["completed", "error", "aborted", "blocked", "max-tokens"] {
            var digest = DeepSeekEventDigest()
            digest.consume(Data(#"{"type":"session","version":4,"id":"test","delegationDepth":0}"#.utf8))
            digest.consume(Data(#"{"type":"turn/start","time":1000,"data":{"turn":1}}"#.utf8))
            try check(digest.activeTurn == 1, "Start event did not mark task running")
            digest.consume(Data("{\"type\":\"turn/end\",\"time\":2000,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"\(reason)\"}}}".utf8))
            try check(digest.activeTurn == nil, "End event did not clear task running")
            try check((digest.latestCompletion != nil) == (reason == "completed"), "Non-success was announced as completed: \(reason)")
            if let notice = digest.latestCompletion {
                try check(notice.id == "dsh|test|1" && notice.isDeepSeek, "Wrong DSH completion identity")
                try check(notice.startedAt == Date(timeIntervalSince1970: 1) && notice.completedAt == Date(timeIntervalSince1970: 2), "Millisecond timestamps not decoded")
            }
        }
        var child = DeepSeekEventDigest()
        child.consume(Data(#"{"type":"session","version":4,"id":"child","delegationDepth":1}"#.utf8))
        child.consume(Data(#"{"type":"turn/end","time":2000,"data":{"turn":1,"reason":{"kind":"completed"}}}"#.utf8))
        try check(child.latestCompletion == nil, "Subagent completion escaped into user feedback")
        child.consume(Data("partial json".utf8))
    }

    private static func testCompressedReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenlens-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("input.jsonl")
        let output = root.appendingPathComponent("session.v4.jsonl.zstd")
        let now = Date()
        let content = """
        {"type":"session","version":4,"id":"fixture","delegationDepth":0}
        {"type":"turn/start","time":\(now.timeIntervalSince1970 * 1000 - 1000),"data":{"turn":1}}
        {"type":"turn/end","time":\(now.timeIntervalSince1970 * 1000),"data":{"turn":1,"reason":{"kind":"completed"}}}

        """
        try content.write(to: plain, atomically: true, encoding: .utf8)
        let command = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let command else { throw NSError(domain: "IslandSelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "zstd is required to verify DSH logs"]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["-q", plain.path, "-o", output.path]
        try process.run()
        process.waitUntilExit()
        try check(process.terminationStatus == 0, "Unable to create synthetic DSH fixture")
        let reader = DeepSeekActivityReader(root: root)
        let result = await reader.read(now: now)
        try check(!result.isRunning && result.latestCompletion?.id == "dsh|fixture|1", "Compressed log did not produce expected lifecycle")
        let cached = await reader.read(now: now)
        try check(cached == result, "Unmodified compressed log cache changed")
    }
}
