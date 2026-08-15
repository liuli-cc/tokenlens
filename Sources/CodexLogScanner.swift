import Foundation

actor CodexLogScanner {
    private let sessionsRoot: URL
    private var cache: [URL: CachedSession] = [:]
    private let tokenMarker = Data("\"token_count\"".utf8)
    private let contextMarker = Data("\"turn_context\"".utf8)
    private let taskMarker = Data("\"task_started\"".utf8)
    private let sessionMarker = Data("\"session_meta\"".utf8)
    private let ccSwitchScanner: CCSwitchScanner
    private let threadTitleStore: CodexThreadTitleStore

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        ccSwitchScanner: CCSwitchScanner = CCSwitchScanner(),
        threadTitleStore: CodexThreadTitleStore = CodexThreadTitleStore()
    ) {
        self.sessionsRoot = sessionsRoot
        self.ccSwitchScanner = ccSwitchScanner
        self.threadTitleStore = threadTitleStore
    }

    func scan(now: Date = Date(), historyDays: Int = 7) throws -> UsageSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            throw ScannerError.sessionsDirectoryMissing(sessionsRoot.path)
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let historyStart = calendar.date(byAdding: .day, value: -(historyDays - 1), to: today) ?? today
        let includeAfter = calendar.date(byAdding: .day, value: -1, to: historyStart) ?? historyStart

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            throw ScannerError.cannotEnumerate(sessionsRoot.path)
        }

        var observed = Set<URL>()
        var digests: [SessionDigest] = []

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= includeAfter else { continue }

            let size = UInt64(max(0, values.fileSize ?? 0))
            observed.insert(url)
            let entry = try updateCache(for: url, size: size, modifiedAt: modifiedAt)
            digests.append(entry.digest)
        }

        cache = cache.filter { observed.contains($0.key) }
        let ccSwitch = ccSwitchScanner.scan()
        let active = digests.max {
            ($0.latestEventAt ?? .distantPast) < ($1.latestEventAt ?? .distantPast)
        }
        let threadTitle = threadTitleStore.currentTitle(for: active?.sessionID)
        return makeSnapshot(
            from: digests,
            ccSwitch: ccSwitch,
            now: now,
            historyStart: historyStart,
            historyDays: historyDays,
            filesObserved: observed.count,
            threadTitle: threadTitle
        )
    }

    private func updateCache(for url: URL, size: UInt64, modifiedAt: Date) throws -> CachedSession {
        if var cached = cache[url], cached.size <= size {
            guard cached.size != size || cached.modifiedAt != modifiedAt else { return cached }
            try parseAppend(url: url, from: cached.size, into: &cached)
            cached.size = size
            cached.modifiedAt = modifiedAt
            cache[url] = cached
            return cached
        }

        var fresh = CachedSession(
            size: 0,
            modifiedAt: modifiedAt,
            trailingData: Data(),
            digest: SessionDigest(url: url)
        )
        try parseAppend(url: url, from: 0, into: &fresh)
        fresh.size = size
        cache[url] = fresh
        return fresh
    }

    private func parseAppend(url: URL, from offset: UInt64, into cached: inout CachedSession) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ScannerError.cannotOpen(url.path)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var buffer = cached.trailingData
        cached.trailingData = Data()

        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex

            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: lineStart..<newline)
                process(line: line, into: &cached.digest)
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        cached.trailingData = buffer
    }

    private func process(line: Data, into digest: inout SessionDigest) {
        let relevant = line.range(of: tokenMarker) != nil ||
            line.range(of: contextMarker) != nil ||
            line.range(of: taskMarker) != nil ||
            line.range(of: sessionMarker) != nil
        guard relevant,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }

        let timestamp = parseDate(object["timestamp"])
        let topLevelType = object["type"] as? String
        let eventType = payload["type"] as? String

        if topLevelType == "session_meta" {
            if let sessionID = payload["session_id"] as? String, !sessionID.isEmpty {
                digest.sessionID = sessionID
            }
            if let provider = payload["model_provider"] as? String, !provider.isEmpty {
                digest.currentProvider = provider
            }
            digest.latestEventAt = maxDate(digest.latestEventAt, timestamp)
            return
        }

        if topLevelType == "turn_context" {
            if let model = payload["model"] as? String, !model.isEmpty {
                digest.currentModel = model
                if digest.unattributedTokens > 0 {
                    let provider = digest.currentProvider.isEmpty ? "unknown" : digest.currentProvider
                    let identity = ModelIdentity(provider: provider, model: model, source: "Codex")
                    digest.modelTotals[identity, default: 0] += digest.unattributedTokens
                    digest.unattributedTokens = 0
                }
            }
            if let summary = payload["summary"] as? String,
               let title = normalizedConversationTitle(summary) {
                digest.currentConversationTitle = title
            }
            digest.latestEventAt = maxDate(digest.latestEventAt, timestamp)
            return
        }

        if eventType == "task_started" {
            if let window = int64(payload["model_context_window"]), window > 0 {
                digest.contextWindow = window
            }
            digest.latestEventAt = maxDate(digest.latestEventAt, timestamp)
            return
        }

        guard eventType == "token_count",
              let info = payload["info"] as? [String: Any] else { return }

        if let totalObject = info["total_token_usage"] as? [String: Any] {
            let currentTotal = parseUsage(totalObject)
            var delta = currentTotal - digest.previousTotal
            if currentTotal.totalTokens < digest.previousTotal.totalTokens {
                delta = currentTotal
            }
            digest.previousTotal = currentTotal
            digest.latestTotal = currentTotal

            if let timestamp {
                let day = Calendar.current.startOfDay(for: timestamp)
                digest.dailyUsage[day, default: .zero] = digest.dailyUsage[day, default: .zero] + delta
                if digest.currentModel.isEmpty {
                    digest.unattributedTokens += delta.totalTokens
                } else {
                    let provider = digest.currentProvider.isEmpty ? "unknown" : digest.currentProvider
                    let identity = ModelIdentity(provider: provider, model: digest.currentModel, source: "Codex")
                    digest.modelTotals[identity, default: 0] += delta.totalTokens
                }
            }
        }

        if let lastObject = info["last_token_usage"] as? [String: Any] {
            digest.lastCall = parseUsage(lastObject)
        }
        if let window = int64(info["model_context_window"]), window > 0 {
            digest.contextWindow = window
        }
        if let limits = payload["rate_limits"] as? [String: Any],
           let primary = limits["primary"] as? [String: Any],
           let used = double(primary["used_percent"]) {
            digest.quota = RateLimitWindow(
                usedPercent: used,
                windowMinutes: Int(int64(primary["window_minutes"]) ?? 0),
                resetsAt: dateFromEpoch(primary["resets_at"]),
                planType: limits["plan_type"] as? String
            )
            digest.quotaEventAt = timestamp
        }
        digest.latestTokenAt = timestamp
        digest.latestEventAt = maxDate(digest.latestEventAt, timestamp)
    }

    private func makeSnapshot(
        from digests: [SessionDigest],
        ccSwitch: CCSwitchSnapshot,
        now: Date,
        historyStart: Date,
        historyDays: Int,
        filesObserved: Int,
        threadTitle: String?
    ) -> UsageSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let active = digests.max {
            ($0.latestEventAt ?? .distantPast) < ($1.latestEventAt ?? .distantPast)
        }
        let quotaDigest = digests
            .filter { $0.quota != nil }
            .max { ($0.quotaEventAt ?? .distantPast) < ($1.quotaEventAt ?? .distantPast) }

        var dayTotals: [Date: TokenUsage] = [:]
        var modelTotals: [ModelIdentity: Int64] = [:]
        var sessionsToday = 0

        for digest in digests {
            if digest.dailyUsage[today]?.totalTokens ?? 0 > 0 {
                sessionsToday += 1
            }
            for (day, usage) in digest.dailyUsage where day >= historyStart && day <= today {
                dayTotals[day, default: .zero] = dayTotals[day, default: .zero] + usage
            }
            for (identity, tokens) in digest.modelTotals {
                modelTotals[identity, default: 0] += tokens
            }
        }

        let days = (0..<historyDays).compactMap { offset -> DayUsage? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: historyStart) else { return nil }
            return DayUsage(date: day, usage: dayTotals[day, default: .zero])
        }

        var models: [ModelUsage] = []
        for (identity, tokens) in modelTotals {
            let usage = ModelUsage(
                provider: displayProvider(identity.provider),
                model: identity.model,
                tokens: tokens,
                requests: 0,
                source: identity.source
            )
            models.append(usage)
        }
        models.sort(by: modelUsageComesFirst)

        for external in ccSwitch.usage {
            if let index = models.firstIndex(where: {
                $0.provider == external.provider && $0.model == external.model
            }) {
                models[index] = external
            } else {
                models.append(external)
            }
        }
        models.sort(by: modelUsageComesFirst)

        let activeCCProvider = ccSwitch.activeProvider.flatMap { provider -> String? in
            let normalized = provider.lowercased()
            return (normalized == "default" || normalized.contains("official")) ? nil : provider
        }
        let activeProvider = activeCCProvider ?? displayProvider(active?.currentProvider ?? "openai")
        let activeSource = activeCCProvider == nil ? "Codex" : "CC Switch"

        return UsageSnapshot(
            currentModel: active?.currentModel.nonEmpty ?? "等待 Codex",
            currentProvider: activeProvider,
            currentSource: activeSource,
            currentConversationTitle: threadTitle ?? active?.currentConversationTitle.nonEmpty ?? "当前会话（正在识别标题）",
            currentSessionUsage: active?.latestTotal ?? .zero,
            lastCallUsage: active?.lastCall ?? .zero,
            contextWindow: active?.contextWindow ?? 0,
            quota: quotaDigest?.quota,
            dailyUsage: days,
            modelUsage: models,
            configuredModels: ccSwitch.configuredModels,
            sessionsToday: sessionsToday,
            lastEventAt: active?.latestEventAt,
            filesObserved: filesObserved
        )
    }

    private func displayProvider(_ raw: String) -> String {
        switch raw.lowercased() {
        case "openai": return "OpenAI"
        case "unknown", "": return "未知提供商"
        default: return raw
        }
    }

    private func normalizedConversationTitle(_ raw: String) -> String? {
        let title = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let placeholders = ["none", "null", "n/a", "auto"]
        guard !title.isEmpty,
              !placeholders.contains(title.lowercased()) else { return nil }
        return title
    }

    private func modelUsageComesFirst(_ lhs: ModelUsage, _ rhs: ModelUsage) -> Bool {
        if lhs.tokens == rhs.tokens {
            return lhs.model < rhs.model
        }
        return lhs.tokens > rhs.tokens
    }

    private func parseUsage(_ object: [String: Any]) -> TokenUsage {
        TokenUsage(
            inputTokens: int64(object["input_tokens"]) ?? 0,
            cachedInputTokens: int64(object["cached_input_tokens"]) ?? 0,
            outputTokens: int64(object["output_tokens"]) ?? 0,
            reasoningOutputTokens: int64(object["reasoning_output_tokens"]) ?? 0,
            totalTokens: int64(object["total_tokens"]) ?? 0
        )
    }

    private func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    private func dateFromEpoch(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }
}

