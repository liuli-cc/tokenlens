import Foundation

/// In-memory metadata only. Completion detection remains the reader's job;
/// neither foreground changes nor usage changes manufacture success events.
struct CompletionNoticeQueue: Sendable {
    private struct Pending: Sendable {
        let notice: TaskCompletionNotice
        let observedAt: Date
    }

    private let historyLimit: Int
    private let pendingLimit: Int
    private let deduplicationLimit: Int
    private let freshness: TimeInterval
    private let pendingRetention: TimeInterval
    private var baselineDates: [IslandAssistant: Date] = [:]
    private var seenIDs = Set<String>()
    private var seenOrder: [String] = []
    private var pending: [Pending] = []
    private(set) var recentCompletions: [TaskCompletionNotice] = []

    init(historyLimit: Int = 20, pendingLimit: Int = 128,
         deduplicationLimit: Int = 512, freshness: TimeInterval = 90,
         pendingRetention: TimeInterval = 600) {
        self.historyLimit = max(1, historyLimit)
        self.pendingLimit = max(1, pendingLimit)
        self.deduplicationLimit = max(1, deduplicationLimit)
        self.freshness = max(0, freshness)
        self.pendingRetention = max(0, pendingRetention)
    }

    var current: TaskCompletionNotice? { pending.first?.notice }
    var count: Int { pending.count }

    mutating func observe(_ completion: TaskCompletionNotice?, for assistant: IslandAssistant,
                          now: Date = Date()) {
        observe(completion.map { [$0] } ?? [], for: assistant, now: now)
    }

    mutating func observe(_ completions: [TaskCompletionNotice], for assistant: IslandAssistant,
                          now: Date = Date()) {
        observe([assistant: completions], now: now)
    }

    mutating func observe(_ completionsByAssistant: [IslandAssistant: [TaskCompletionNotice]],
                          now: Date = Date()) {
        expireWaitingNotices(now: now)
        // The first read seeds each independent source even when it is empty.
        // A subsequently selected old session must not replay startup history.
        var eligible: [(notice: TaskCompletionNotice, assistant: IslandAssistant, baseline: Date)] = []
        for assistant in IslandAssistant.allCases {
            guard let completions = completionsByAssistant[assistant] else { continue }
            guard let baseline = baselineDates[assistant] else {
                // Codex completed_at can have whole-second precision. Rounding
                // the startup cutoff down avoids losing a genuinely new turn
                // that finishes in that same second; known history is seeded by ID.
                baselineDates[assistant] = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
                for completion in completions { remember(key(for: completion, assistant: assistant)) }
                continue
            }
            eligible += CompletionEventBatch.recent(completions, now: now, freshness: freshness)
                .map { ($0, assistant, baseline) }
        }
        eligible.sort {
            if $0.notice.completedAt != $1.notice.completedAt { return $0.notice.completedAt < $1.notice.completedAt }
            if $0.assistant != $1.assistant { return $0.assistant.rawValue < $1.assistant.rawValue }
            return $0.notice.id < $1.notice.id
        }
        for event in eligible {
            append(event.notice, for: event.assistant, baseline: event.baseline, now: now)
        }
    }

    private mutating func append(_ completion: TaskCompletionNotice, for assistant: IslandAssistant,
                                 baseline: Date, now: Date) {
        let identity = key(for: completion, assistant: assistant)
        guard !seenIDs.contains(identity) else { return }
        let age = now.timeIntervalSince(completion.completedAt)
        guard completion.completedAt >= baseline, age >= -5, age <= freshness else { return }
        // Pending and history provide additional identity protection if a very
        // busy source has evicted an entry from the bounded deduplication set.
        guard !pending.contains(where: { $0.notice.id == completion.id && $0.notice.source == completion.source }),
              !recentCompletions.contains(where: { $0.id == completion.id && $0.source == completion.source }) else { return }
        remember(identity)
        pending.append(Pending(notice: completion, observedAt: now))
        if pending.count > pendingLimit {
            // Preserve the notice already on screen when bounding a backlog.
            pending.removeSubrange(1..<(pending.count - pendingLimit + 1))
        }
        recentCompletions.insert(completion, at: 0)
        if recentCompletions.count > historyLimit {
            recentCompletions.removeLast(recentCompletions.count - historyLimit)
        }
    }

    mutating func dismiss(id: String, now: Date = Date()) {
        // Only the current presentation may advance the FIFO. A stale timeout
        // cannot erase a later queued completion from another assistant.
        guard current?.id == id else { return }
        pending.removeFirst()
        pending.removeAll { now.timeIntervalSince($0.observedAt) > pendingRetention }
    }

    private mutating func expireWaitingNotices(now: Date) {
        guard pending.count > 1 else { return }
        let first = pending.removeFirst()
        pending.removeAll { now.timeIntervalSince($0.observedAt) > pendingRetention }
        pending.insert(first, at: 0)
    }

    private func key(for completion: TaskCompletionNotice, assistant: IslandAssistant) -> String {
        assistant.rawValue + "|" + completion.id
    }

    private mutating func remember(_ identity: String) {
        guard seenIDs.insert(identity).inserted else { return }
        seenOrder.append(identity)
        if seenOrder.count > deduplicationLimit {
            let expired = seenOrder.removeFirst()
            seenIDs.remove(expired)
        }
    }
}
