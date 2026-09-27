import Foundation

struct DeepSeekActivitySnapshot: Equatable, Sendable {
    var isRunning = false
    var latestCompletion: TaskCompletionNotice?
}

/// Only explicit `turn/end` with reason `completed` is a completion. In
/// particular, cancellation, error, blocked, file writes and balance changes
/// must never produce the completion feedback.
struct DeepSeekEventDigest: Sendable {
    var sessionID = ""
    var isUserSession = false
    var activeTurn: Int?
    var startedAt: Date?
    var latestCompletion: TaskCompletionNotice?

    mutating func consume(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return }
        if envelope.type == "session" {
            sessionID = envelope.id ?? ""
            isUserSession = envelope.version == 4 && envelope.delegationDepth == 0
            return
        }
        guard isUserSession, let turn = envelope.data?.turn else { return }
        let time = envelope.time.map { Date(timeIntervalSince1970: $0 / 1000) }
        if envelope.type == "turn/start" {
            activeTurn = turn
            startedAt = time
        } else if envelope.type == "turn/end" {
            defer { if activeTurn == turn { activeTurn = nil; startedAt = nil } }
            guard envelope.data?.reason?.kind == "completed", let time, !sessionID.isEmpty else { return }
            latestCompletion = TaskCompletionNotice(
                id: "dsh|\(sessionID)|\(turn)", sessionID: sessionID, turnID: String(turn),
                title: "DeepSeek 已完成本轮任务", provider: "DeepSeek", model: "DeepSeek Harness",
                source: "DeepSeek Harness", usage: .zero, quotaUsedPercent: nil, costUSD: nil,
                startedAt: startedAt ?? time, completedAt: time
            )
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let id: String?
        let version: Int?
        let delegationDepth: Int?
        let time: Double?
        let data: EventData?
    }
    private struct EventData: Decodable {
        let turn: Int?
        let reason: Reason?
    }
    private struct Reason: Decodable { let kind: String }
}

actor DeepSeekActivityReader {
    private let root: URL
    private var cache: [URL: Entry] = [:]
    private struct Entry { let modified: Date; let size: Int; let digest: DeepSeekEventDigest }

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/sessions")) {
        self.root = root
    }

    func read(now: Date = Date()) -> DeepSeekActivitySnapshot {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return .init() }
        var candidates: [(url: URL, modified: Date, size: Int)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "session.v4.jsonl.zstd" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, let size = values.fileSize,
                  now.timeIntervalSince(modified) < 86_400,
                  size < 64 * 1_024 * 1_024 else { continue }
            candidates.append((url, modified, size))
        }
        let recent = candidates.sorted { $0.modified > $1.modified }.prefix(32)
        let seen = Set(recent.map(\.url))
        var decoded = 0
        for item in recent {
            if cache[item.url]?.modified == item.modified && cache[item.url]?.size == item.size { continue }
            guard decoded < 4 else { continue }
            decoded += 1
            if let digest = Self.decompress(item.url) {
                cache[item.url] = Entry(modified: item.modified, size: item.size, digest: digest)
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return DeepSeekActivitySnapshot(
            isRunning: cache.values.contains { $0.digest.activeTurn != nil && now.timeIntervalSince($0.modified) < 600 },
            latestCompletion: cache.values.compactMap(\.digest.latestCompletion).max { $0.completedAt < $1.completedAt }
        )
    }

    private static func decompress(_ url: URL) -> DeepSeekEventDigest? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zstd").path
        let candidates = [bundled, "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-dcq", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        var digest = DeepSeekEventDigest()
        var pending = Data()
        var bytesRead = 0
        while let data = try? pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
            bytesRead += data.count
            // Malformed or unexpectedly large logs never stall a UI refresh.
            if bytesRead > 128 * 1_024 * 1_024 { process.terminate(); break }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                // Decode only lifecycle envelopes, never message text or tool output.
                if line.range(of: Data("\"turn/start\"".utf8)) != nil ||
                    line.range(of: Data("\"turn/end\"".utf8)) != nil ||
                    line.range(of: Data("\"session\"".utf8)) != nil {
                    digest.consume(Data(line))
                }
                pending.removeSubrange(...end)
            }
        }
        process.waitUntilExit()
        // Concurrent appends can leave an incomplete zstd frame; retry next poll.
        guard process.terminationStatus == 0 else { return nil }
        return digest
    }
}
