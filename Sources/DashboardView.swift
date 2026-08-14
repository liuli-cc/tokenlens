import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var appearance: String
    @State private var showingMethodology = false
    @State private var entrance = false

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            MonochromeSignalField(isAnimated: !reduceMotion)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.bottom, 26)

                    if let error = store.errorMessage, store.snapshot == .empty {
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
                Text("Codex 本机用量助手")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tokenMuted)
            }

            Spacer()

            HStack(spacing: 9) {
                LiveIndicator(isActive: store.errorMessage == nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.snapshot.currentModel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(store.snapshot.currentProvider)  ·  \(store.snapshot.currentSource)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(Color.tokenMuted)
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

            HStack(alignment: .top, spacing: 16) {
                trendPanel
                    .frame(maxWidth: .infinity)

                modelPanel
                    .frame(width: 330)
            }
        }
    }

    private var heroMetrics: some View {
        HStack(spacing: 0) {
            QuotaMetric(quota: store.snapshot.quota)
                .frame(maxWidth: .infinity)

            Hairline()

            ContextMetric(
                current: store.snapshot.lastCallUsage.totalTokens,
                window: store.snapshot.contextWindow,
                percent: store.snapshot.contextUsedPercent
            )
            .frame(maxWidth: .infinity)

            Hairline()

            VStack(alignment: .leading, spacing: 24) {
                FlatMetric(
                    label: "今日 TOKEN",
                    value: store.snapshot.todayUsage.totalTokens.compactTokenString,
                    detail: "\(store.snapshot.sessionsToday) 个会话"
                )

                FlatMetric(
                    label: "缓存命中率",
                    value: store.snapshot.cacheHitRate.oneDecimalPercent,
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
                    Text("输入、缓存与输出的实际日志计数")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tokenMuted)
                }
                Spacer()
                Text(store.snapshot.dailyUsage.reduce(0) { $0 + $1.usage.totalTokens }.compactTokenString)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }

            Chart(store.snapshot.dailyUsage) { item in
                BarMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value("Token", item.usage.totalTokens)
                )
                .foregroundStyle(Color.tokenInk.gradient)
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: store.snapshot.dailyUsage)

            HStack(spacing: 20) {
                InlineStat(label: "输入", value: store.snapshot.todayUsage.inputTokens.compactTokenString)
                InlineStat(label: "缓存", value: store.snapshot.todayUsage.cachedInputTokens.compactTokenString)
                InlineStat(label: "输出", value: store.snapshot.todayUsage.outputTokens.compactTokenString)
                Spacer()
                if let updated = store.lastUpdated {
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
                Text("无需预置模型列表")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tokenMuted)
            }

            if store.snapshot.modelUsage.isEmpty && store.snapshot.configuredModels.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 24, weight: .light))
                    Text("开始一次 Codex 任务后将自动显示")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tokenMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.snapshot.modelUsage.prefix(3).enumerated()), id: \.element.id) { index, item in
                        ModelRow(
                            provider: item.provider,
                            model: item.model,
                            tokens: item.tokens,
                            requests: item.requests,
                            source: item.source,
                            isCurrent: item.model == store.snapshot.currentModel && item.provider == store.snapshot.currentProvider
                        )
                        if index < min(2, store.snapshot.modelUsage.count - 1) {
                            Divider().overlay(Color.tokenLine)
                        }
                    }
                }
            }

            if !store.snapshot.configuredModels.isEmpty {
                Divider().overlay(Color.tokenLine)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("CC SWITCH 已接入")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(Color.tokenMuted)
                        Spacer()
                        Text("\(Set(store.snapshot.configuredModels.map(\.provider)).count) 个提供商")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.tokenMuted)
                    }
                    ForEach(store.snapshot.configuredModels.prefix(4)) { item in
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
                Text("\(store.snapshot.filesObserved) 个近期日志")
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
            Text("只读取 ~/.codex/sessions 中的计数与模型字段，对话正文不会进入仪表盘。")
            Spacer()
            if let error = store.errorMessage {
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
            Text("暂时无法读取 Codex 用量")
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
    let quota: RateLimitWindow?

    var body: some View {
        HStack(spacing: 20) {
            RingGauge(
                percent: quota?.remainingPercent ?? 0,
                center: quota?.remainingPercent.oneDecimalPercent ?? "--"
            )

            VStack(alignment: .leading, spacing: 7) {
                Text("CHATGPT / CODEX")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Color.tokenMuted)
                Text("共享额度剩余")
                    .font(.system(size: 14, weight: .medium))
                if let quota {
                    Text(quotaDescription(quota))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.tokenMuted)
                } else {
                    Text("等待最新额度事件")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.tokenMuted)
                }
            }
        }
        .padding(.horizontal, 28)
    }

    private func quotaDescription(_ quota: RateLimitWindow) -> String {
        let window = quota.windowMinutes >= 1_440
            ? "\(quota.windowMinutes / 1_440) 天窗口"
            : "\(max(1, quota.windowMinutes / 60)) 小时窗口"
        guard let reset = quota.resetsAt else { return window }
        return "\(window)  ·  \(reset.formatted(date: .abbreviated, time: .shortened)) 重置"
    }
}

private struct ContextMetric: View {
    let current: Int64
    let window: Int64
    let percent: Double

    var body: some View {
        HStack(spacing: 20) {
            RingGauge(percent: percent, center: percent.oneDecimalPercent)

            VStack(alignment: .leading, spacing: 7) {
                Text("当前上下文")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Color.tokenMuted)
                Text("\(current.compactTokenString) / \(window.compactTokenString)")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                Text("最近一次模型调用 / 动态窗口")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.tokenMuted)
            }
        }
        .padding(.horizontal, 28)
    }
}

private struct RingGauge: View {
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
                    Color.tokenInk,
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
    let requests: Int
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
            Text(tokens.compactTokenString)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.tokenMuted)
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
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(isActive ? Color.tokenInk : Color.tokenMuted)
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
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.tokenInk)
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

            MethodRow(title: "Token 消耗", detail: "Codex token_count 事件中的实际累计值。")
            MethodRow(title: "额度剩余", detail: "100% 减去 Codex 共享 agentic 窗口的 used_percent。")
            MethodRow(title: "缓存命中率", detail: "本会话 cached_input_tokens 除以 input_tokens。")
            MethodRow(title: "当前长度", detail: "最近一次模型调用的 total_tokens，对比日志报告的动态上下文窗口。")
            MethodRow(title: "CC Switch 外部模型", detail: "提供商与模型目录来自本机 CC Switch，近 30 日用量优先使用其代理请求日志。")

            Divider()

            Label("不读取 API Key，不上传日志，不解析对话正文。", systemImage: "lock.shield")
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
