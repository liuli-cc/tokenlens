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
    var currentConversationTitle: String = "当前会话（正在识别标题）"
    var currentSessionUsage: TokenUsage = .zero
    var lastCallUsage: TokenUsage = .zero
    var contextWindow: Int64 = 0
    var quota: RateLimitWindow?
    var dailyUsage: [DayUsage] = []
    var modelUsage: [ModelUsage] = []
    var configuredModels: [ConfiguredModel] = []
    var sessionsToday: Int = 0
    var lastEventAt: Date?
    var filesObserved: Int = 0

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
