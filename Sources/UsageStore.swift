import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionNotice: TaskCompletionNotice?
    @Published private(set) var activeAssistant: IslandAssistant = .chatGPT
    @Published private(set) var deepSeekStatus: DeepSeekStatusSnapshot
    @Published private(set) var deepSeekActivity = DeepSeekActivitySnapshot()
    @Published private(set) var additionalSnapshots: [IslandAssistant: UsageSnapshot] = [:]

    private let scanner: CodexLogScanner
    private let deepSeekStatusReader = DeepSeekStatusReader()
    private let deepSeekActivityReader = DeepSeekActivityReader()
    private let additionalReader = AdditionalAssistantReader()
    private var completionGates: [IslandAssistant: CompletionNoticeGate] = [:]
    private var pendingNotices: [IslandAssistant: TaskCompletionNotice] = [:]
    private let refreshEnabled: Bool

    init(scanner: CodexLogScanner = CodexLogScanner(), refreshEnabled: Bool = true) {
        self.scanner = scanner
        self.refreshEnabled = refreshEnabled
        deepSeekStatus = refreshEnabled ? DeepSeekStatusReader().read() : .empty
    }

    func refresh() {
        guard refreshEnabled, !isScanning else { return }
        let refreshedDeepSeekStatus = deepSeekStatusReader.read()
        if refreshedDeepSeekStatus != deepSeekStatus { deepSeekStatus = refreshedDeepSeekStatus }
        isScanning = true
        Task {
            let refreshedAt = Date()
            async let activity = deepSeekActivityReader.read(now: refreshedAt)
            async let additional = additionalReader.read(now: refreshedAt)
            do {
                let refreshedSnapshot = try await scanner.scan(now: refreshedAt)
                snapshot = refreshedSnapshot
                recordCompletion(refreshedSnapshot.latestCompletion, for: .chatGPT, now: refreshedAt)
                lastUpdated = refreshedAt
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                // A failed scan cannot keep a formerly valid balance or quota
                // looking current. Independent readers below still run.
                var failed = UsageSnapshot.empty
                failed.currentModel = "模型未读取"
                failed.currentProvider = "GPT"
                failed.currentSource = snapshot.currentSource
                failed.metricsSource = snapshot.metricsSource
                failed.metricsDiagnostic = "本机读取失败：\(error.localizedDescription)；等待下次刷新"
                snapshot = failed
                pendingNotices.removeValue(forKey: .chatGPT)
            }
            deepSeekActivity = await activity
            recordCompletion(deepSeekActivity.latestCompletion, for: .deepSeek, now: refreshedAt)
            additionalSnapshots = await additional
            for assistant in [.workBuddy, .claude, .codeBuddy] as [IslandAssistant] {
                recordCompletion(additionalSnapshots[assistant]?.latestCompletion, for: assistant, now: refreshedAt)
            }
            synchronizeNotice()
            isScanning = false
        }
    }

    func dismissCompletionNotice(id: String) {
        pendingNotices = pendingNotices.filter { $0.value.id != id }
        guard completionNotice?.id == id else { return }
        completionNotice = nil
    }

    func setActiveAssistant(_ assistant: IslandAssistant) {
        guard activeAssistant != assistant else { return }
        activeAssistant = assistant
        synchronizeNotice()
    }

    var activeSnapshot: UsageSnapshot {
        switch activeAssistant {
        case .chatGPT: return snapshot
        case .deepSeek:
            var usage = deepSeekActivity.usageSnapshot
            if !deepSeekStatus.modelName.hasPrefix("等待") { usage.currentModel = deepSeekStatus.modelName }
            if usage.currentModel == UsageSnapshot.empty.currentModel { usage.currentModel = "模型未读取" }
            if usage.currentProvider == UsageSnapshot.empty.currentProvider { usage.currentProvider = deepSeekStatus.providerName }
            usage.currentSource = "DeepSeek Harness"
            usage.isTaskRunning = deepSeekActivity.isRunning
            return usage
        case .workBuddy, .claude, .codeBuddy:
            if let data = additionalSnapshots[activeAssistant] { return data }
            var unavailable = UsageSnapshot.empty
            unavailable.currentModel = "模型未读取"
            unavailable.currentProvider = activeAssistant.displayName
            unavailable.currentSource = activeAssistant.displayName
            unavailable.metricsDiagnostic = "尚未发现此软件的可读取用量数据"
            return unavailable
        }
    }

    var activeMetricValue: String {
        if activeAssistant == .deepSeek { return deepSeekStatus.balanceDisplayValue }
        let data = activeSnapshot
        return data.usesExternalModel || data.providerBalance != nil
            ? data.balanceDisplayValue : data.quotaDisplayValue
    }

    var activeMetricTitle: String {
        if activeAssistant == .deepSeek { return "账户余额" }
        let data = activeSnapshot
        return data.usesExternalModel || data.providerBalance != nil ? "账户余额" : "剩余额度"
    }

    var activeMetricDetail: String {
        if activeAssistant == .deepSeek {
            guard let updated = deepSeekStatus.balanceUpdatedAt else { return deepSeekStatus.balanceDiagnostic }
            return deepSeekStatus.balanceDiagnostic + " · " + updated.formatted(date: .omitted, time: .shortened)
        }
        let data = activeSnapshot
        if let balance = data.providerBalance {
            return "官方接口 · " + balance.fetchedAt.formatted(date: .omitted, time: .shortened)
        }
        if let quota = data.effectiveQuota(), let reset = quota.resetsAt {
            let window = quota.windowMinutes >= 1_440 ? "\(quota.windowMinutes / 1_440) 天窗口" : "\(quota.windowMinutes) 分钟窗口"
            let name = (data.quotaLimitName ?? data.quotaLimitID).map { "\($0) · " } ?? ""
            return "\(name)\(window) · \(reset.formatted(date: .abbreviated, time: .shortened)) 重置"
        }
        return data.quotaUpdatedAt == nil ? "未取得账户额度数据" : "额度缓存已过期，等待新的服务器数据"
    }

    private func recordCompletion(_ completion: TaskCompletionNotice?, for assistant: IslandAssistant, now: Date) {
        var gate = completionGates[assistant] ?? CompletionNoticeGate()
        if let notice = gate.nextNotice(from: completion, now: now) { pendingNotices[assistant] = notice }
        completionGates[assistant] = gate
    }

    private func synchronizeNotice() {
        pendingNotices = pendingNotices.filter { Date().timeIntervalSince($0.value.completedAt) < 90 }
        let next = pendingNotices[activeAssistant]
        if completionNotice != next { completionNotice = next }
    }
}
