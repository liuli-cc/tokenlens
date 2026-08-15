import Foundation

actor CodexLogScanner {
    private let sessionsRoot: URL
    private var cache: [URL: CachedSession] = [:]
    private let tokenMarker = Data("\"token_count\"".utf8)
    private let contextMarker = Data("\"turn_context\"".utf8)
    private let taskMarker = Data("\"task_started\"".utf8)
    private let sessionMarker = Data("\"session_meta\"".utf8)
    private let ccSwitchScanner: CCSwitchScanner

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        ccSwitchScanner: CCSwitchScanner = CCSwitchScanner()
    ) {
        self.sessionsRoot = sessionsRoot
        self.ccSwitchScanner = ccSwitchScanner
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
        let ccSwitch = await ccSwitchScanner.scan()
        return makeSnapshot(
            from: digests,
            ccSwitch: ccSwitch,
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

        return UsageSnapshot(
            currentModel: active?.currentModel.nonEmpty ?? "等待 Codex",
            currentProvider: activeProvider,
            currentSource: activeSource,
            currentSessionUsage: active?.latestTotal ?? .zero,
            lastCallUsage: active?.lastCall ?? .zero,
            contextWindow: active?.contextWindow ?? 0,
            quota: quotaDigest?.quota,
            providerBalance: activeCCProvider == nil ? nil : ccSwitch.providerBalance,
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
    var currentModel = ""
    var currentProvider = "openai"
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

private struct ModelIdentity: Hashable, Sendable {
    let provider: String
    let model: String
    let source: String
}

struct CCSwitchSnapshot: Sendable {
    var activeProvider: String?
    var providerBalance: ProviderBalance?
    var configuredModels: [ConfiguredModel] = []
    var usage: [ModelUsage] = []
}

struct CCSwitchScanner: Sendable {
    private let databaseURL: URL
    private let balanceReader = ProviderBalanceReader()

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-switch/cc-switch.db")) {
        self.databaseURL = databaseURL
    }

    func scan() async -> CCSwitchSnapshot {
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
               COALESCE(json_extract(p.settings_config, '$.auth.OPENAI_API_KEY'), '')
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
        let activeCredentials = query(providerSQL).first.flatMap(ProviderCredentials.init(columns:))
        let activeProvider = activeCredentials?.name
        let providerBalance = await balanceReader.balance(for: activeCredentials)

        return CCSwitchSnapshot(
            activeProvider: activeProvider,
            providerBalance: providerBalance,
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

private struct ProviderCredentials: Sendable {
    let id: String
    let name: String
    let baseURL: String
    let apiKey: String

    init?(columns: [String]) {
        guard columns.count >= 4,
              !columns[0].isEmpty,
              !columns[1].isEmpty,
              !columns[3].isEmpty else { return nil }
        id = columns[0]
        name = columns[1]
        baseURL = columns[2]
        apiKey = columns[3]
    }

    var isExternal: Bool {
        let normalized = name.lowercased()
        return normalized != "default" && !normalized.contains("official")
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
