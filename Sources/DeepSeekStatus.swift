import Foundation

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
    let balanceFetchedAt: String?
    let balanceAttemptedAt: String?
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
    var balanceIsFresh = false
    var balanceDiagnostic = "等待官方余额"

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

    fileprivate init(payload: DeepSeekBridgePayload, now: Date = Date()) {
        let isSignedIn = payload.accountStatus == "credential-stored"
        modelName = payload.modelLabel ?? payload.model ?? "等待模型"
        reasoningEffort = payload.reasoningEffort
        accountDisplayValue = isSignedIn ? "已登录" : (payload.accountStatus == "signed-out" ? "未登录" : "等待账号数据")
        providerName = payload.provider ?? "DeepSeek Harness"
        workspaceName = payload.workspacePath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "默认工作区"
        balanceUpdatedAt = Self.date(from: payload.balanceFetchedAt ?? payload.balanceUpdatedAt)
        balanceIsFresh = balanceUpdatedAt.map { now.timeIntervalSince($0) >= -5 && now.timeIntervalSince($0) <= 180 } ?? false
        balanceDiagnostic = payload.balanceStatus == "ready" && balanceIsFresh
            ? "Harness 官方余额 · 60秒轮询" : (balanceUpdatedAt == nil ? "等待官方余额" : "官方余额未更新或读取失败")

        let wallets = payload.balance ?? []
        let bonusWallets = payload.bonusWallets ?? []
        if payload.accountStatus == "signed-out" {
            balanceDisplayValue = "未登录"
        } else if !isSignedIn {
            balanceDisplayValue = "--"
        } else if payload.balanceStatus != "ready" || !balanceIsFresh {
            balanceDisplayValue = "暂不可读"
        } else {
            balanceDisplayValue = Self.displayWallets(wallets)
        }
        bonusDisplayValue = isSignedIn && payload.balanceStatus == "ready" && balanceIsFresh
            ? Self.displayWallets(bonusWallets, empty: "暂无")
            : "--"
    }

    private static func displayWallets(_ wallets: [DeepSeekWallet], empty: String = "--") -> String {
        let values = wallets.map { display($0) }.filter { $0 != "--" }
        return values.isEmpty ? empty : values.joined(separator: " / ")
    }

    private static func display(_ wallet: DeepSeekWallet?, empty: String = "--") -> String {
        guard let wallet else { return empty }
        let currency = wallet.currency.uppercased()
        let symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : "\(currency) ")
        guard let amount = Decimal(string: wallet.balance, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: amount).doubleValue.isFinite else {
            return "--"
        }
        let fractionalBalance = amount != .zero && abs(amount) < Decimal(string: "0.01")!
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let magnitude = abs(NSDecimalNumber(decimal: amount).doubleValue)
        if magnitude > 0 && magnitude < 0.00000001 { return symbol + (amount < .zero ? ">-0.00000001" : "<0.00000001") }
        let digits = fractionalBalance ? min(8, max(4, Int(ceil(-log10(magnitude))) + 1)) : 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
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
    private let statusURL: URL
    init(statusURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TokenLens/deepseek-status.json")) { self.statusURL = statusURL }

    func read(now: Date = Date()) -> DeepSeekStatusSnapshot {
        guard let data = try? Data(contentsOf: statusURL),
              let payload = try? JSONDecoder().decode(DeepSeekBridgePayload.self, from: data) else {
            return .empty
        }
        return DeepSeekStatusSnapshot(payload: payload, now: now)
    }
}
