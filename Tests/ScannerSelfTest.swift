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
        try await testDynamicModelAndMetrics()
        try await testIncrementalRefresh()
        try testRechargeURLResolution()
        print("TokenLens scanner self-test passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SelfTestFailure.assertion(message) }
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
        try expect(snapshot.quota?.remainingPercent == 62.5, "remaining quota is incorrect")
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

}
