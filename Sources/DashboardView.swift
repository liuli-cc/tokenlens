import AppKit
import Charts
import Combine
import SwiftUI

private enum TokenAccent {
    static func color(_ assistant: IslandAssistant) -> Color { adaptive(assistant.palette.accent) }
    static func gradient(_ assistant: IslandAssistant) -> LinearGradient {
        LinearGradient(colors: [adaptive(assistant.palette.start), adaptive(assistant.palette.end)],
                       startPoint: .bottomLeading, endPoint: .topTrailing)
    }
    private static func adaptive(_ rgb: AssistantPalette.RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scale = dark ? 1.0 : 0.52
            return NSColor(srgbRed: rgb.red * scale, green: rgb.green * scale,
                           blue: rgb.blue * scale, alpha: 1)
        })
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var appearance: String
    @State private var showingMethodology = false
    @State private var entrance = false

    private var data: UsageSnapshot { store.activeSnapshot }

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            MonochromeSignalField(isAnimated: !reduceMotion)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.bottom, 18)
                    dataStatus
                        .padding(.bottom, 20)

                    if store.activeAssistant == .chatGPT, let error = store.errorMessage, data == .empty {
                        errorState(error)
                    } else {
                        dashboard
                    }

                    privacyFooter
                        .padding(.top, 18)
                }
                .padding(.horizontal, 30)
                .padding(.top, 24)
                .padding(.bottom, 26)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.tokenBackground)
        .foregroundStyle(Color.tokenInk)
        .tint(TokenAccent.color(store.activeAssistant))
        .onReceive(refreshTimer) { _ in store.refresh() }
        .onAppear {
            if reduceMotion {
                entrance = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) { entrance = true }
            }
        }
        .popover(isPresented: $showingMethodology, arrowEdge: .top) {
            MethodologyView()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            TokenLensMark()

            VStack(alignment: .leading, spacing: 2) {
                Text("TokenLens")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(store.activeAssistant.displayName) 本机用量助手")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tokenMuted)
            }

            Spacer()

            HStack(spacing: 9) {
                LiveIndicator(isActive: store.activeAssistant != .chatGPT || store.errorMessage == nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(data.currentModel)
                        .foregroundStyle(TokenAccent.gradient(store.activeAssistant))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(data.currentProvider)  ·  \(data.currentSource)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(Color.tokenMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 250, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.tokenSurface)
            .clipShape(Capsule())

            Button {
                appearance = appearance == "dark" ? "light" : "dark"
            } label: {
                Image(systemName: appearance == "dark" ? "sun.max" : "moon")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(TokenIconButtonStyle())
            .help("切换黑白主题")

            Button { showingMethodology.toggle() } label: {
                Image(systemName: "info")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(TokenIconButtonStyle())
            .help("查看指标口径")

            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isScanning ? 360 : 0))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false),
                        value: store.isScanning
                    )
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(TokenIconButtonStyle())
            .disabled(store.isScanning)
            .help("立即刷新")
        }
    }

    private var dashboard: some View {
        VStack(spacing: 16) {
            heroMetrics
                .offset(y: entrance ? 0 : 12)
                .opacity(entrance ? 1 : 0.6)

            quotaWindows

            HStack(alignment: .top, spacing: 16) {
                trendPanel
                    .frame(maxWidth: .infinity)

                modelPanel
                    .frame(width: 330)
            }
        }
    }

    private var dataStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(data.metricsSource).fontWeight(.medium)
                if let updated = data.metricsUpdatedAt {
                    Text("数据时间 \(updated.formatted(date: .abbreviated, time: .shortened))")
                }
                Spacer()
                Text(data.recentRequestCount.map {
                    "\(recentCallRange) · 已记录 \(data.requestCountIsLowerBound ? "≥" : "")\($0) 次模型调用"
                } ?? "\(recentCallRange) · 调用数未提供")
            }
            if let diagnostic = data.metricsDiagnostic {
                Text(diagnostic).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11)).foregroundStyle(Color.tokenMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var recentCallRange: String {
        switch store.activeAssistant {
        case .chatGPT, .deepSeek: return "近 7 天"
        case .workBuddy, .claude: return "近 24 小时"
        case .codeBuddy: return "近期"
        }
    }

    private var freshQuotaWindows: [RateLimitWindow] {
        let now = Date()
        // The timestamp check is shared with the primary metric; individual
        // windows that have already reset are excluded instead of reused.
        guard data.effectiveQuota(now: now) != nil else { return [] }
        return [data.quota, data.secondaryQuota].compactMap { $0 }
            .filter { $0.resetsAt.map { $0 > now } ?? false }
    }

    @ViewBuilder private var quotaWindows: some View {
        if !freshQuotaWindows.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                if let name = data.quotaLimitName ?? data.quotaLimitID, !name.isEmpty {
                    Text("账户限制：\(name)").font(.system(size: 11, weight: .medium))
                }
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(freshQuotaWindows.enumerated()), id: \.offset) { _, quota in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(quotaWindowTitle(quota)) · 剩余 \(quota.remainingPercent.oneDecimalPercent)")
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            if let reset = quota.resetsAt {
                                Text("\(reset.formatted(date: .abbreviated, time: .shortened)) 重置")
                                    .font(.system(size: 10)).foregroundStyle(Color.tokenMuted)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let at = data.quotaUpdatedAt {
                    Text("服务器采样于 \(at.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10)).foregroundStyle(Color.tokenMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
        }
    }

    private func quotaWindowTitle(_ quota: RateLimitWindow) -> String {
        let minutes = quota.windowMinutes
        if minutes >= 1_440, minutes % 1_440 == 0 { return "\(minutes / 1_440) 天窗口" }
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) 小时窗口" }
        return minutes > 0 ? "\(minutes) 分钟窗口" : "额度窗口"
    }

    private var heroMetrics: some View {
        HStack(spacing: 0) {
            QuotaMetric(
                value: store.activeMetricValue,
                title: store.activeMetricTitle,
                detail: store.activeMetricDetail,
                percent: data.effectiveQuota()?.remainingPercent,
                isBalance: store.activeAssistant == .deepSeek || data.usesExternalModel || data.providerBalance != nil
            )
                .frame(maxWidth: .infinity)

            Hairline()

            ContextMetric(
                current: data.contextUsedTokens,
                window: data.contextWindow,
                percent: data.contextPercent,
                display: data.contextDisplayValue,
                isEstimate: data.contextIsEstimate
            )
            .frame(maxWidth: .infinity)

            Hairline()

            VStack(alignment: .leading, spacing: 24) {
                FlatMetric(
                    label: "今日 TOKEN",
                    value: data.tokenDisplayValue,
                    detail: data.tokenUsageKnown ? "\(data.sessionsToday) 个可观察会话" : "软件未提供可读取计数"
                )

                FlatMetric(
                    label: "缓存命中率",
                    value: data.cacheHitDisplayValue,
                    detail: "本会话 cached / input"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
        }
        .padding(.vertical, 28)
        .background(Color.tokenSurface.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tokenLine, lineWidth: 1)
        }
    }

    private var trendPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("近 7 日使用趋势")
                        .font(.system(size: 15, weight: .semibold))
                    Text(data.tokenUsageKnown ? "可观察日志中的输入、缓存与输出计数" : "未取得可读取的 Token 计数")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tokenMuted)
                }
                Spacer()
                Text(data.tokenUsageKnown ? data.dailyUsage.reduce(0) { $0 + $1.usage.totalTokens }.compactTokenString : "--")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }

            Chart(data.dailyUsage) { item in
                BarMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value("Token", item.usage.totalTokens)
                )
                .foregroundStyle(TokenAccent.gradient(store.activeAssistant))
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .foregroundStyle(Color.tokenMuted)
                    AxisTick(stroke: StrokeStyle(lineWidth: 0))
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 5]))
                        .foregroundStyle(Color.tokenLine)
                    AxisValueLabel {
                        if let number = value.as(Int64.self) {
                            Text(number.compactTokenString)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.tokenMuted)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            .overlay {
                if !data.tokenUsageKnown {
                    Text("此软件暂未提供可读取的用量趋势")
                        .font(.system(size: 12)).foregroundStyle(Color.tokenMuted)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: data.dailyUsage)

            HStack(spacing: 20) {
                InlineStat(label: "输入", value: data.tokenUsageKnown ? data.todayUsage.inputTokens.compactTokenString : "--")
                InlineStat(label: "缓存", value: data.cacheUsageKnown ? data.todayUsage.cachedInputTokens.compactTokenString : "--")
                InlineStat(label: "输出", value: data.tokenUsageKnown ? data.todayUsage.outputTokens.compactTokenString : "--")
                Spacer()
                if let updated = data.metricsUpdatedAt {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.tokenMuted)
                }
            }
        }
        .padding(22)
        .background(Color.tokenSurface.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tokenLine, lineWidth: 1)
        }
    }

    private var modelPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("模型动态")
                    .font(.system(size: 15, weight: .semibold))
                Text("最近 7 天 · 本机记录")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tokenMuted)
            }

            if data.modelUsage.isEmpty && data.configuredModels.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 24, weight: .light))
                    Text("此软件产生可读取的模型计数后将显示")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tokenMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(data.modelUsage.prefix(3).enumerated()), id: \.element.id) { index, item in
                        ModelRow(
                            provider: item.provider,
                            model: item.model,
                            tokens: item.tokens,
                            tokensKnown: data.tokenUsageKnown,
                            requests: item.requests,
                            requestsKnown: item.requestsKnown,
                            source: item.source,
                            isCurrent: item.model == data.currentModel && item.provider == data.currentProvider
                        )
                        if index < min(2, data.modelUsage.count - 1) {
                            Divider().overlay(Color.tokenLine)
                        }
                    }
                }
            }

            if !data.configuredModels.isEmpty {
                Divider().overlay(Color.tokenLine)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("CC SWITCH 已接入")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(Color.tokenMuted)
                        Spacer()
                        Text("\(Set(data.configuredModels.map(\.provider)).count) 个提供商")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.tokenMuted)
                    }
                    ForEach(data.configuredModels.prefix(4)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.tokenMuted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                Text("\(item.provider)  ·  \(item.contextWindow.compactTokenString) 窗口")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(Color.tokenMuted)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Spacer(minLength: 6)

            HStack {
                Image(systemName: "folder")
                Text("\(data.filesObserved) 个近期日志")
                Spacer()
                Image(systemName: "lock.shield")
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.tokenMuted)
        }
        .padding(22)
        .background(Color.tokenSurface.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tokenLine, lineWidth: 1)
        }
    }

    private var privacyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
            Text("只提取各软件本机日志中的模型、计数和状态；对话正文不进入仪表盘。")
            Spacer()
            if store.activeAssistant == .chatGPT, let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
            } else {
                Text("5 秒自动刷新")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.tokenMuted)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
            Text("暂时无法读取 \(store.activeAssistant.displayName) 用量")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.tokenMuted)
            Button("重试") { store.refresh() }
                .buttonStyle(.borderedProminent)
                .tint(Color.tokenInk)
                .foregroundStyle(Color.tokenBackground)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
        .background(Color.tokenSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct QuotaMetric: View {
    let value: String
    let title: String
    let detail: String
    let percent: Double?
    let isBalance: Bool

    var body: some View {
        HStack(spacing: 18) {
            if isBalance {
                Text(value)
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .frame(minWidth: 82, alignment: .leading)
            } else {
                RingGauge(percent: percent ?? 0, center: value)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(Color.tokenMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
    }
}

private struct ContextMetric: View {
    let current: Int64?
    let window: Int64
    let percent: Double?
    let display: String
    let isEstimate: Bool

    var body: some View {
        HStack(spacing: 18) {
            RingGauge(percent: percent ?? 0, center: display)
            VStack(alignment: .leading, spacing: 7) {
                Text(isEstimate && percent != nil ? "上下文估算" : "当前上下文")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.tokenMuted)
                Text("\(current?.compactTokenString ?? "--") / \(window > 0 ? window.compactTokenString : "--")")
                    .font(.system(size: 14, weight: .medium, design: .monospaced)).monospacedDigit()
                Text(percent == nil ? "未读取上下文长度或窗口" : (isEstimate ? "最近响应估算，未含后续工具消息/压缩变化" : "软件报告的当前长度 / 窗口"))
                    .font(.system(size: 10)).foregroundStyle(Color.tokenMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
    }
}

private struct RingGauge: View {
    @EnvironmentObject private var store: UsageStore
    let percent: Double
    let center: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedPercent = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.tokenLine, lineWidth: 7)
            Circle()
                .trim(from: 0, to: animatedPercent / 100)
                .stroke(
                    TokenAccent.gradient(store.activeAssistant),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(center)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 72, height: 72)
        .onAppear { update() }
        .onChange(of: percent) { _, _ in update() }
    }

    private func update() {
        if reduceMotion {
            animatedPercent = percent
        } else {
            withAnimation(.easeOut(duration: 0.55)) { animatedPercent = percent }
        }
    }
}

private struct FlatMetric: View {
    @EnvironmentObject private var store: UsageStore
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.tokenMuted)
            Text(value)
                .foregroundStyle(TokenAccent.gradient(store.activeAssistant))
                .font(.system(size: 29, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Color.tokenMuted)
        }
    }
}

private struct InlineStat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Color.tokenMuted)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

private struct ModelRow: View {
    let provider: String
    let model: String
    let tokens: Int64
    let tokensKnown: Bool
    let requests: Int
    let requestsKnown: Bool
    let source: String
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.tokenInk : Color.tokenSubtle)
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.tokenBackground : Color.tokenMuted)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(model)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isCurrent ? "\(provider)  ·  当前活跃" : "\(provider)  ·  \(source)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.tokenMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(tokensKnown ? tokens.compactTokenString : "--").font(.system(size: 10, weight: .medium, design: .monospaced))
                Text(requestsKnown ? "\(requests) 次调用" : "调用数未提供").font(.system(size: 9))
            }.foregroundStyle(Color.tokenMuted)
        }
        .padding(.vertical, 10)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.tokenLine)
            .frame(width: 1, height: 104)
    }
}

