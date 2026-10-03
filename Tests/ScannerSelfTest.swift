import Foundation

enum SelfTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@main
struct ScannerSelfTest {
    static func main() async throws {
        try await testRepeatedUsageResetAndQuotaWindows()
        try await testDynamicModelAndMetrics()
        try await testIncrementalRefresh()
        try await testRunningAndAbortedLifecycle()
        try await testCompletionMetricsTitleAndSharedQuotaBaseline()
        try await testSubagentCompletionIsIgnored()
        try await testCompletionBatches()
        try await testCCSwitchTaskCostSupportsSecondsAndMilliseconds()
        try await testCCSwitchInputSemantics()
        try await testConfiguredProviderDoesNotOverrideOfficialSession()
        try await testOfficialQuotaDoesNotBindExternalSession()
        try testCompletionNoticeGate()
        try testQuotaDeltaCalculator()
        try testCompletionMetricFormatting()
        try testRechargeURLResolution()
        print("TokenLens scanner self-test passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SelfTestFailure.assertion(message) }
    }

    private static func testRepeatedUsageResetAndQuotaWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func event(_ type: String, _ payload: [String: Any], _ offset: Double) throws -> String {
            let value: [String: Any] = ["type": type, "payload": payload, "timestamp": now.addingTimeInterval(offset).ISO8601Format()]
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        func token(_ total: Int64) -> [String: Any] {
            let usage: [String: Any] = ["input_tokens": total * 8 / 10, "cached_input_tokens": total * 4 / 10, "output_tokens": total * 2 / 10, "total_tokens": total]
            return ["type": "token_count", "info": ["total_token_usage": usage,
                "last_token_usage": ["input_tokens": 80, "cached_input_tokens": 40, "output_tokens": 20, "total_tokens": 100], "model_context_window": 1000]]
        }
        let header = try event("session_meta", ["id": "root", "model_provider": "openai"], -10)
        let model = try event("turn_context", ["model": "root-model"], -9)
        let calls = try [(100, -8.0), (100, -7.0), (20, -6.0), (70, -5.0)].map { try event("event_msg", token(Int64($0.0)), $0.1) }
        let reset = now.addingTimeInterval(3600).timeIntervalSince1970
        let quota = try event("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": [
            "primary": ["used_percent": 50, "window_minutes": 300, "resets_at": reset],
            "secondary": ["used_percent": 80, "window_minutes": 10080, "resets_at": reset]]], -1)
        try Data(([header, model] + calls + [quota]).joined(separator: "\n").appending("\n").utf8).write(to: root.appendingPathComponent("root.jsonl"))
        let child = try event("session_meta", ["id": "child", "source": ["subagent": [:]]], -11)
        let childModel = try event("turn_context", ["model": "child-model"], 0)
        try Data(([child, header, model] + calls + [childModel]).joined(separator: "\n").appending("\n").utf8).write(to: root.appendingPathComponent("child.jsonl"))
        let scanner = CodexLogScanner(sessionsRoot: root, ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")))
        let result = try await scanner.scan(now: now)
        try expect(result.currentModel == "root-model", "subagent model replaced root model")
        try expect(result.todayUsage.totalTokens == 170, "repeat/reset/copied usage was counted incorrectly")
        try expect(result.currentSessionUsage.totalTokens == 170, "reset lost prior epoch usage")
        try expect(result.recentRequestCount == 3, "recorded request count ignored duplicate totals")
        try expect(result.contextPercent == 10, "context estimate used lifetime cumulative instead of latest response")
        try expect(result.cacheHitPercent == 50, "session cache percent denominator incorrect")
        try expect(result.effectiveQuota(now: now)?.remainingPercent == 20, "secondary bottleneck quota ignored")
        try expect(result.effectiveQuota(now: now.addingTimeInterval(901)) == nil, "stale quota shown as current")
        try expect(UsageSnapshot.empty.cacheHitPercent == nil, "unknown cache was represented as zero")
        try expect(UsageSnapshot.empty.contextPercent == nil, "unknown context was represented as zero")
    }

    private static func testRechargeURLResolution() throws {
        try expect(
            ProviderRechargeURLResolver.url(
                providerName: "DeepSeek",
                baseURL: "https://api.deepseek.com",
                websiteURL: "https://platform.deepseek.com"
            ) == URL(string: "https://platform.deepseek.com/top_up"),
            "DeepSeek recharge URL was not resolved"
        )
        try expect(
            ProviderRechargeURLResolver.url(
                providerName: "Kimi",
                baseURL: "https://api.moonshot.cn/v1",
                websiteURL: "https://platform.kimi.com?aff=cc-switch"
            ) == URL(string: "https://platform.kimi.com/console/pay"),
            "Kimi recharge URL was not resolved"
        )
        try expect(
            ProviderRechargeURLResolver.url(
                providerName: "GLM",
                baseURL: "https://open.bigmodel.cn/api/paas/v4",
                websiteURL: "https://open.bigmodel.cn"
            ) == URL(string: "https://open.bigmodel.cn/console/usercenter/expense"),
            "GLM recharge URL was not resolved"
        )
        try expect(
            ProviderRechargeURLResolver.url(
                providerName: "Custom Relay",
                baseURL: "https://api.example.com/v1",
                websiteURL: "https://example.com/billing"
            ) == URL(string: "https://example.com/billing"),
            "Fallback recharge URL was not used"
        )
        try expect(
            ProviderRechargeURLResolver.url(
                providerName: "Custom Relay",
                baseURL: "https://api.example.com/v1",
                websiteURL: ""
            ) == nil,
            "Unknown provider without website should not resolve a recharge URL"
        )
    }

    private static func testDynamicModelAndMetrics() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dayFolder = root.appendingPathComponent("2026/08/14", isDirectory: true)
        try fileManager.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let log = dayFolder.appendingPathComponent("rollout-test.jsonl")
        let lines = [
            #"{"timestamp":"2026-08-14T02:00:00.000Z","type":"session_meta","payload":{"model_provider":"third-party-provider"}}"#,
            #"{"timestamp":"2026-08-14T02:00:00.000Z","type":"turn_context","payload":{"model":"future-codex-model-x","summary":"Dashboard context title"}}"#,
            #"{"timestamp":"2026-08-14T02:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":100},"last_token_usage":{"input_tokens":80,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":100},"model_context_window":400000},"rate_limits":{"primary":{"used_percent":37.5,"window_minutes":10080,"resets_at":1787241518},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-08-14T02:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":250},"last_token_usage":{"input_tokens":120,"cached_input_tokens":60,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":150},"model_context_window":400000},"rate_limits":{"primary":{"used_percent":37.5,"window_minutes":10080,"resets_at":1787241518},"plan_type":"plus"}}}"#
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: log)

        let scanner = CodexLogScanner(
            sessionsRoot: root,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db"))
        )
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T12:00:00Z")
        let snapshot = try await scanner.scan(now: now)

        try expect(snapshot.currentModel == "future-codex-model-x", "dynamic model was not detected")
        try expect(snapshot.currentProvider == "third-party-provider", "model provider was not detected")
        try expect(snapshot.currentSessionUsage.totalTokens == 250, "session token total is incorrect")
        try expect(snapshot.lastCallUsage.totalTokens == 150, "last call size is incorrect")
        try expect(snapshot.contextWindow == 400_000, "dynamic context window is incorrect")
        try expect(abs(snapshot.cacheHitRate - 50) < 0.001, "cache hit rate is incorrect")
        try expect(snapshot.quota == nil && snapshot.usesExternalModel, "External provider inherited an official quota")
        try expect(snapshot.dailyUsage.last?.usage.totalTokens == 250, "daily trend is incorrect")
        try expect(snapshot.modelUsage.first?.model == "future-codex-model-x", "model usage was not grouped")
    }

