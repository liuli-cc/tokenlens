import Foundation

actor CodexLogScanner {
    private let sessionsRoot: URL
    private var cache: [URL: CachedSession] = [:]
    private let tokenMarker = Data("\"token_count\"".utf8)
    private let contextMarker = Data("\"turn_context\"".utf8)
    private let taskMarker = Data("\"task_started\"".utf8)
    private let taskAbortedMarker = Data("\"turn_aborted\"".utf8)
    private let taskCompleteMarker = Data("\"task_complete\"".utf8)
    private let sessionMarker = Data("\"session_meta\"".utf8)
    private let ccSwitchScanner: CCSwitchScanner
    private let threadTitleStore: CodexThreadTitleStore

    init(
        sessionsRoot: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
            .appendingPathComponent("sessions", isDirectory: true),
        ccSwitchScanner: CCSwitchScanner = CCSwitchScanner(),
        threadTitleStore: CodexThreadTitleStore = CodexThreadTitleStore()
    ) {
        self.sessionsRoot = sessionsRoot
        self.ccSwitchScanner = ccSwitchScanner
        self.threadTitleStore = threadTitleStore
    }

    func scan(now: Date = Date(), historyDays: Int = 7) async throws -> UsageSnapshot {
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

        var observed = Set<URL>()
        var digests: [SessionDigest] = []

        for url in try sessionFiles(resourceKeys: resourceKeys) {
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
        let latestCompletion = digests
            .filter(\.isUserThread)
            .compactMap(\.latestCompletion)
            .max { $0.completedAt < $1.completedAt }
        let completionQuotaUsedPercent = latestCompletion.flatMap { completion in
            quotaUsedPercent(for: completion, across: digests)
        }
        let ccSwitch = await ccSwitchScanner.scan(
            taskCostWindow: latestCompletion.map(TaskCostWindow.init)
        )
        let completionTitle = latestCompletion.flatMap { completion in
            threadTitleStore.title(for: completion.sessionID)
                ?? completion.fallbackTitle.nonEmpty
        }
        return makeSnapshot(
            from: digests,
            ccSwitch: ccSwitch,
            latestCompletion: latestCompletion,
            completionTitle: completionTitle,
            completionQuotaUsedPercent: completionQuotaUsedPercent,
            now: now,
            historyStart: historyStart,
            historyDays: historyDays,
            filesObserved: observed.count
        )
    }

    private func sessionFiles(resourceKeys: Set<URLResourceKey>) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            throw ScannerError.cannotEnumerate(sessionsRoot.path)
        }
        return enumerator.allObjects.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
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
        if line.range(of: taskCompleteMarker) != nil {
            guard let event = try? JSONDecoder().decode(TaskCompleteEnvelope.self, from: line),
                  event.type == "event_msg",
                  event.payload.type == "task_complete" else { return }
            finishTask(
                turnID: event.payload.turnID,
                startedAt: event.payload.startedAt.map(Date.init(timeIntervalSince1970:)),
                completedAt: event.payload.completedAt.map(Date.init(timeIntervalSince1970:)),
                timestamp: event.timestamp.flatMap(parseDateString),
                digest: &digest
            )
            return
        }

        let relevant = line.range(of: tokenMarker) != nil ||
            line.range(of: contextMarker) != nil ||
            line.range(of: taskMarker) != nil ||
            line.range(of: taskAbortedMarker) != nil ||
            line.range(of: sessionMarker) != nil
        guard relevant,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }

        let timestamp = parseDate(object["timestamp"])
        let topLevelType = object["type"] as? String
        let eventType = payload["type"] as? String

        if topLevelType == "session_meta" {
            guard !digest.hasReadIdentity else { return }
            digest.hasReadIdentity = true
            if let sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String),
               !sessionID.isEmpty {
                digest.sessionID = sessionID
            }
            let threadSource = payload["thread_source"] as? String
            let sourceIsSubagent = payload["source"] is [String: Any]
            digest.isUserThread = !sourceIsSubagent
                && (threadSource == nil || threadSource == "user")
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

        if topLevelType == "event_msg", eventType == "turn_aborted" {
            digest.activeTurnID = nil
            digest.activeTaskStartedAt = nil
            digest.activeTaskUsage = .zero
            digest.latestEventAt = maxDate(digest.latestEventAt, timestamp)
            return
        }

        if eventType == "task_started" {
            digest.activeTurnID = payload["turn_id"] as? String
            digest.activeTaskStartedAt = dateFromEpoch(payload["started_at"]) ?? timestamp
            digest.activeTaskUsage = .zero
            digest.activeTaskQuotaUsedPercent = digest.quota?.usedPercent
            digest.activeTaskQuotaResetAt = digest.quota?.resetsAt
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
            if digest.activeTurnID != nil {
                digest.activeTaskUsage = digest.activeTaskUsage + delta
            }

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
            if let timestamp {
                digest.quotaSamples.append(
                    QuotaSample(
                        usedPercent: used,
                        resetsAt: digest.quota?.resetsAt,
                        recordedAt: timestamp
                    )
                )
            }
        }
        digest.latestTokenAt = timestamp
        digest.latestEventAt = maxDate(digest.latestEventAt, timestamp)
    }

    private func finishTask(
        turnID rawTurnID: String?,
        startedAt rawStartedAt: Date?,
        completedAt rawCompletedAt: Date?,
        timestamp: Date?,
        digest: inout SessionDigest
    ) {
        let turnID = rawTurnID ?? digest.activeTurnID ?? ""
        let completedAt = rawCompletedAt ?? timestamp
        let startedAt = rawStartedAt ?? digest.activeTaskStartedAt ?? completedAt
        if digest.latestCompletion?.turnID == turnID {
            digest.latestEventAt = maxDate(digest.latestEventAt, completedAt ?? timestamp)
            return
        }
        if !turnID.isEmpty,
           !digest.sessionID.isEmpty,
           let completedAt {
            let quotaUsedPercent: Double?
            quotaUsedPercent = QuotaDeltaCalculator.delta(
                startUsedPercent: digest.activeTaskQuotaUsedPercent,
                startResetAt: digest.activeTaskQuotaResetAt,
                endUsedPercent: digest.quota?.usedPercent,
                endResetAt: digest.quota?.resetsAt
            )
            digest.latestCompletion = RawTaskCompletion(
                id: "\(digest.sessionID)|\(turnID)",
                sessionID: digest.sessionID,
                turnID: turnID,
                fallbackTitle: digest.currentConversationTitle,
                model: digest.currentModel.nonEmpty ?? "未知模型",
                provider: digest.currentProvider,
                usage: digest.activeTaskUsage,
                quotaUsedPercent: quotaUsedPercent,
                quotaEndUsedPercent: digest.quota?.usedPercent,
                quotaResetAt: digest.quota?.resetsAt,
                startedAt: startedAt ?? completedAt,
                completedAt: completedAt
            )
        }
        digest.activeTurnID = nil
        digest.activeTaskStartedAt = nil
        digest.activeTaskQuotaUsedPercent = nil
        digest.activeTaskQuotaResetAt = nil
        digest.activeTaskUsage = .zero
        digest.latestEventAt = maxDate(digest.latestEventAt, completedAt ?? timestamp)
    }

    private func quotaUsedPercent(
        for completion: RawTaskCompletion,
        across digests: [SessionDigest]
    ) -> Double? {
        if let taskLocalDelta = completion.quotaUsedPercent {
            return taskLocalDelta
        }
        guard let resetAt = completion.quotaResetAt else { return nil }
        let baseline = digests
            .flatMap(\.quotaSamples)
            .filter { sample in
                sample.recordedAt <= completion.startedAt && sample.resetsAt == resetAt
            }
            .max { $0.recordedAt < $1.recordedAt }
        return QuotaDeltaCalculator.delta(
            startUsedPercent: baseline?.usedPercent,
            startResetAt: baseline?.resetsAt,
            endUsedPercent: completion.quotaEndUsedPercent,
            endResetAt: completion.quotaResetAt
        )
    }

    private func makeSnapshot(
        from digests: [SessionDigest],
        ccSwitch: CCSwitchSnapshot,
        latestCompletion: RawTaskCompletion?,
        completionTitle: String?,
        completionQuotaUsedPercent: Double?,
        now: Date,
        historyStart: Date,
        historyDays: Int,
        filesObserved: Int
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
        let completionNotice = latestCompletion.map { completion in
            let providerIdentity = completion.provider.lowercased()
            let usesExternalModel = ccSwitch.taskCost != nil
                || (providerIdentity != "openai"
                    && providerIdentity != "default"
                    && !providerIdentity.contains("official"))
            let completionProvider = ccSwitch.taskCost?.providers.joined(separator: " / ").nonEmpty
                ?? (providerIdentity == "custom" ? "CC Switch" : displayProvider(completion.provider))
            return TaskCompletionNotice(
                id: completion.id,
                sessionID: completion.sessionID,
                turnID: completion.turnID,
                title: completionTitle ?? "任务已完成",
                provider: completionProvider,
                model: completion.model,
                source: usesExternalModel ? "CC Switch" : "Codex",
                usage: completion.usage,
                quotaUsedPercent: usesExternalModel ? nil : completionQuotaUsedPercent,
                costUSD: usesExternalModel ? ccSwitch.taskCost?.costUSD : nil,
                startedAt: completion.startedAt,
                completedAt: completion.completedAt
            )
        }

        return UsageSnapshot(
            currentModel: active?.currentModel.nonEmpty ?? "等待 Codex",
            currentProvider: activeProvider,
            currentSource: activeSource,
            currentSessionUsage: active?.latestTotal ?? .zero,
            lastCallUsage: active?.lastCall ?? .zero,
            contextWindow: active?.contextWindow ?? 0,
            quota: quotaDigest?.quota,
            providerBalance: activeCCProvider == nil ? nil : ccSwitch.providerBalance,
            providerRechargeURL: activeCCProvider == nil ? nil : ccSwitch.providerRechargeURL,
            dailyUsage: days,
            modelUsage: models,
            configuredModels: ccSwitch.configuredModels,
            sessionsToday: sessionsToday,
            lastEventAt: active?.latestEventAt,
            filesObserved: filesObserved,
            latestCompletion: completionNotice,
            isTaskRunning: digests.contains { $0.isUserThread && $0.activeTurnID != nil && now.timeIntervalSince($0.latestEventAt ?? .distantPast) < 600 }
        )
    }

    private func normalizedConversationTitle(_ raw: String) -> String? {
        let title = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let placeholders = ["none", "null", "n/a", "auto"]
        guard !title.isEmpty,
              title.count <= 300,
              !placeholders.contains(title.lowercased()) else { return nil }
        return title
    }

    private func displayProvider(_ raw: String) -> String {
        switch raw.lowercased() {
        case "openai": return "OpenAI"
        case "unknown", "": return "未知提供商"
        default: return raw
        }
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
        return parseDateString(string)
    }

    private func parseDateString(_ string: String) -> Date? {
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

private struct TaskCompleteEnvelope: Decodable {
    let timestamp: String?
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let turnID: String?
        let startedAt: Double?
        let completedAt: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
            case startedAt = "started_at"
            case completedAt = "completed_at"
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
    var hasReadIdentity = false
    var isUserThread = false
    var currentModel = ""
    var currentProvider = "openai"
    var currentConversationTitle = ""
    var latestTotal: TokenUsage = .zero
    var previousTotal: TokenUsage = .zero
    var lastCall: TokenUsage = .zero
    var contextWindow: Int64 = 0
    var quota: RateLimitWindow?
    var quotaEventAt: Date?
    var quotaSamples: [QuotaSample] = []
    var latestTokenAt: Date?
    var latestEventAt: Date?
    var dailyUsage: [Date: TokenUsage] = [:]
    var modelTotals: [ModelIdentity: Int64] = [:]
    var unattributedTokens: Int64 = 0
    var activeTurnID: String?
    var activeTaskStartedAt: Date?
    var activeTaskUsage: TokenUsage = .zero
    var activeTaskQuotaUsedPercent: Double?
    var activeTaskQuotaResetAt: Date?
    var latestCompletion: RawTaskCompletion?
}

private struct RawTaskCompletion: Sendable {
    let id: String
    let sessionID: String
    let turnID: String
    let fallbackTitle: String
    let model: String
    let provider: String
    let usage: TokenUsage
    let quotaUsedPercent: Double?
    let quotaEndUsedPercent: Double?
    let quotaResetAt: Date?
    let startedAt: Date
    let completedAt: Date
}

private struct QuotaSample: Sendable {
    let usedPercent: Double
    let resetsAt: Date?
    let recordedAt: Date
}

struct TaskCostWindow: Sendable {
    let sessionID: String
    let model: String
    let provider: String
    let startedAt: Date
    let completedAt: Date

    init(
        sessionID: String,
        model: String,
        provider: String,
        startedAt: Date,
        completedAt: Date
    ) {
        self.sessionID = sessionID
        self.model = model
        self.provider = provider
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    fileprivate init(_ completion: RawTaskCompletion) {
        sessionID = completion.sessionID
        model = completion.model
        provider = completion.provider
        startedAt = completion.startedAt
        completedAt = completion.completedAt
    }

    var isLikelyExternal: Bool {
        let normalized = provider.lowercased()
        return !normalized.isEmpty
            && normalized != "openai"
            && normalized != "default"
            && !normalized.contains("official")
    }
}

struct CCSwitchTaskCost: Equatable, Sendable {
    let costUSD: Double?
    let providers: [String]
}

struct CodexThreadTitleStore: Sendable {
    private let codexRoot: URL

    init(codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)) {
        self.codexRoot = codexRoot
    }

    func title(for sessionID: String) -> String? {
        guard isSafeSessionID(sessionID) else { return nil }
        if let database = newestStateDatabase() {
            let sql = """
            SELECT COALESCE(NULLIF(name, ''), NULLIF(title, ''), '')
            FROM threads
            WHERE id = '\(sessionID)'
            LIMIT 1;
            """
            if let title = query(sql, database: database).first?.first.flatMap(normalizedTitle) {
                return title
            }
        }
        return indexTitle(for: sessionID)
    }

    private func indexTitle(for sessionID: String) -> String? {
        let indexURL = codexRoot.appendingPathComponent("session_index.jsonl")
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["id"] as? String == sessionID,
                  let rawTitle = (object["thread_name"] as? String) ?? (object["title"] as? String),
                  let title = normalizedTitle(rawTitle) else { continue }
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
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return [] }
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

    private func normalizedTitle(_ raw: String) -> String? {
        let title = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let placeholders = ["none", "null", "n/a", "auto"]
        guard !title.isEmpty,
              title.count <= 300,
              !placeholders.contains(title.lowercased()),
              !title.lowercased().hasPrefix("the following is the codex agent history") else { return nil }
        return title
    }

    private func isSafeSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0.value == 45
        }
    }
}

