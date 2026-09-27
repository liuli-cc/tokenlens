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

    private let scanner: CodexLogScanner
    private let deepSeekStatusReader = DeepSeekStatusReader()
    private let deepSeekActivityReader = DeepSeekActivityReader()
    private var completionGate = CompletionNoticeGate()
    private var deepSeekCompletionGate = CompletionNoticeGate()
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
            do {
                let refreshedSnapshot = try await scanner.scan(now: refreshedAt)
                snapshot = refreshedSnapshot
                if let notice = completionGate.nextNotice(from: refreshedSnapshot.latestCompletion, now: refreshedAt) {
                    pendingNotices[.chatGPT] = notice
                }
                lastUpdated = refreshedAt
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
            deepSeekActivity = await activity
            if let notice = deepSeekCompletionGate.nextNotice(from: deepSeekActivity.latestCompletion, now: refreshedAt) {
                pendingNotices[.deepSeek] = notice
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

    private func synchronizeNotice() {
        pendingNotices = pendingNotices.filter { Date().timeIntervalSince($0.value.completedAt) < 90 }
        let next = pendingNotices[activeAssistant]
        if completionNotice != next { completionNotice = next }
    }
}