private struct CachedSession: Sendable {
    var size: UInt64
    var modifiedAt: Date
    var trailingData: Data
    var digest: SessionDigest
}

private struct SessionDigest: Sendable {
    let url: URL
    var sessionID = ""
    var currentModel = ""
    var currentProvider = "openai"
    var currentConversationTitle = ""
    var latestTotal: TokenUsage = .zero
    var previousTotal: TokenUsage = .zero
    var lastCall: TokenUsage = .zero
    var contextWindow: Int64 = 0
    var quota: RateLimitWindow?
    var quotaEventAt: Date?
    var latestTokenAt: Date?
    var latestEventAt: Date?
    var dailyUsage: [Date: TokenUsage] = [:]
    var modelTotals: [ModelIdentity: Int64] = [:]
    var unattributedTokens: Int64 = 0
}

struct CodexThreadTitleStore: Sendable {
    private let codexRoot: URL

    init(codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)) {
        self.codexRoot = codexRoot
    }

    func currentTitle(for sessionID: String?) -> String? {
        if let title = sqliteCurrentTitle() {
            return title
        }
        guard let sessionID else { return nil }
        return indexTitle(for: sessionID)
    }

    private func sqliteCurrentTitle() -> String? {
        guard let database = newestStateDatabase() else { return nil }
        let sql = """
        SELECT title
        FROM threads
        WHERE archived = 0
          AND thread_source != 'subagent'
          AND title <> ''
        ORDER BY recency_at_ms DESC
        LIMIT 1;
        """
        return query(sql, database: database).first?.first.flatMap(normalizedThreadTitle)
    }

    private func indexTitle(for sessionID: String) -> String? {
        let indexURL = codexRoot.appendingPathComponent("session_index.jsonl")
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["id"] as? String == sessionID,
                  let rawTitle = object["thread_name"] as? String,
                  let title = normalizedThreadTitle(rawTitle) else { continue }
            return title
        }
        return nil
    }

    private func newestStateDatabase() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: codexRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files
            .filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("state_") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private func query(_ sql: String, database: URL) -> [[String]] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-separator", "\t",
            "file:\(database.path)?mode=ro",
            sql
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { line in
                    line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                }
        } catch {
            return []
        }
    }

    private func normalizedThreadTitle(_ raw: String) -> String? {
        let title = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let placeholders = ["none", "null", "n/a", "auto"]
        guard !title.isEmpty,
              title.count <= 300,
              !placeholders.contains(title.lowercased()),
              !title.lowercased().hasPrefix("the following is the codex agent history") else { return nil }
        return title
    }
}