private struct ModelIdentity: Hashable, Sendable {
    let provider: String
    let model: String
    let source: String
}

struct CCSwitchSnapshot: Sendable {
    var activeProvider: String?
    var providerBalance: ProviderBalance?
    var providerRechargeURL: URL?
    var configuredModels: [ConfiguredModel] = []
    var usage: [ModelUsage] = []
    var taskCost: CCSwitchTaskCost? = nil
}

struct CCSwitchScanner: Sendable {
    private let databaseURL: URL
    private let balanceReader = ProviderBalanceReader()

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-switch/cc-switch.db")) {
        self.databaseURL = databaseURL
    }

    func scan(taskCostWindow: TaskCostWindow? = nil) async -> CCSwitchSnapshot {
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
        SELECT p.id,
               p.name,
               COALESCE(e.url, ''),
               COALESCE(json_extract(p.settings_config, '$.auth.OPENAI_API_KEY'), ''),
               COALESCE(p.website_url, '')
        FROM providers p
        LEFT JOIN provider_endpoints e ON e.provider_id=p.id AND e.app_type=p.app_type
        WHERE p.app_type='codex' AND p.is_current=1
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
          AND (CASE
                WHEN l.created_at > 100000000000 THEN l.created_at / 1000
                ELSE l.created_at
               END) >= CAST(strftime('%s','now','-30 day') AS INTEGER)
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
        let activeCredentials = query(providerSQL).first.flatMap(ProviderCredentials.init(columns:))
        let activeProvider = activeCredentials?.name
        let providerBalance = await balanceReader.balance(for: activeCredentials)
        let taskCost = taskCostWindow.flatMap(readTaskCost)

        return CCSwitchSnapshot(
            activeProvider: activeProvider,
            providerBalance: providerBalance,
            providerRechargeURL: activeCredentials?.rechargeURL,
            configuredModels: configured,
            usage: usage,
            taskCost: taskCost
        )
    }

    private func readTaskCost(window: TaskCostWindow) -> CCSwitchTaskCost? {
        guard window.isLikelyExternal else { return nil }
        let start = Int64(window.startedAt.timeIntervalSince1970.rounded(.down))
        let end = Int64(window.completedAt.timeIntervalSince1970.rounded(.up))
        let model = sqlLiteral(window.model)
        let sql = """
        SELECT COALESCE(p.name, l.provider_id),
               l.total_cost_usd,
               l.input_tokens + l.output_tokens + l.cache_read_tokens + l.cache_creation_tokens
        FROM proxy_request_logs l
        LEFT JOIN providers p ON p.id=l.provider_id AND p.app_type=l.app_type
        WHERE l.app_type='codex'
          AND substr(l.provider_id, 1, 1) != '_'
          AND COALESCE(l.data_source, 'proxy')='proxy'
          AND (l.model='\(model)' OR l.request_model='\(model)' OR l.pricing_model='\(model)')
          AND (CASE
                WHEN l.created_at > 100000000000 THEN l.created_at / 1000
                ELSE l.created_at
               END) BETWEEN \(start) AND \(end);
        """
        var rows = query(sql)
        if rows.isEmpty {
            let fallbackSQL = """
            SELECT COALESCE(p.name, l.provider_id),
                   l.total_cost_usd,
                   l.input_tokens + l.output_tokens + l.cache_read_tokens + l.cache_creation_tokens
            FROM proxy_request_logs l
            LEFT JOIN providers p ON p.id=l.provider_id AND p.app_type=l.app_type
            WHERE l.app_type='codex'
              AND substr(l.provider_id, 1, 1) != '_'
              AND COALESCE(l.data_source, 'proxy')='proxy'
              AND (CASE
                    WHEN l.created_at > 100000000000 THEN l.created_at / 1000
                    ELSE l.created_at
                   END) BETWEEN \(start) AND \(end);
            """
            rows = query(fallbackSQL)
        }
        guard !rows.isEmpty else { return nil }

        var providers = Set<String>()
        var total = Decimal.zero
        var recordedTokens: Int64 = 0
        for columns in rows where columns.count >= 3 {
            if !columns[0].isEmpty {
                providers.insert(columns[0])
            }
            if let value = Decimal(string: columns[1], locale: Locale(identifier: "en_US_POSIX")) {
                total += value
            }
            recordedTokens += Int64(columns[2]) ?? 0
        }
        let costUSD = total == .zero && recordedTokens > 0
            ? nil
            : NSDecimalNumber(decimal: total).doubleValue
        return CCSwitchTaskCost(
            costUSD: costUSD,
            providers: providers.sorted()
        )
    }

    private func sqlLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func query(_ sql: String) -> [[String]] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let readOnlyURI = "file:\(databaseURL.path)?mode=ro"
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

