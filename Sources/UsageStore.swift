import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private let scanner: CodexLogScanner
    private let contextTitleReader: ChatGPTContextTitleReader

    init(
        scanner: CodexLogScanner = CodexLogScanner(),
        contextTitleReader: ChatGPTContextTitleReader = ChatGPTContextTitleReader()
    ) {
        self.scanner = scanner
        self.contextTitleReader = contextTitleReader
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        Task {
            do {
                var newSnapshot = try await scanner.scan()
                if newSnapshot.currentConversationTitle == UsageSnapshot.empty.currentConversationTitle,
                   let title = contextTitleReader.currentTitle() {
                    newSnapshot.currentConversationTitle = title
                }
                snapshot = newSnapshot
                lastUpdated = Date()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }
}
