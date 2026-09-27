import Foundation

enum IslandAssistant: Hashable, Sendable {
    case chatGPT
    case deepSeek
}

struct DeepSeekWallet: Decodable, Equatable, Sendable {
    let currency: String
    let balance: String
}

struct DeepSeekBridgePayload: Decodable {
    let accountStatus: String?
    let balanceStatus: String?
    let balance: [DeepSeekWallet]?
    let bonusWallets: [DeepSeekWallet]?
    let provider: String?
    let model: String?
    let modelLabel: String?
    let reasoningEffort: String?
    let workspacePath: String?
    let balanceUpdatedAt: String?
}

struct DeepSeekStatusSnapshot: Equatable, Sendable {
    let modelName: String
    let reasoningEffort: String?
    let balanceDisplayValue: String
    let bonusDisplayValue: String
    let accountDisplayValue: String
    let workspaceName: String
    let providerName: String
    let balanceUpdatedAt: Date?

    static let empty = DeepSeekStatusSnapshot(
        modelName: "等待 Harness",
        reasoningEffort: nil,
        balanceDisplayValue: "--",
        bonusDisplayValue: "--",
        accountDisplayValue: "等待账号数据",
        workspaceName: "默认工作区",
        providerName: "DeepSeek Harness",
        balanceUpdatedAt: nil
    )

    private init(
        modelName: String,
        reasoningEffort: String?,
        balanceDisplayValue: String,
        bonusDisplayValue: String,
        accountDisplayValue: String,
        workspaceName: String,
        providerName: String,
        balanceUpdatedAt: Date?
    ) {
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
        self.balanceDisplayValue = balanceDisplayValue
        self.bonusDisplayValue = bonusDisplayValue
        self.accountDisplayValue = accountDisplayValue
        self.workspaceName = workspaceName
        self.providerName = providerName
        self.balanceUpdatedAt = balanceUpdatedAt
    }

    fileprivate init(payload: DeepSeekBridgePayload) {
        let isSignedIn = payload.accountStatus == "credential-stored"
        modelName = payload.modelLabel ?? payload.model ?? "等待模型"
        reasoningEffort = payload.reasoningEffort
        accountDisplayValue = isSignedIn ? "已登录" : "未登录"
        providerName = "DeepSeek Harness"
        workspaceName = payload.workspacePath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "默认工作区"
        balanceUpdatedAt = Self.date(from: payload.balanceUpdatedAt)

        let wallets = payload.balance ?? []
        let bonusWallets = payload.bonusWallets ?? []
        if !isSignedIn {
            balanceDisplayValue = "未登录"
        } else if payload.balanceStatus != "ready" {
            balanceDisplayValue = "暂不可读"
        } else {
            balanceDisplayValue = Self.display(wallets.first(where: { $0.currency == "CNY" }) ?? wallets.first)
        }
        bonusDisplayValue = isSignedIn
            ? (Self.display(bonusWallets.first(where: { $0.currency == "CNY" }) ?? bonusWallets.first, empty: "暂无"))
            : "--"
    }

    private static func display(_ wallet: DeepSeekWallet?, empty: String = "--") -> String {
        guard let wallet else { return empty }
        let symbol = wallet.currency == "CNY" ? "¥" : (wallet.currency == "USD" ? "$" : "")
        guard let amount = Decimal(string: wallet.balance, locale: Locale(identifier: "en_US_POSIX")) else {
            return symbol + wallet.balance
        }
        let fractionalBalance = amount != .zero && abs(amount) < Decimal(string: "0.01")!
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = fractionalBalance ? 4 : 2
        formatter.maximumFractionDigits = fractionalBalance ? 4 : 2
        return symbol + (formatter.string(from: NSDecimalNumber(decimal: amount)) ?? wallet.balance)
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct DeepSeekStatusReader {
    private let statusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TokenLens/deepseek-status.json")

    func read() -> DeepSeekStatusSnapshot {
        guard let data = try? Data(contentsOf: statusURL),
              let payload = try? JSONDecoder().decode(DeepSeekBridgePayload.self, from: data) else {
            return .empty
        }
        return DeepSeekStatusSnapshot(payload: payload)
    }
}