private struct ProviderCredentials: Sendable {
    let id: String
    let name: String
    let baseURL: String
    let apiKey: String
    let websiteURL: String

    init?(columns: [String]) {
        guard columns.count >= 5,
              !columns[0].isEmpty,
              !columns[1].isEmpty,
              !columns[3].isEmpty else { return nil }
        id = columns[0]
        name = columns[1]
        baseURL = columns[2]
        apiKey = columns[3]
        websiteURL = columns[4]
    }

    var isExternal: Bool {
        let normalized = name.lowercased()
        return normalized != "default" && !normalized.contains("official")
    }

    var rechargeURL: URL? {
        ProviderRechargeURLResolver.url(
            providerName: name,
            baseURL: baseURL,
            websiteURL: websiteURL
        )
    }
}

enum ProviderRechargeURLResolver {
    static func url(providerName: String, baseURL: String, websiteURL: String) -> URL? {
        let identity = "\(providerName) \(baseURL)".lowercased()

        if identity.contains("deepseek") {
            return URL(string: "https://platform.deepseek.com/top_up")
        }
        if identity.contains("kimi") || identity.contains("moonshot") {
            return URL(string: "https://platform.kimi.com/console/pay")
        }
        if identity.contains("glm") || identity.contains("zhipu") || identity.contains("bigmodel") {
            return URL(string: "https://open.bigmodel.cn/console/usercenter/expense")
        }
        if identity.contains("siliconflow") {
            let host = identity.contains("siliconflow.com") && !identity.contains("siliconflow.cn")
                ? "https://cloud.siliconflow.com/account/billing"
                : "https://cloud.siliconflow.cn/account/billing"
            return URL(string: host)
        }
        if identity.contains("openrouter") {
            return URL(string: "https://openrouter.ai/settings/credits")
        }
        if identity.contains("novita") {
            return URL(string: "https://novita.ai/settings/billing")
        }
        if identity.contains("stepfun") {
            return URL(string: "https://platform.stepfun.com/")
        }

        guard !websiteURL.isEmpty else { return nil }
        return URL(string: websiteURL)
    }
}