private struct LiveIndicator: View {
    @EnvironmentObject private var store: UsageStore
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(isActive ? TokenAccent.color(store.activeAssistant) : Color.tokenMuted)
            .frame(width: 6, height: 6)
            .scaleEffect(breathing ? 1.25 : 0.85)
            .opacity(breathing ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .accessibilityLabel(isActive ? "正在监控" : "监控异常")
    }
}

private struct TokenLensMark: View {
    @EnvironmentObject private var store: UsageStore
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TokenAccent.gradient(store.activeAssistant))
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.tokenBackground)
        }
        .frame(width: 36, height: 36)
    }
}

private struct TokenIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.tokenInk)
            .background(configuration.isPressed ? Color.tokenLine : Color.tokenSurface)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.tokenLine, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct MonochromeSignalField: View {
    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: isAnimated ? 1.0 / 24.0 : 60)) { context in
            Canvas { canvas, size in
                let time = isAnimated ? context.date.timeIntervalSinceReferenceDate : 0
                for row in 0..<4 {
                    var path = Path()
                    let baseY = size.height * (0.18 + Double(row) * 0.22)
                    let amplitude = 7.0 + Double(row) * 2.5
                    for x in stride(from: 0.0, through: size.width, by: 10.0) {
                        let phase = x / 90 + time * (0.24 + Double(row) * 0.035)
                        let y = baseY + sin(phase) * amplitude
                        if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    canvas.stroke(path, with: .color(Color.tokenLine.opacity(0.45)), lineWidth: 0.6)
                }
            }
        }
        .allowsHitTesting(false)
        .background(Color.tokenBackground)
    }
}

