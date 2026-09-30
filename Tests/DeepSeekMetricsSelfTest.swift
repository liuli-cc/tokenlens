import Foundation

@main struct DeepSeekMetricsSelfTest {
    static func main() throws {
        func expect(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }
        func event(_ type: String, _ seq: Int, _ data: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "seq": seq, "time": seq * 1000, "data": data])
        }
        var digest = DeepSeekEventDigest()
        digest.consume(Data(#"{"type":"session","version":4,"delegationDepth":0,"id":"fixture"}"#.utf8))
        let usage: [String: Any] = ["inputTokens": 100, "cacheReadTokens": 200, "cacheWriteTokens": 50,
            "outputTokens": 40, "totalTokens": 390, "reasoningTokens": 20]
        digest.consume(try event("assistant/message", 1, ["usage": usage]))
        try expect(!digest.usageKnown, "Copied seed incorrectly counted as a new billable response")
        digest.consume(try event("session/end-seed", 2, [:]))
        digest.consume(try event("request/context", 3, ["provider": "deepseek", "model": "real-model", "contextWindow": 1000]))
        let call = try event("assistant/message", 4, ["usage": usage, "message": ["source": ["provider": "deepseek", "model": "real-model"]]])
        digest.consume(call); digest.consume(call)
        try expect(digest.usage.totalTokens == 390, "Reasoning or repeated usage counted twice")
        try expect(digest.usage.inputTokens == 350, "Cache input omitted from the full-input denominator")
        try expect(digest.usage.cachedInputTokens == 200 && digest.cacheKnown, "Cache read measurement incorrect")
        try expect(digest.samples.count == 1, "Duplicate durable event counted as two calls")
        try expect(digest.contextWindow == 1000, "Reported context window was discarded")
        digest.consume(try event("assistant/attempt", 5, ["stream": [["type": "usage", "usage": ["inputTokens": 70, "outputTokens": 10, "totalTokens": 100]]]]))
        try expect(digest.usage.totalTokens == 490 && digest.lastUsage.inputTokens == 90, "Exact total from attempt stream was not preserved")
        try expect(!digest.cacheKnown, "Missing cache metadata falsely reported as zero cache hits")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let statusFile = root.appendingPathComponent("status.json"), now = Date()
        let payload: [String: Any] = ["accountStatus": "credential-stored", "balanceStatus": "ready",
            "balanceFetchedAt": now.ISO8601Format(), "balance": [["currency": "CNY", "balance": "0.0012"]],
            "bonusWallets": [["currency": "CNY", "balance": "1.00"]]]
        try JSONSerialization.data(withJSONObject: payload).write(to: statusFile)
        let reader = DeepSeekStatusReader(statusURL: statusFile)
        try expect(reader.read(now: now).balanceDisplayValue == "¥0.0012", "Small positive official balance rounded to zero")
        try expect(reader.read(now: now.addingTimeInterval(181)).balanceDisplayValue == "暂不可读", "Stale official balance shown as current")
        try expect(reader.read(now: now.addingTimeInterval(181)).bonusDisplayValue == "--", "Stale bonus remained visible")
        print("DeepSeek metrics self-test passed: exact usage, cache denominator, seed/duplicate filtering and balance freshness")
    }
}