private actor ProviderBalanceReader {
    private struct CachedBalance: Sendable {
        let value: ProviderBalance?
        let fetchedAt: Date
    }

    private var cache: [String: CachedBalance] = [:]

    func balance(for credentials: ProviderCredentials?) async -> ProviderBalance? {
        guard let credentials, credentials.isExternal else { return nil }
        if let cached = cache[credentials.id],
           Date().timeIntervalSince(cached.fetchedAt) < 45 {
            return cached.value
        }

        let result = await fetchOfficialBalance(credentials)
        cache[credentials.id] = CachedBalance(value: result, fetchedAt: Date())
        return result
    }

    private func fetchOfficialBalance(_ credentials: ProviderCredentials) async -> ProviderBalance? {
        let identity = "\(credentials.name) \(credentials.baseURL)".lowercased()
        if identity.contains("deepseek") {
            return await requestDeepSeekBalance(credentials)
        }
        if identity.contains("kimi") || identity.contains("moonshot") {
            return await requestKimiBalance(credentials)
        }
        if identity.contains("glm") || identity.contains("zhipu") || identity.contains("bigmodel") {
            return await requestGLMBalance(credentials)
        }
        return nil
    }

    private func requestDeepSeekBalance(_ credentials: ProviderCredentials) async -> ProviderBalance? {
        guard let object = await requestJSON(path: "/user/balance", credentials: credentials),
              object["is_available"] as? Bool == true,
              let infos = object["balance_infos"] as? [[String: Any]] else { return nil }

        let amounts = infos.compactMap { info -> ProviderBalance.Amount? in
            guard let currency = info["currency"] as? String,
                  let value = numeric(info["total_balance"]) else { return nil }
            return ProviderBalance.Amount(currency: currency, value: value)
        }
        return amounts.isEmpty ? nil : ProviderBalance(amounts: amounts, fetchedAt: Date())
    }

    private func requestKimiBalance(_ credentials: ProviderCredentials) async -> ProviderBalance? {
        guard let object = await requestJSON(path: "/users/me/balance", credentials: credentials),
              let data = object["data"] as? [String: Any],
              let value = numeric(data["available_balance"]) else { return nil }
        return ProviderBalance(
            amounts: [.init(currency: inferredCurrency(for: credentials), value: value)],
            fetchedAt: Date()
        )
    }

    private func requestGLMBalance(_ credentials: ProviderCredentials) async -> ProviderBalance? {
        // GLM has no documented balance endpoint. Only surface a value if a
        // compatible deployment explicitly returns one from its credit route.
        guard let object = await requestJSON(path: "/user/credit", credentials: credentials) else { return nil }
        let data = (object["data"] as? [String: Any]) ?? object
        let candidates = ["available_balance", "balance", "credit", "total_balance"]
        guard let value = candidates.compactMap({ numeric(data[$0]) }).first else { return nil }
        return ProviderBalance(
            amounts: [.init(currency: inferredCurrency(for: credentials), value: value)],
            fetchedAt: Date()
        )
    }

    private func requestJSON(path: String, credentials: ProviderCredentials) async -> [String: Any]? {
        guard let url = balanceURL(baseURL: credentials.baseURL, path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func balanceURL(baseURL: String, path: String) -> URL? {
        guard var components = URLComponents(string: baseURL),
              let host = components.host,
              !host.isEmpty else { return nil }
        let cleanPath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        let requiredPath: String
        if path == "/user/balance" {
            requiredPath = cleanPath.hasSuffix("/v1")
                ? String(cleanPath.dropLast(3)) + path
                : cleanPath + path
        } else {
            requiredPath = cleanPath + path
        }
        components.path = requiredPath.replacingOccurrences(of: "//", with: "/")
        return components.url
    }

    private func inferredCurrency(for credentials: ProviderCredentials) -> String {
        credentials.baseURL.lowercased().contains("moonshot.cn") ? "CNY" : "CNY"
    }

    private func numeric(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
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