private struct ModelIdentity: Hashable, Sendable {
    let provider: String
    let model: String
    let source: String
}

struct CCSwitchSnapshot: Sendable {
    var activeProvider: String?
    var configuredModels: [ConfiguredModel] = []
    var usage: [ModelUsage] = []
}

struct CCSwitchScanner: Sendable {
    private let databaseURL: URL

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-switch/cc-switch.db")) {
        self.databaseURL = databaseURL
    }

    func scan() -> CCSwitchSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            return CCSwitchSnapshot()
        }

        let configuredSQL = """
        SELECT p.name,
               json_extract(m.value,'$.model'),
               COALESCE(json_extract(m.value,'$.displayName'), json_extract(m.value,'$.model')),
               COALESCE(json_extract(m.value,'$.contextWindow'), 0),
               p.is_current
        FROM providers p,
             json_each(json_extract(p.settings_config,'$.modelCatalog.models')) m
        WHERE p.app_type='codex'
        ORDER BY p.name, m.key;
        """
        let providerSQL = """
        SELECT name FROM providers
        WHERE app_type='codex' AND is_current=1
        LIMIT 1;
        """
        let usageSQL = """
        SELECT COALESCE(p.name, r.provider_id),
               r.model,
               SUM(r.input_tokens + r.cache_read_tokens + r.cache_creation_tokens + r.output_tokens),
               SUM(r.request_count)
        FROM usage_daily_rollups r
        LEFT JOIN providers p ON p.id=r.provider_id AND p.app_type=r.app_type
        WHERE r.app_type='codex'
          AND substr(r.provider_id, 1, 1) != '_'
          AND r.date >= date('now','-30 day')
        GROUP BY COALESCE(p.name, r.provider_id), r.model
        ORDER BY SUM(r.input_tokens + r.cache_read_tokens + r.cache_creation_tokens + r.output_tokens) DESC;
        """
        let liveUsageSQL = """
        SELECT COALESCE(p.name, l.provider_id),
               l.model,
               SUM(l.input_tokens + l.cache_read_tokens + l.cache_creation_tokens + l.output_tokens),
               COUNT(*)
        FROM proxy_request_logs l
        LEFT JOIN providers p ON p.id=l.provider_id AND p.app_type=l.app_type
        WHERE l.app_type='codex'
          AND substr(l.provider_id, 1, 1) != '_'
          AND l.created_at >= CAST(strftime('%s','now','-30 day') AS INTEGER) * 1000
        GROUP BY COALESCE(p.name, l.provider_id), l.model
        ORDER BY SUM(l.input_tokens + l.cache_read_tokens + l.cache_creation_tokens + l.output_tokens) DESC;
        """

        let configured = query(configuredSQL).compactMap { columns -> ConfiguredModel? in
            guard columns.count >= 5,
                  !columns[0].isEmpty,
                  !columns[1].isEmpty else { return nil }
            return ConfiguredModel(
                provider: columns[0],
                model: columns[1],
                displayName: columns[2],
                contextWindow: Int64(columns[3]) ?? 0,
                isCurrentProvider: columns[4] == "1"
            )
        }
        let liveRows = query(liveUsageSQL)
        let usageRows = liveRows.isEmpty ? query(usageSQL) : liveRows
        let usage = usageRows.compactMap { columns -> ModelUsage? in
            guard columns.count >= 4,
                  !columns[0].isEmpty,
                  !columns[1].isEmpty else { return nil }
            return ModelUsage(
                provider: columns[0],
                model: columns[1],
                tokens: Int64(columns[2]) ?? 0,
                requests: Int(columns[3]) ?? 0,
                source: "CC Switch"
            )
        }
        let activeProvider = query(providerSQL).first?.first

        return CCSwitchSnapshot(
            activeProvider: activeProvider,
            configuredModels: configured,
            usage: usage
        )
    }

    private func query(_ sql: String) -> [[String]] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let readOnlyURI = "file:\(databaseURL.path)?mode=ro&immutable=1"
        process.arguments = [
            "-separator", "\t",
            readOnlyURI,
            sql
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { line in
                    line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                }
        } catch {
            return []
        }
    }
}

enum ScannerError: LocalizedError {
    case sessionsDirectoryMissing(String)
    case cannotEnumerate(String)
    case cannotOpen(String)

    var errorDescription: String? {
        switch self {
        case .sessionsDirectoryMissing(let path):
            return "未找到 Codex 日志目录：\(path)"
        case .cannotEnumerate(let path):
            return "无法扫描日志目录：\(path)"
        case .cannotOpen(let path):
            return "无法读取日志文件：\(path)"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
