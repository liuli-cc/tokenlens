import Foundation

struct IslandModelText: Equatable {
    let primary: String
    let secondary: String?
}

enum IslandCompactText {
    /// Split meaningful model identifiers rather than replacing the name with
    /// an icon. The unchanged identifier remains available in help/expanded UI.
    static func model(_ raw: String) -> IslandModelText {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        if lower.hasPrefix("gpt-") {
            let parts = name.dropFirst(4).split(separator: "-", maxSplits: 1)
            if let version = parts.first {
                return .init(primary: "GPT-" + version,
                             secondary: parts.count > 1 ? String(parts[1]).uppercased() : nil)
            }
        }
        if lower.hasPrefix("deepseek-") || lower.hasPrefix("deepseek ") {
            let detail = name.dropFirst(9).trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(primary: "DeepSeek", secondary: detail.isEmpty ? nil : detail)
        }
        if lower.hasPrefix("claude-") {
            return .init(primary: "Claude", secondary: String(name.dropFirst(7)))
        }
        let words = name.split(separator: " ", maxSplits: 1)
        if words.count == 2 {
            return .init(primary: String(words[0]), secondary: String(words[1]))
        }
        return .init(primary: name.isEmpty ? "等待模型" : name, secondary: nil)
    }

    /// Currency symbols and percent signs are semantic: never turn a balance
    /// into a quota, nor turn unreadable data or a small nonzero balance into 0.
    static func metric(_ raw: String, characterBudget: Int = 7) -> String {
        let full = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasSuffix("%"), let value = Double(full.dropLast()), value.isFinite {
            if characterBudget <= 4, value > 0, value < 1 { return "<1%" }
            return number(value, fractionDigits: characterBudget <= 4 ? 0 : 1) + "%"
        }
        let first = full.components(separatedBy: " / ").first ?? full
        guard let symbol = first.first, "¥$€£".contains(symbol),
              let value = Double(first.dropFirst().replacingOccurrences(of: ",", with: "")), value.isFinite else {
            return first.isEmpty ? "--" : first
        }
        let magnitude = abs(value)
        let unit: (Double, String)? = magnitude >= 1_000_000_000 ? (1_000_000_000, "B")
            : (magnitude >= 1_000_000 ? (1_000_000, "M") : (magnitude >= 1_000 ? (1_000, "K") : nil))
        guard let (divisor, suffix) = unit else { return first }
        return String(symbol) + number(value / divisor, fractionDigits: characterBudget <= 4 ? 0 : 1) + suffix
    }

    private static func number(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