private struct MethodologyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("指标口径")
                .font(.system(size: 15, weight: .semibold))

            MethodRow(title: "Token 消耗", detail: "只汇总软件实际报告的使用计数。未取得数据时显示 --，不把日志行数或费用反推成 Token。")
            MethodRow(title: "额度 / 余额", detail: "账户额度来自服务器返回值，多个限制窗口取最紧的一项；超过 15 分钟或已重置的样本不再显示。余额显示实际返回金额和采样时间。")
            MethodRow(title: "缓存命中率", detail: "缓存读取 Token / 全部输入 Token；包含不同软件分别报告的未缓存、缓存读取与缓存写入。缺少分项时显示 --。")
            MethodRow(title: "上下文", detail: "优先采用软件报告的当前长度。Codex/Harness 按最近响应估算并标为 ≈，后续工具消息和压缩变化可能尚未反映；缺少窗口时显示 --。")
            MethodRow(title: "近期调用", detail: "只统计有唯一调用或响应 ID 的实际模型请求；重试、重复累计、配置变更和一般日志行不会算作新调用。")

            Divider()

            Label("API Key 仅在本机内存中用于官方余额请求；不上传日志，不解析对话正文。", systemImage: "lock.shield")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 390)
    }
}

private struct MethodRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension Color {
    static let tokenBackground = adaptive(
        light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.043, green: 0.045, blue: 0.048, alpha: 1)
    )
    static let tokenSurface = adaptive(
        light: NSColor(srgbRed: 0.995, green: 0.995, blue: 0.995, alpha: 1),
        dark: NSColor(srgbRed: 0.070, green: 0.072, blue: 0.075, alpha: 1)
    )
    static let tokenSubtle = adaptive(
        light: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1),
        dark: NSColor(srgbRed: 0.120, green: 0.122, blue: 0.125, alpha: 1)
    )
    static let tokenInk = adaptive(
        light: NSColor(srgbRed: 0.050, green: 0.052, blue: 0.055, alpha: 1),
        dark: NSColor(srgbRed: 0.950, green: 0.950, blue: 0.950, alpha: 1)
    )
    static let tokenMuted = adaptive(
        light: NSColor(srgbRed: 0.340, green: 0.350, blue: 0.360, alpha: 1),
        dark: NSColor(srgbRed: 0.650, green: 0.660, blue: 0.670, alpha: 1)
    )
    static let tokenLine = adaptive(
        light: NSColor(srgbRed: 0.855, green: 0.855, blue: 0.855, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.185, blue: 0.190, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
