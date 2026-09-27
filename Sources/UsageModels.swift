import Foundation

struct TokenUsage: Equatable, Sendable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var totalTokens: Int64 = 0

    static let zero = TokenUsage()

    static func - (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: max(0, lhs.inputTokens - rhs.inputTokens),
            cachedInputTokens: max(0, lhs.cachedInputTokens - rhs.cachedInputTokens),
            outputTokens: max(0, lhs.outputTokens - rhs.outputTokens),
            reasoningOutputTokens: max(0, lhs.reasoningOutputTokens - rhs.reasoningOutputTokens),
            totalTokens: max(0, lhs.totalTokens - rhs.totalTokens)
        )
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }
}

struct RateLimitWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
    var planType: String?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

struct ProviderBalance: Equatable, Sendable {
    struct Amount: Equatable, Sendable {
        let currency: String
        let value: Double

        var displayValue: String {
            let valueText = String(format: "%.2f", value)
            switch currency.uppercased() {
            case "CNY", "RMB": return "¥\(valueText)"
            case "USD": return "$\(valueText)"
            default: return "\(currency.uppercased()) \(valueText)"
            }
        }
    }

    let amounts: [Amount]
    let fetchedAt: Date

    var displayValue: String {
        amounts.map(\.displayValue).joined(separator: " / ")
    }
}

struct TaskCompletionNotice: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String
    let title: String
    let provider: String
    let model: String
    let source: String
    let usage: TokenUsage
    let quotaUsedPercent: Double?
    let costUSD: Double?
    let startedAt: Date
    let completedAt: Date

    var isDeepSeek: Bool { source == "DeepSeek Harness" }

    var usesExternalModel: Bool {
        source == "CC Switch"
    }

    var secondaryMetricTitle: String {
        usesExternalModel ? "费用约" : "额度消耗"
    }

    var secondaryMetricValue: String {
        if usesExternalModel {
            guard let costUSD else { return "未返回" }
            if costUSD > 0, costUSD < 0.0001 {
                return "<$0.0001"
            }
            let digits = costUSD < 1 ? 4 : 2
            return String(format: "$%.*f", digits, costUSD)
        }
        guard let quotaUsedPercent else { return "未返回" }
        if quotaUsedPercent == 0 { return "<1%" }
        return quotaUsedPercent.oneDecimalPercent
    }
}

enum QuotaDeltaCalculator {
    static func delta(
        startUsedPercent: Double?,
        startResetAt: Date?,
        endUsedPercent: Double?,
        endResetAt: Date?
    ) -> Double? {
        guard let startUsedPercent,
              let startResetAt,
              let endUsedPercent,
              let endResetAt,
              startResetAt == endResetAt,
              endUsedPercent >= startUsedPercent else { return nil }
        return endUsedPercent - startUsedPercent
    }
}

struct CompletionNoticeGate: Sendable {
    private(set) var hasSeeded = false
    private(set) var lastCompletionID: String?

    mutating func nextNotice(
        from completion: TaskCompletionNotice?,
        now: Date = Date(),
        freshness: TimeInterval = 90
    ) -> TaskCompletionNotice? {
        guard hasSeeded else {
            hasSeeded = true
            lastCompletionID = completion?.id
            return nil
        }

        guard let completion,
              completion.id != lastCompletionID else { return nil }
        lastCompletionID = completion.id

        let age = now.timeIntervalSince(completion.completedAt)
        guard age >= -5, age <= freshness else { return nil }
        return completion
    }
}

struct DayUsage: Identifiable, Equatable, Sendable {
    let date: Date
    let usage: TokenUsage

    var id: Date { date }
}

struct ModelUsage: Identifiable, Equatable, Sendable {
    let provider: String
    let model: String
    let tokens: Int64
    let requests: Int
    let source: String

    var id: String { "\(source)|\(provider)|\(model)" }
}

struct ConfiguredModel: Identifiable, Equatable, Sendable {
    let provider: String
    let model: String
    let displayName: String
    let contextWindow: Int64
    let isCurrentProvider: Bool

    var id: String { "\(provider)|\(model)" }
}

struct UsageSnapshot: Equatable, Sendable {
    var currentModel: String = "等待 Codex"
    var currentProvider: String = "OpenAI"
    var currentSource: String = "Codex"
    var currentSessionUsage: TokenUsage = .zero
    var lastCallUsage: TokenUsage = .zero
    var contextWindow: Int64 = 0
    var quota: RateLimitWindow?
    var providerBalance: ProviderBalance?
    var providerRechargeURL: URL?
    var dailyUsage: [DayUsage] = []
    var modelUsage: [ModelUsage] = []
    var configuredModels: [ConfiguredModel] = []
    var sessionsToday: Int = 0
    var lastEventAt: Date?
    var filesObserved: Int = 0
    var latestCompletion: TaskCompletionNotice? = nil
    var isTaskRunning = false

    static let empty = UsageSnapshot()

    var cacheHitRate: Double {
        guard currentSessionUsage.inputTokens > 0 else { return 0 }
        return min(100, max(0,
            Double(currentSessionUsage.cachedInputTokens) /
            Double(currentSessionUsage.inputTokens) * 100
        ))
    }

    var contextUsedPercent: Double {
        guard contextWindow > 0 else { return 0 }
        return min(100, max(0,
            Double(lastCallUsage.totalTokens) / Double(contextWindow) * 100
        ))
    }

    var todayUsage: TokenUsage {
        dailyUsage.last?.usage ?? .zero
    }

    var usesExternalModel: Bool {
        currentSource == "CC Switch"
    }

    var quotaMetricTitle: String {
        usesExternalModel ? "余额" : "剩余额度"
    }

    var sharedQuotaMetricTitle: String {
        usesExternalModel ? "官方余额" : "共享额度剩余"
    }

    var balanceDisplayValue: String {
        providerBalance?.displayValue ?? "不可读取"
    }
}

extension Int64 {
    var compactTokenString: String {
        let value = Double(self)
        if value >= 1_000_000 {
            return Self.format(value / 1_000_000, suffix: "M")
        }
        if value >= 1_000 {
            return Self.format(value / 1_000, suffix: "K")
        }
        return "\(self)"
    }

    private static func format(_ value: Double, suffix: String) -> String {
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.*f%@", digits, value, suffix)
    }
}

extension Double {
    var oneDecimalPercent: String {
        String(format: "%.1f%%", self)
    }
}