    private static func testIncrementalRefresh() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let log = root.appendingPathComponent("rollout-test.jsonl")
        let first = #"{"timestamp":"2026-08-14T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":90,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100},"model_context_window":200000},"rate_limits":null}}"# + "\n"
        try Data(first.utf8).write(to: log)

        let scanner = CodexLogScanner(
            sessionsRoot: root,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db"))
        )
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T12:00:00Z")
        _ = try await scanner.scan(now: now)

        let second = #"{"timestamp":"2026-08-14T02:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":90,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100},"model_context_window":200000},"rate_limits":null}}"# + "\n"
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.utf8))
        try handle.close()

        let refreshed = try await scanner.scan(now: now)
        try expect(refreshed.currentSessionUsage.totalTokens == 200, "incremental session total is incorrect")
        try expect(refreshed.dailyUsage.last?.usage.totalTokens == 200, "incremental delta was double-counted")
    }

    private static func testRunningAndAbortedLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("rollout-lifecycle.jsonl")
        let content = [
            #"{"timestamp":"2026-08-14T02:00:00Z","type":"session_meta","payload":{"id":"live-root","thread_source":"user","source":"vscode"}}"#,
            #"{"timestamp":"2026-08-14T02:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"running-turn"}}"#
        ].joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: log)
        let scanner = CodexLogScanner(sessionsRoot: root,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")))
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T02:00:02Z")
        let running = try await scanner.scan(now: now)
        try expect(running.isTaskRunning, "Explicit task start was not reflected by the island activity")
        let stale = try await scanner.scan(now: now.addingTimeInterval(900))
        try expect(!stale.isTaskRunning, "Stale unfinished session remained permanently active")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"timestamp":"2026-08-14T02:00:03Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"running-turn"}}"# + "\n").utf8))
        try handle.close()
        let aborted = try await scanner.scan(now: now.addingTimeInterval(2))
        try expect(!aborted.isTaskRunning && aborted.latestCompletion == nil,
                   "Aborted task stayed active or produced a success notice")
    }

    private static func testCompletionMetricsTitleAndSharedQuotaBaseline() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexRoot = root.appendingPathComponent("codex-state", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sessionID = "session-main"
        let index = #"{"id":"session-main","thread_name":"完成提醒测试"}"# + "\n"
        try Data(index.utf8).write(to: codexRoot.appendingPathComponent("session_index.jsonl"))

        let resetAt: Int64 = 1_787_241_518
        let baseline = [
            #"{"timestamp":"2026-08-14T02:00:00.000Z","type":"session_meta","payload":{"id":"session-prior","thread_source":"user","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-08-14T02:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":100},"last_token_usage":{"input_tokens":80,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":100},"model_context_window":400000},"rate_limits":{"primary":{"used_percent":37.5,"window_minutes":10080,"resets_at":1787241518},"plan_type":"plus"}}}"#
        ].joined(separator: "\n") + "\n"
        try Data(baseline.utf8).write(to: sessionsRoot.appendingPathComponent("rollout-prior.jsonl"))

        let startedAt = try Date.ISO8601FormatStyle().parse("2026-08-14T02:01:00Z")
        let completedAt = try Date.ISO8601FormatStyle().parse("2026-08-14T02:02:00Z")
        let startedEpoch = Int64(startedAt.timeIntervalSince1970)
        let completedEpoch = Int64(completedAt.timeIntervalSince1970)
        let task = [
            #"{"timestamp":"2026-08-14T02:00:59.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","thread_source":"user","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-08-14T02:00:59.500Z","type":"turn_context","payload":{"model":"gpt-5.6","summary":"auto"}}"#,
            #"{"timestamp":"2026-08-14T02:01:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-A","started_at":\#(startedEpoch),"model_context_window":400000}}"#,
            #"{"timestamp":"2026-08-14T02:01:59.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":250},"last_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":250},"model_context_window":400000},"rate_limits":{"primary":{"used_percent":38.25,"window_minutes":10080,"resets_at":\#(resetAt)},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-08-14T02:02:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-A","started_at":\#(startedEpoch),"completed_at":\#(completedEpoch),"last_agent_message":"This body must not be decoded by the completion envelope."}}"#
        ].joined(separator: "\n") + "\n"
        try Data(task.utf8).write(to: sessionsRoot.appendingPathComponent("rollout-main.jsonl"))

        let scanner = CodexLogScanner(
            sessionsRoot: sessionsRoot,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")),
            threadTitleStore: CodexThreadTitleStore(codexRoot: codexRoot)
        )
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T12:00:00Z")
        let snapshot = try await scanner.scan(now: now)
        guard let completion = snapshot.latestCompletion else {
            throw SelfTestFailure.assertion("top-level task completion was not detected")
        }

        try expect(completion.id == "session-main|turn-A", "completion identity is incorrect")
        try expect(completion.title == "完成提醒测试", "exact thread title was not resolved")
        try expect(completion.usage.inputTokens == 200, "task input usage is incorrect")
        try expect(completion.usage.cachedInputTokens == 100, "task cached usage is incorrect")
        try expect(completion.usage.outputTokens == 50, "task output usage is incorrect")
        try expect(completion.usage.totalTokens == 250, "task total usage is incorrect")
        try expect(
            completion.quotaUsedPercent == nil,
            "shared quota baseline was not applied to the first task"
        )
    }

    private static func testSubagentCompletionIsIgnored() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let codexRoot = root.appendingPathComponent("codex-state", isDirectory: true)
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let rootStarted = try Date.ISO8601FormatStyle().parse("2026-08-14T03:00:00Z")
        let rootCompleted = try Date.ISO8601FormatStyle().parse("2026-08-14T03:00:10Z")
        let childStarted = try Date.ISO8601FormatStyle().parse("2026-08-14T03:00:01Z")
        let childCompleted = try Date.ISO8601FormatStyle().parse("2026-08-14T03:00:20Z")

        let rootLog = [
            #"{"timestamp":"2026-08-14T02:59:59.000Z","type":"session_meta","payload":{"id":"root-session","thread_source":"user","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-08-14T02:59:59.500Z","type":"turn_context","payload":{"model":"gpt-5.6","summary":"auto"}}"#,
            #"{"timestamp":"2026-08-14T03:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"root-turn","started_at":\#(Int64(rootStarted.timeIntervalSince1970))}}"#,
            #"{"timestamp":"2026-08-14T03:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":90,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100}},"rate_limits":null}}"#,
            #"{"timestamp":"2026-08-14T03:00:10.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"root-turn","started_at":\#(Int64(rootStarted.timeIntervalSince1970)),"completed_at":\#(Int64(rootCompleted.timeIntervalSince1970))}}"#
        ].joined(separator: "\n") + "\n"
        try Data(rootLog.utf8).write(to: sessionsRoot.appendingPathComponent("rollout-root.jsonl"))

        let childLog = [
            #"{"timestamp":"2026-08-14T03:00:00.000Z","type":"session_meta","payload":{"id":"child-session","session_id":"root-session","thread_source":"subagent","source":{"subagent":{"name":"audit"}},"model_provider":"openai"}}"#,
            #"{"timestamp":"2026-08-14T03:00:00.500Z","type":"session_meta","payload":{"id":"root-session","thread_source":"user","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-08-14T03:00:00.750Z","type":"turn_context","payload":{"model":"gpt-5.6","summary":"auto"}}"#,
            #"{"timestamp":"2026-08-14T03:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"child-turn","started_at":\#(Int64(childStarted.timeIntervalSince1970))}}"#,
            #"{"timestamp":"2026-08-14T03:00:19.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":180,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":200}},"rate_limits":null}}"#,
            #"{"timestamp":"2026-08-14T03:00:20.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"child-turn","started_at":\#(Int64(childStarted.timeIntervalSince1970)),"completed_at":\#(Int64(childCompleted.timeIntervalSince1970))}}"#
        ].joined(separator: "\n") + "\n"
        try Data(childLog.utf8).write(to: sessionsRoot.appendingPathComponent("rollout-child.jsonl"))

        let scanner = CodexLogScanner(
            sessionsRoot: sessionsRoot,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")),
            threadTitleStore: CodexThreadTitleStore(codexRoot: codexRoot)
        )
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T12:00:00Z")
        let snapshot = try await scanner.scan(now: now)
        try expect(
            snapshot.latestCompletion?.id == "root-session|root-turn",
            "subagent completion replaced the user task completion"
        )
    }

    private static func testCompletionBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenlens-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_769_600)
        func event(_ type: String, _ payload: [String: Any], _ offset: Double) throws -> String {
            let value: [String: Any] = ["type": type, "payload": payload,
                "timestamp": now.addingTimeInterval(offset).ISO8601Format()]
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        func finish(_ turn: String, _ offset: Double) -> [String: Any] {
            ["type": "task_complete", "turn_id": turn,
             "completed_at": now.addingTimeInterval(offset).timeIntervalSince1970]
        }
        func tokens(_ total: Int) -> [String: Any] {
            ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total * 8 / 10,
                "cached_input_tokens": total * 4 / 10, "output_tokens": total * 2 / 10, "total_tokens": total]]]
        }
        let main = root.appendingPathComponent("main.jsonl")
        let mainEvents = try [
            event("session_meta", ["id": "batch-main", "thread_source": "user", "model_provider": "openai"], -110),
            event("turn_context", ["model": "gpt-fixture"], -109),
            event("event_msg", finish("old", -100), -100),
            event("event_msg", ["type": "task_started", "turn_id": "A"], -5),
            event("event_msg", tokens(100), -4.5),
            event("event_msg", finish("A", -4), -4),
            event("event_msg", ["type": "task_started", "turn_id": "B"], -3),
            event("event_msg", tokens(250), -2.5),
            event("event_msg", finish("B", -2), -2),
            event("event_msg", finish("A", -4), -1.8),
            event("event_msg", ["type": "task_started", "turn_id": "aborted"], -1.5),
            event("event_msg", ["type": "turn_aborted", "turn_id": "aborted"], -1)
        ]
        try Data((mainEvents.joined(separator: "\n") + "\n").utf8).write(to: main)
        let peer = try [
            event("session_meta", ["id": "batch-peer", "thread_source": "user", "model_provider": "custom"], -6),
            event("turn_context", ["model": "external-fixture"], -5.5),
            event("event_msg", finish("peer", -3.5), -3.5)
        ]
        try Data((peer.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent("peer.jsonl"))
        let child = try [
            event("session_meta", ["id": "batch-child", "thread_source": "subagent", "source": ["subagent": [:]]], -6),
            event("event_msg", finish("child", -0.5), -0.5)
        ]
        try Data((child.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent("child.jsonl"))
        let scanner = CodexLogScanner(sessionsRoot: root,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")),
            threadTitleStore: CodexThreadTitleStore(codexRoot: root.appendingPathComponent("missing-state")))
        let first = try await scanner.scan(now: now)
        try expect(first.completionEvents.map(\.id) == ["batch-main|A", "batch-peer|peer", "batch-main|B"],
                   "Same-log or concurrent completion was lost, duplicated, unsorted or polluted by a subagent")
        try expect(first.latestCompletion?.id == "batch-main|B", "Completion batch changed the legacy latest success")
        try expect(first.completionEvents[0].usage.totalTokens == 100 && first.completionEvents[2].usage.totalTokens == 150,
                   "Completion batching changed per-turn token usage")
        try expect(first.completionEvents[1].source == "CC Switch" && first.completionEvents[1].costUSD == nil
                   && !first.completionEvents[1].usageKnown && first.completionEvents[1].usageDisplayValue == "--",
                   "Earlier external completion acquired a fabricated cost or measured token count")
        let cached = try await scanner.scan(now: now)
        try expect(cached.completionEvents == first.completionEvents, "Unchanged logs produced an unstable completion batch")
        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd()
        let append = try [
            event("event_msg", ["type": "task_started", "turn_id": "C"], 1),
            event("event_msg", tokens(300), 1.5),
            event("event_msg", finish("C", 2), 2)
        ]
        try handle.write(contentsOf: Data((append.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let updated = try await scanner.scan(now: now.addingTimeInterval(3))
        try expect(updated.completionEvents.map(\.id) == first.completionEvents.map(\.id) + ["batch-main|C"],
                   "Incremental scan dropped an earlier unpresented completion")
        try expect(updated.completionEvents.last?.usage.totalTokens == 50, "Incremental completion usage was not kept per turn")
        let expired = try await scanner.scan(now: now.addingTimeInterval(100))
        try expect(expired.completionEvents.isEmpty && expired.latestCompletion?.id == "batch-main|C",
                   "Completion batch freshness erased legacy metadata or replayed stale events")
    }

    private static func testCCSwitchTaskCostSupportsSecondsAndMilliseconds() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let database = root.appendingPathComponent("cc-switch.db")
        let start: Int64 = 1_787_000_000
        let end = start + 10
        let schemaAndRows = """
        CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, settings_config TEXT, website_url TEXT, is_current INTEGER);
        CREATE TABLE provider_endpoints (provider_id TEXT, app_type TEXT, url TEXT);
        CREATE TABLE usage_daily_rollups (provider_id TEXT, app_type TEXT, model TEXT, input_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, output_tokens INTEGER, request_count INTEGER, date TEXT);
        CREATE TABLE proxy_request_logs (provider_id TEXT, app_type TEXT, model TEXT, request_model TEXT, pricing_model TEXT, total_cost_usd TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, created_at INTEGER, data_source TEXT);
        INSERT INTO providers VALUES ('deepseek','codex','DeepSeek','{}','',0);
        INSERT INTO proxy_request_logs VALUES ('deepseek','codex','deepseek-chat','deepseek-chat','deepseek-chat','0.012345',100,20,10,0,\(start + 1),'proxy');
        INSERT INTO proxy_request_logs VALUES ('deepseek','codex','deepseek-chat','deepseek-chat','deepseek-chat','0.023455',200,40,20,0,\((start + 2) * 1000),'proxy');
        INSERT INTO proxy_request_logs VALUES ('_codex_session','codex','deepseek-chat','deepseek-chat','deepseek-chat','9.0',100,20,0,0,\(start + 3),'proxy');
        INSERT INTO proxy_request_logs VALUES ('deepseek','codex','other-model','other-model','other-model','8.0',100,20,0,0,\(start + 4),'proxy');
        INSERT INTO proxy_request_logs VALUES ('deepseek','codex','deepseek-chat','deepseek-chat','deepseek-chat','7.0',100,20,0,0,\(start - 1),'proxy');
        INSERT INTO proxy_request_logs VALUES ('deepseek','codex','deepseek-chat','deepseek-chat','deepseek-chat','6.0',100,20,0,0,\(start + 5),'synthetic');
        """
        try runSQLite(database: database, sql: schemaAndRows)

        let snapshot = await CCSwitchScanner(databaseURL: database).scan(
            taskCostWindow: TaskCostWindow(
                sessionID: "session-external",
                model: "deepseek-chat",
                provider: "custom",
                startedAt: Date(timeIntervalSince1970: TimeInterval(start)),
                completedAt: Date(timeIntervalSince1970: TimeInterval(end))
            )
        )
        guard let taskCost = snapshot.taskCost else {
            throw SelfTestFailure.assertion("CC Switch task cost was not returned")
        }
        try expect(
            abs((taskCost.costUSD ?? -1) - 0.0358) < 0.0000001,
            "CC Switch task cost did not combine seconds and milliseconds rows"
        )
        try expect(taskCost.providers == ["DeepSeek"], "CC Switch task provider is incorrect")
    }

    private static func testCCSwitchInputSemantics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("cc-switch.db")
        let sql = """
        CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, settings_config TEXT, website_url TEXT, is_current INTEGER);
        CREATE TABLE provider_endpoints (provider_id TEXT, app_type TEXT, url TEXT);
        CREATE TABLE usage_daily_rollups (provider_id TEXT, app_type TEXT, model TEXT, input_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, output_tokens INTEGER, request_count INTEGER, date TEXT, input_token_semantics INTEGER);
        CREATE TABLE proxy_request_logs (provider_id TEXT, app_type TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, created_at INTEGER, data_source TEXT, input_token_semantics INTEGER);
        INSERT INTO proxy_request_logs VALUES ('external','codex','fixture',100,20,30,5,strftime('%s','now'),'proxy',0);
        INSERT INTO proxy_request_logs VALUES ('external','codex','fixture',100,20,30,5,strftime('%s','now'),'proxy',1);
        INSERT INTO proxy_request_logs VALUES ('external','codex','fixture',65,20,30,5,strftime('%s','now'),'proxy',2);
        INSERT INTO proxy_request_logs VALUES ('external','codex','fixture',100000,20,30,5,strftime('%s','now'),'synthetic',1);
        """
        try runSQLite(database: database, sql: sql)
        let snapshot = await CCSwitchScanner(databaseURL: database).scan()
        try expect(snapshot.usage.first?.tokens == 365, "CC Switch cache-inclusive rows counted cache twice")
        try expect(snapshot.usage.first?.requests == 3, "Imported or synthetic rows counted as real proxy calls")
    }

    private static func testConfiguredProviderDoesNotOverrideOfficialSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("cc-switch.db")
        let sql = """
        CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, settings_config TEXT, website_url TEXT, is_current INTEGER);
        CREATE TABLE provider_endpoints (provider_id TEXT, app_type TEXT, url TEXT);
        CREATE TABLE usage_daily_rollups (provider_id TEXT, app_type TEXT, model TEXT, input_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, output_tokens INTEGER, request_count INTEGER, date TEXT);
        CREATE TABLE proxy_request_logs (provider_id TEXT, app_type TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, created_at INTEGER, data_source TEXT);
        INSERT INTO providers VALUES ('external','codex','DeepSeek','{"auth":{"OPENAI_API_KEY":"fixture-only-not-a-real-key"}}','',1);
        INSERT INTO provider_endpoints VALUES ('external','codex','https://unsupported.example.invalid');
        """
        try runSQLite(database: database, sql: sql)
        let timestamp = Date().ISO8601Format()
        let events: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "official", "model_provider": "openai"]],
            ["type": "turn_context", "payload": ["model": "official-model"]],
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "without-usage"]]
        ]
        let log = try events.map { raw in
            var value = raw; value["timestamp"] = timestamp
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(log.utf8).write(to: root.appendingPathComponent("official.jsonl"))
        let scanner = CodexLogScanner(sessionsRoot: root, ccSwitchScanner: CCSwitchScanner(databaseURL: database))
        let result = try await scanner.scan()
        try expect(result.currentProvider == "OpenAI" && result.currentSource == "Codex", "Stale configured provider overrode current official session")
        try expect(result.providerBalance == nil, "Other provider balance was bound to an official session")
        try expect(result.latestCompletion?.usageKnown == false, "Missing task usage was shown as measured zero")
    }

    private static func testOfficialQuotaDoesNotBindExternalSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func line(_ type: String, _ payload: [String: Any], _ offset: Double) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
                "timestamp": now.addingTimeInterval(offset).ISO8601Format()]), as: UTF8.self)
        }
        let official = try [line("session_meta", ["id": "official", "model_provider": "openai"], -10),
            line("turn_context", ["model": "official-model"], -9),
            line("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": [
                "primary": ["used_percent": 20, "window_minutes": 300, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970],
                "secondary": ["used_percent": 40, "window_minutes": 10080, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970]]], -8)]
        let external = try [line("session_meta", ["id": "external", "model_provider": "custom"], -2),
            line("turn_context", ["model": "external-model"], -1)]
        try Data(official.joined(separator: "\n").appending("\n").utf8).write(to: root.appendingPathComponent("official.jsonl"))
        try Data(external.joined(separator: "\n").appending("\n").utf8).write(to: root.appendingPathComponent("external.jsonl"))
        let scanner = CodexLogScanner(sessionsRoot: root, ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")))
        let result = try await scanner.scan(now: now)
        try expect(result.currentModel == "external-model" && result.usesExternalModel, "External session identity was lost")
        try expect(result.currentSource == "Codex 外部模型", "External session incorrectly claimed to use configured CC Switch")
        try expect(result.quota == nil && result.secondaryQuota == nil && result.quotaUpdatedAt == nil,
            "Old official quota leaked into an external session")
        try expect(result.effectiveQuota(now: now) == nil && result.providerBalance == nil, "Unavailable external balance was fabricated")
    }

    private static func testCompletionNoticeGate() throws {
        let now = Date(timeIntervalSince1970: 1_787_000_100)
        var gate = CompletionNoticeGate()
        let existing = completionNotice(id: "old", completedAt: now.addingTimeInterval(-10))
        try expect(gate.nextNotice(from: existing, now: now) == nil, "startup completion should only seed the gate")

        let fresh = completionNotice(id: "fresh", completedAt: now.addingTimeInterval(-2))
        try expect(gate.nextNotice(from: fresh, now: now)?.id == "fresh", "fresh completion was not emitted")
        try expect(gate.nextNotice(from: fresh, now: now) == nil, "completion was emitted twice")

        let stale = completionNotice(id: "stale", completedAt: now.addingTimeInterval(-100))
        try expect(gate.nextNotice(from: stale, now: now) == nil, "stale completion was emitted")
    }

    private static func testQuotaDeltaCalculator() throws {
        let reset = Date(timeIntervalSince1970: 1_787_241_518)
        let laterReset = reset.addingTimeInterval(60)
        try expect(
            QuotaDeltaCalculator.delta(
                startUsedPercent: 37.5,
                startResetAt: reset,
                endUsedPercent: 38.25,
                endResetAt: reset
            ) == 0.75,
            "quota delta for one reset window is incorrect"
        )
        try expect(
            QuotaDeltaCalculator.delta(
                startUsedPercent: 37.5,
                startResetAt: reset,
                endUsedPercent: 38.25,
                endResetAt: laterReset
            ) == nil,
            "quota delta crossed reset windows"
        )
        try expect(
            QuotaDeltaCalculator.delta(
                startUsedPercent: 50,
                startResetAt: reset,
                endUsedPercent: 49,
                endResetAt: reset
            ) == nil,
            "quota delta accepted a decreasing used percentage"
        )
        try expect(
            QuotaDeltaCalculator.delta(
                startUsedPercent: nil,
                startResetAt: reset,
                endUsedPercent: 38.25,
                endResetAt: reset
            ) == nil,
            "quota delta accepted a missing baseline"
        )
    }

    private static func testCompletionMetricFormatting() throws {
        let completedAt = Date(timeIntervalSince1970: 1_787_000_100)
        let external = TaskCompletionNotice(
            id: "external",
            sessionID: "session",
            turnID: "turn",
            title: "External",
            provider: "DeepSeek",
            model: "deepseek-chat",
            source: "CC Switch",
            usage: TokenUsage(totalTokens: 100),
            quotaUsedPercent: nil,
            costUSD: 0.0358,
            startedAt: completedAt.addingTimeInterval(-10),
            completedAt: completedAt
        )
        try expect(external.secondaryMetricTitle == "费用约", "external cost title is misleading")
        try expect(external.secondaryMetricValue == "$0.0358", "external cost formatting is incorrect")

        let missingCost = TaskCompletionNotice(
            id: "external-missing",
            sessionID: "session",
            turnID: "turn",
            title: "External",
            provider: "CC Switch",
            model: "unknown",
            source: "CC Switch",
            usage: .zero,
            quotaUsedPercent: nil,
            costUSD: nil,
            startedAt: completedAt.addingTimeInterval(-10),
            completedAt: completedAt
        )
        try expect(missingCost.secondaryMetricValue == "未返回", "missing external price looks like free usage")

        let belowPrecision = TaskCompletionNotice(
            id: "official",
            sessionID: "session",
            turnID: "turn",
            title: "Official",
            provider: "OpenAI",
            model: "gpt-5.6",
            source: "Codex",
            usage: .zero,
            quotaUsedPercent: 0,
            costUSD: nil,
            startedAt: completedAt.addingTimeInterval(-10),
            completedAt: completedAt
        )
        try expect(belowPrecision.secondaryMetricValue == "<1%", "zero quota delta overstates precision")
    }

    private static func completionNotice(id: String, completedAt: Date) -> TaskCompletionNotice {
        TaskCompletionNotice(
            id: id,
            sessionID: "session",
            turnID: id,
            title: "Test",
            provider: "OpenAI",
            model: "gpt-5.6",
            source: "Codex",
            usage: TokenUsage(totalTokens: 100),
            quotaUsedPercent: 0.5,
            costUSD: nil,
            startedAt: completedAt.addingTimeInterval(-10),
            completedAt: completedAt
        )
    }

    private static func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            throw SelfTestFailure.assertion("sqlite fixture failed: \(String(decoding: data, as: UTF8.self))")
        }
    }

}
