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
        try await testThreadTitleIndexFallback()
        try await testThreadTitleFromStateDatabase()
        print("TokenLens scanner self-test passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SelfTestFailure.assertion(message) }
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
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")),
            threadTitleStore: CodexThreadTitleStore(codexRoot: root.appendingPathComponent("missing-codex"))
        )
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T12:00:00Z")
        let snapshot = try await scanner.scan(now: now)

        try expect(snapshot.currentModel == "future-codex-model-x", "dynamic model was not detected")
        try expect(snapshot.currentProvider == "third-party-provider", "model provider was not detected")
        try expect(snapshot.currentConversationTitle == "Dashboard context title", "context title was not detected")
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
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")),
            threadTitleStore: CodexThreadTitleStore(codexRoot: root.appendingPathComponent("missing-codex"))
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

    private static func testThreadTitleIndexFallback() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dayFolder = root.appendingPathComponent("2026/08/14", isDirectory: true)
        try fileManager.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: codexRoot)
        }

        let log = dayFolder.appendingPathComponent("rollout-test.jsonl")
        let lines = [
            #"{"timestamp":"2026-08-14T02:00:00.000Z","type":"session_meta","payload":{"session_id":"test-session-index","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-08-14T02:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15},"model_context_window":200000},"rate_limits":null}}"#
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: log)

        let indexURL = codexRoot.appendingPathComponent("session_index.jsonl")
        let indexLine = #"{"id":"test-session-index","thread_name":"Index conversation title"}"# + "\n"
        try Data(indexLine.utf8).write(to: indexURL)

        let store = CodexThreadTitleStore(codexRoot: codexRoot)
        let scanner = CodexLogScanner(
            sessionsRoot: root,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")),
            threadTitleStore: store
        )
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T12:00:00Z")
        let snapshot = try await scanner.scan(now: now)

        try expect(snapshot.currentConversationTitle == "Index conversation title", "session index title was not used")
    }

    private static func testThreadTitleFromStateDatabase() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dayFolder = root.appendingPathComponent("2026/08/14", isDirectory: true)
        try fileManager.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: codexRoot)
        }

        let log = dayFolder.appendingPathComponent("rollout-test.jsonl")
        let lines = [
            #"{"timestamp":"2026-08-14T02:00:00.000Z","type":"session_meta","payload":{"session_id":"test-session-state","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-08-14T02:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15},"model_context_window":200000},"rate_limits":null}}"#
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: log)

        let indexURL = codexRoot.appendingPathComponent("session_index.jsonl")
        let indexLine = #"{"id":"test-session-state","thread_name":"Index conversation title"}"# + "\n"
        try Data(indexLine.utf8).write(to: indexURL)

        let databaseURL = codexRoot.appendingPathComponent("state_9.sqlite")
        let sql = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            recency_at_ms INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            thread_source TEXT NOT NULL DEFAULT ''
        );
        INSERT INTO threads (id, title, recency_at_ms, archived, thread_source) VALUES
            ('test-session-state', 'State conversation title', 1787000000000, 0, 'user'),
            ('test-session-guardian', 'The following is the Codex agent history', 1788000000000, 0, 'subagent');
        """
        let createProcess = Process()
        let createPipe = Pipe()
        createProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        createProcess.arguments = [databaseURL.path, sql]
        createProcess.standardOutput = createPipe
        createProcess.standardError = createPipe
        try createProcess.run()
        createProcess.waitUntilExit()
        guard createProcess.terminationStatus == 0 else {
            throw SelfTestFailure.assertion("failed to create state database")
        }

        let store = CodexThreadTitleStore(codexRoot: codexRoot)
        let scanner = CodexLogScanner(
            sessionsRoot: root,
            ccSwitchScanner: CCSwitchScanner(databaseURL: root.appendingPathComponent("missing.db")),
            threadTitleStore: store
        )
        let now = try Date.ISO8601FormatStyle().parse("2026-08-14T12:00:00Z")
        let snapshot = try await scanner.scan(now: now)

        try expect(snapshot.currentConversationTitle == "State conversation title", "state database title was not used")
    }
}
