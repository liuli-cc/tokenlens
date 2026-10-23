import Foundation

@main
struct AdditionalTelemetrySelfTest {
    enum Failure: Error { case expectation(String) }
    static func expect(_ passed: @autoclosure () -> Bool, _ message: String) throws {
        guard passed() else { throw Failure.expectation(message) }
    }
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_790_769_600)
        let at = now.timeIntervalSince1970 * 1000 - 1_000
        let work: [String: Any] = ["timestamp": at, "sessionId": "fixture-session", "content": "PRIVATE_TRANSCRIPT",
            "providerData": ["messageId": "fixture-call", "requestModelName": "fixture-model",
                "usage": ["inputTokens": 100, "outputTokens": 20, "totalTokens": 120, "requests": 1],
                "rawUsage": ["prompt_cache_hit_tokens": 40, "prompt_cache_write_tokens": 20, "credit": 900]]]
        let w = try unwrap(AdditionalAssistantReader.workBuddyRecord(work))
        try expect(w.usage.totalTokens == 120 && w.usage.cachedInputTokens == 40 && w.usage.cacheWriteInputTokens == 20, "WorkBuddy usage metadata")
        try expect(AdditionalAssistantReader.deduplicate([w, w]).count == 1, "WorkBuddy duplicate call")
        try expect(AdditionalAssistantReader.nonnegativeInteger(true) == nil && AdditionalAssistantReader.nonnegativeInteger(-1) == nil, "Invalid token fields")
        let claude: [String: Any] = ["type": "assistant", "timestamp": at, "sessionId": "desktop-fixture",
            "message": ["id": "api-id", "model": "claude-test", "content": "PRIVATE",
                "usage": ["input_tokens": 10, "cache_read_input_tokens": 70, "cache_creation_input_tokens": 20, "output_tokens": 5]]]
        let c = try unwrap(AdditionalAssistantReader.claudeRecord(claude))
        try expect(c.usage.inputTokens == 100 && c.usage.totalTokens == 105 && c.usage.cachedInputTokens == 70, "Anthropic cache inclusion")
        let code: [String: Any] = ["requests": [["id": "user-turn", "state": "complete", "startedAt": at,
            "messages": ["PRIVATE_MESSAGE_ID"], "usage": ["inputTokens": 1_000, "outputTokens": 100, "totalTokens": 1_100,
                "cacheTokens": 800, "cachedWriteTokens": 100, "credit": 8, "lastTokens": 200]]]]
        let rows = AdditionalAssistantReader.codeBuddyRecords(code, session: "history-session")
        try expect(rows.count == 1 && rows[0].requests == nil && rows[0].usage.totalTokens == 1_100, "CodeBuddy user turns are not API count")
        try expect(AdditionalAssistantReader.deduplicate(rows + rows).count == 1, "CodeBuddy history copies")
        let quota: [String: Any] = ["samples": [["t": at, "org": "PRIVATE_ORG", "u": [
            "five_hour": ["utilization": 20, "resets_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(600))],
            "seven_day": ["utilization": 75, "resets_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))]]]]]
        let q = try unwrap(AdditionalAssistantReader.claudeQuota(quota, now: now))
        try expect(q.primary.remainingPercent == 80 && q.secondary?.remainingPercent == 25, "Actual quota windows")
        try expect(AdditionalAssistantReader.claudeQuota(quota, now: now.addingTimeInterval(21_601)) == nil, "Expired quota does not infer reset")
        let compactQuota: [String: Any] = ["version": 2, "samples": [["t": at, "u": ["fh": 19, "sd": 3]]]]
        let compact = try unwrap(AdditionalAssistantReader.claudeQuota(compactQuota, now: now))
        try expect(compact.primary.remainingPercent == 81 && compact.secondary?.remainingPercent == 97 && compact.primary.resetsAt == nil, "Desktop v2 compact utilization")
        var observed = UsageSnapshot()
        observed.quota = compact.primary
        observed.secondaryQuota = compact.secondary
        observed.quotaUpdatedAt = compact.at
        try expect(observed.effectiveQuota(now: now) == nil, "Missing reset requires explicit source opt-in")
        observed.quotaResetTimeUnavailable = true
        try expect(observed.effectiveQuota(now: now)?.remainingPercent == 81, "Reported percentage without invented reset")
        try expect(observed.quotaPeriods(now: now).allSatisfy { $0.sampleNote == nil }, "Live samples carry no delay note")
        let delayed = observed.quotaPeriods(now: now.addingTimeInterval(901))
        try expect(delayed.map(\.value) == ["81.0%", "97.0%"] && delayed.allSatisfy { $0.delayedSampleAt == compact.at },
                   "Sparse history stays visible with its sample time")
        try expect(observed.quotaPeriods(now: now.addingTimeInterval(3_601)).map(\.value) == ["--", "97.0%"],
                   "Five-hour sample expires before the weekly one")
        try expect(observed.effectiveQuota(now: now.addingTimeInterval(21_601)) == nil, "Compact history expires")
        for invalid: Any in [true, -1, 101, "19"] {
            let invalidQuota: [String: Any] = ["version": 2, "samples": [["t": at, "u": ["fh": invalid]]]]
            try expect(AdditionalAssistantReader.claudeQuota(invalidQuota, now: now) == nil, "Invalid compact quota")
        }
        let control = ClaudeDesktopTelemetry.parseControl("用量：已使用会话限额的 19%4 小时 12 分钟后重置")
        try expect(control.usedPercent == 19, "Actual localized usage control")
        try expect(ClaudeDesktopTelemetry.parseControl("模型：Opus 5.5 中等").model == "Opus 5.5", "Visible selected model excludes effort")
        try expect(ClaudeDesktopTelemetry.parseControl("message says 19% remaining").usedPercent == nil, "Conversation text cannot become usage")
        try expect(ClaudeDesktopTelemetry.parseControl("用量：已使用会话限额的 101%").usedPercent == nil, "Invalid visible quota")
        try expect(ClaudeDesktopTelemetry.weeklyPercentage(label: "每周 · 所有模型", value: 4) == 4, "Visible weekly quota")
        try expect(ClaudeDesktopTelemetry.weeklyPercentage(label: "Weekly · All models", value: 0) == 0, "Explicit weekly zero")
        try expect(ClaudeDesktopTelemetry.weeklyPercentage(label: "每周 · Sonnet", value: 4) == nil, "Different weekly bucket stays separate")
        try expect(ClaudeDesktopTelemetry.weeklyPercentage(label: "每周 · 所有模型", value: true) == nil, "Boolean is not weekly usage")
        var split = UsageSnapshot()
        split.currentSource = "Claude Desktop / Cowork"
        let currentUI = ClaudeDesktopTelemetry.Visible(usedPercent: 8, surfaceKey: "synthetic-surface")
        let weeklySample = AdditionalAssistantReader.WeeklySample(usedPercent: 4, at: now.addingTimeInterval(-60), surfaceKey: "synthetic-surface")
        AdditionalAssistantReader.applyVisibleQuota(currentUI, weekly: weeklySample, to: &split, now: now)
        try expect(split.quotaPeriods(now: now).map(\.value) == ["92.0%", "96.0%"], "Short and weekly quotas retain distinct values")
        try expect(split.quotaPeriods(now: now).map(\.title) == ["5小时", "每周"], "Five hours is not a daily allowance")
        AdditionalAssistantReader.applyVisibleQuota(currentUI, weekly: weeklySample, to: &split, now: now.addingTimeInterval(850))
        try expect(split.quotaPeriods(now: now.addingTimeInterval(850)).map(\.value) == ["92.0%", "--"], "Fresh short quota cannot renew stale weekly quota")
        var switched = UsageSnapshot()
        AdditionalAssistantReader.applyVisibleQuota(ClaudeDesktopTelemetry.Visible(usedPercent: 10, surfaceKey: "different-surface"),
            weekly: weeklySample, to: &switched, now: now)
        try expect(switched.secondaryQuota == nil, "Different visible conversation cannot inherit cached weekly quota")
        split.quota = RateLimitWindow(usedPercent: 10, windowMinutes: 1_440, resetsAt: now.addingTimeInterval(600), planType: nil, sampledAt: now)
        try expect(split.quotaPeriods(now: now).first?.title == "每日", "Actual daily windows use daily label")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenlens-assistants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workRoot = root.appendingPathComponent(".workbuddy-ai/projects/test")
        let cliRoot = root.appendingPathComponent(".claude/projects/test")
        let codeRoot = root.appendingPathComponent("ApplicationSupport/CodeBuddyExtension/Data/synthetic/history/conversation")
        for folder in [workRoot, cliRoot, codeRoot] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var line = try JSONSerialization.data(withJSONObject: work); line.append(10)
        try line.write(to: workRoot.appendingPathComponent("session.jsonl"))
        try JSONSerialization.data(withJSONObject: claude).write(to: cliRoot.appendingPathComponent("session.jsonl"))
        try JSONSerialization.data(withJSONObject: code).write(to: codeRoot.appendingPathComponent("session.json"))
        let snapshot = await AdditionalAssistantReader(home: root, appSupport: root.appendingPathComponent("ApplicationSupport"), observeDesktopUI: false).read(now: now)
        let workSnapshot = try unwrap(snapshot[.workBuddy])
        let codeSnapshot = try unwrap(snapshot[.codeBuddy])
        let desktop = try unwrap(snapshot[.claude])
        try expect(workSnapshot.tokenUsageKnown && workSnapshot.cacheHitPercent == 40 && workSnapshot.recentRequestCount == 1, "Swift end-to-end WorkBuddy")
        try expect(codeSnapshot.tokenUsageKnown && codeSnapshot.cacheHitPercent == 80 && codeSnapshot.recentRequestCount == nil, "Swift end-to-end CodeBuddy")
        try expect(codeSnapshot.contextPercent == nil && codeSnapshot.providerBalance == nil && codeSnapshot.quota == nil, "Consumed credit does not become balance")
        try expect(!desktop.tokenUsageKnown && desktop.currentModel == "模型未返回", "Desktop must not borrow CLI")
        let desktopRoot = root.appendingPathComponent("ApplicationSupport/Claude/claude-code-sessions/account/org")
        try FileManager.default.createDirectory(at: desktopRoot, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["sessionId": "desktop-session", "cliSessionId": "unrelated-cli", "lastActivityAt": at,
            "model": "claude-opus-5-5", "isArchived": false, "title": "PRIVATE_TRANSCRIPT"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: desktopRoot.appendingPathComponent("local_session.json"))
        let selectedDesktop = try unwrap(await AdditionalAssistantReader(home: root,
            appSupport: root.appendingPathComponent("ApplicationSupport"), observeDesktopUI: false).read(now: now)[.claude])
        try expect(selectedDesktop.currentModel == "claude-opus-5-5" && !selectedDesktop.tokenUsageKnown, "Desktop model metadata without CLI token borrowing")
        var archived = metadata; archived["isArchived"] = true
        try expect(AdditionalAssistantReader.desktopModel(archived, now: now) == nil, "Archived model does not override current")
        try expect(AdditionalAssistantReader.desktopModel(metadata, now: now.addingTimeInterval(9 * 86_400)) == nil, "Old model metadata expires")
        try JSONSerialization.data(withJSONObject: compactQuota).write(to: root.appendingPathComponent("ApplicationSupport/Claude/plan-usage-history.json"))
        let freshDesktop = try unwrap(await AdditionalAssistantReader(home: root,
            appSupport: root.appendingPathComponent("ApplicationSupport"), observeDesktopUI: false).read(now: now)[.claude])
        try expect(freshDesktop.effectiveQuota(now: now)?.remainingPercent == 81 && freshDesktop.providerBalance == nil, "End-to-end compact quota stays a percentage")
        let database = root.appendingPathComponent(".workbuddy-ai/workbuddy.db")
        func databaseWrite(_ sql: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [database.path, sql]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            try expect(process.terminationStatus == 0, "Create synthetic lifecycle DB")
        }
        try databaseWrite("CREATE TABLE sessions(id TEXT,status TEXT,is_background_automation INTEGER,deleted_at INTEGER,last_activity_at INTEGER); CREATE TABLE session_usage(session_id TEXT,used INTEGER,size INTEGER,updated_at INTEGER); INSERT INTO sessions VALUES('fixture-session','working',0,NULL,\(Int64(at))); INSERT INTO session_usage VALUES('fixture-session',50,200,\(Int64(at)));")
        let reader = AdditionalAssistantReader(home: root, appSupport: root.appendingPathComponent("ApplicationSupport"), observeDesktopUI: false)
        let working = try unwrap(await reader.read(now: now)[.workBuddy])
        try expect(working.isTaskRunning && working.contextPercent == 25 && working.latestCompletion == nil, "Explicit live status/context")
        try databaseWrite("UPDATE sessions SET status='completed';")
        let completed = try unwrap(await reader.read(now: now)[.workBuddy])
        try expect(!completed.isTaskRunning && completed.latestCompletion == nil, "Terminal cached state without end timestamp must not celebrate")
        print("Additional assistant telemetry self-test passed: cache formulas, deduplication, unknown metadata, quota freshness, Desktop/CLI separation")
    }
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure.expectation("Required fixture parse") }
        return value
    }
}
