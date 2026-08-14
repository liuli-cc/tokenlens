import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private let scanner: CodexLogScanner

    init(scanner: CodexLogScanner = CodexLogScanner()) {
        self.scanner = scanner
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        Task {
            do {
                let newSnapshot = try await scanner.scan()
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
