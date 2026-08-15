import AppKit
import QuartzCore
import SwiftUI

@MainActor
private final class TopPinnedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
private final class IslandHostContainer: NSView {
    let hostedView: NSView
    let compactDesignWidth: CGFloat
    var usesExpandedLayout = false {
        didSet { needsLayout = true }
    }

    init(hostedView: NSView, compactDesignWidth: CGFloat) {
        self.hostedView = hostedView
        self.compactDesignWidth = compactDesignWidth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        hostedView.wantsLayer = true
        hostedView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostedView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        hostedView.frame = NSRect(
            x: 0,
            y: 0,
            width: usesExpandedLayout ? bounds.width : compactDesignWidth,
            height: bounds.height
        )
    }
}

@MainActor
final class IslandViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var isJellySettling = false
    @Published var notchGapWidth: CGFloat = 176
}

@MainActor
final class IslandPanelController {
    private let compactDesignSize = NSSize(width: 430, height: 33.5)
    private let compactSize = NSSize(width: 358, height: 33.5)
    private let expandedSize = NSSize(width: 548, height: 148)
    private let topInset: CGFloat = 0

    private let store: UsageStore
    private let onOpenDetails: () -> Void
    private let viewModel = IslandViewModel()
    private let panel: TopPinnedPanel
    private var hostContainer: IslandHostContainer!

    private var currentScreen: NSScreen?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var animationGeneration = 0

    init(store: UsageStore, onOpenDetails: @escaping () -> Void) {
        self.store = store
        self.onOpenDetails = onOpenDetails
        self.panel = TopPinnedPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let rootView = DynamicIslandView(
            viewModel: viewModel,
            onHover: { [weak self] isInside in
                if isInside {
                    self?.expand()
                } else {
                    self?.collapseIfPointerIsOutside()
                }
            },
            onTap: { [weak self] in
                self?.handleTap()
            }
        )
        .environmentObject(store)

        let hostingView = NSHostingView(rootView: rootView)
        hostContainer = IslandHostContainer(
            hostedView: hostingView,
            compactDesignWidth: compactDesignSize.width
        )
        panel.contentView = hostContainer
    }

    func start() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            updateCurrentScreen(screen)
            panel.setFrame(compactFrame(on: screen), display: true)
        }
        panel.orderFrontRegardless()
        installPointerMonitors()
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                self?.handlePointer(at: point)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                self?.handlePointer(at: point)
            }
            return event
        }
    }

    private func handlePointer(at point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            collapseImmediately()
            return
        }

        let trigger = topTrigger(on: screen)
        if viewModel.isExpanded {
            if panel.frame.contains(point) || trigger.contains(point) {
                updateCurrentScreen(screen)
            } else {
                collapseImmediately()
            }
        } else if panel.frame.contains(point) || trigger.contains(point) {
            updateCurrentScreen(screen)
            expand()
        }
    }

    private func updateCurrentScreen(_ screen: NSScreen) {
        currentScreen = screen
        viewModel.notchGapWidth = resolvedNotchGap(on: screen)
    }

    private func resolvedNotchGap(on screen: NSScreen) -> CGFloat {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              !leftArea.isEmpty,
              !rightArea.isEmpty else {
            return 176
        }

        let physicalGap = rightArea.minX - leftArea.maxX
        guard physicalGap > 60 else { return 176 }
        return min(210, max(150, physicalGap + 10))
    }

    private func topTrigger(on screen: NSScreen) -> NSRect {
        let compactFrame = compactFrame(on: screen)
        return NSRect(
            x: compactFrame.minX - 12,
            y: screen.frame.maxY - 24,
            width: compactFrame.width + 24,
            height: 24
        )
    }

    private func collapseIfPointerIsOutside() {
        let point = NSEvent.mouseLocation
        guard !panel.frame.contains(point) else { return }

        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
           topTrigger(on: screen).contains(point) {
            return
        }
        collapseImmediately()
    }

    private func expand() {
        guard !viewModel.isExpanded else { return }

        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        animationGeneration += 1
        let generation = animationGeneration
        hostContainer.usesExpandedLayout = true
        viewModel.isExpanded = true
        viewModel.isJellySettling = false

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.setFrame(frame(for: expandedSize, on: screen), display: true)
            return
        }

        let overshootSize = NSSize(width: expandedSize.width + 16, height: expandedSize.height + 10)
        let overshootFrame = frame(for: overshootSize, on: screen)
        let targetFrame = frame(for: expandedSize, on: screen)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.68
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.88, 0.26, 1.0)
            panel.animator().setFrame(overshootFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.animationGeneration == generation,
                      self.viewModel.isExpanded else { return }
                self.settleJelly(to: targetFrame, generation: generation)
            }
        }
    }

    private func settleJelly(to targetFrame: NSRect, generation: Int) {
        viewModel.isJellySettling = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 1.28, 0.36, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.animationGeneration == generation,
                      self.viewModel.isExpanded else { return }
                self.viewModel.isJellySettling = false
            }
        }
    }

    private func collapseImmediately() {
        guard viewModel.isExpanded else { return }

        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        animationGeneration += 1
        viewModel.isExpanded = false
        viewModel.isJellySettling = false
        hostContainer.usesExpandedLayout = false

        let targetFrame = compactFrame(on: screen)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.40, 0.0, 1.0, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func handleTap() {
        if viewModel.isExpanded {
            onOpenDetails()
        } else {
            expand()
        }
    }

    private func frame(for size: NSSize, on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        )
    }

    private func compactFrame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - compactDesignSize.width / 2,
            y: screen.frame.maxY - compactSize.height - topInset,
            width: compactSize.width,
            height: compactSize.height
        )
    }
}

private struct DynamicIslandView: View {
    private let compactRightWingShift: CGFloat = 72

    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: IslandViewModel

    let onHover: (Bool) -> Void
    let onTap: () -> Void

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            islandShape
                .fill(Color.black)
                .overlay {
                    islandShape
                        .strokeBorder(
                            Color.white.opacity(viewModel.isExpanded ? 0.12 : 0.08),
                            lineWidth: 0.7
                        )
                }
                .padding(.trailing, viewModel.isExpanded ? 0 : compactRightWingShift)

            if viewModel.isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.90, anchor: .top)))
            } else {
                compactContent
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .scaleEffect(
            x: viewModel.isJellySettling ? 1.012 : 1,
            y: viewModel.isJellySettling ? 0.972 : 1,
            anchor: .top
        )
        .overlay(alignment: .leading) {
            GeometryReader { proxy in
                Color.clear
                    .frame(
                        width: viewModel.isExpanded
                            ? proxy.size.width
                            : max(0, proxy.size.width - compactRightWingShift),
                        height: proxy.size.height
                    )
                    .contentShape(Rectangle())
                    .onHover(perform: onHover)
                    .onTapGesture(perform: onTap)
            }
        }
        .onReceive(refreshTimer) { _ in store.refresh() }
        .animation(
            reduceMotion ? nil : .timingCurve(0.18, 0.88, 0.26, 1, duration: 0.58),
            value: viewModel.isExpanded
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.48),
            value: viewModel.isJellySettling
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(viewModel.isExpanded ? "TokenLens 已展开，点击查看详细统计" : "TokenLens，用量监控")
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: viewModel.isExpanded ? 30 : 16.75,
            bottomTrailingRadius: viewModel.isExpanded ? 30 : 16.75,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 1) {
                    Text(compactModelName)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(store.snapshot.currentProvider) · \(store.snapshot.currentSource)")
                        .font(.system(size: 7.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: viewModel.notchGapWidth)
                .accessibilityHidden(true)

            VStack(alignment: .trailing, spacing: 1) {
                Text(compactMetricValue)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(store.snapshot.quotaMetricTitle)
                    .font(.system(size: 7.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(x: -compactRightWingShift)
        }
        .padding(.horizontal, 14)
    }

    private var expandedContent: some View {
        VStack(spacing: 11) {
            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 23, height: 23)
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.snapshot.currentModel)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(store.snapshot.currentProvider) · \(store.snapshot.currentSource)")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: viewModel.notchGapWidth)
                    .accessibilityHidden(true)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(store.snapshot.usesExternalModel
                        ? store.snapshot.balanceDisplayValue
                        : store.snapshot.quota?.remainingPercent.oneDecimalPercent ?? "--")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(store.isScanning ? "正在扫描" : store.snapshot.sharedQuotaMetricTitle)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 31)

            HStack(spacing: 0) {
                IslandMetric(title: "今日 TOKEN", value: store.snapshot.todayUsage.totalTokens.compactTokenString)
                divider
                IslandMetric(
                    title: store.snapshot.quotaMetricTitle,
                    value: store.snapshot.usesExternalModel
                        ? store.snapshot.balanceDisplayValue
                        : store.snapshot.quota?.remainingPercent.oneDecimalPercent ?? "--"
                )
                divider
                IslandMetric(title: "上下文", value: store.snapshot.contextUsedPercent.oneDecimalPercent)
                divider
                IslandMetric(title: "缓存命中", value: store.snapshot.cacheHitRate.oneDecimalPercent)
            }

            HStack {
                Text("点击查看详细趋势与全部模型")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.40))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.40))
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 5)
        .padding(.bottom, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 24)
    }

    private var compactModelName: String {
        let name = store.snapshot.currentModel
        return name.count > 15 ? String(name.prefix(14)) + "…" : name
    }

    private var compactMetricValue: String {
        let value = store.snapshot.usesExternalModel
            ? store.snapshot.balanceDisplayValue
            : store.snapshot.quota?.remainingPercent.oneDecimalPercent ?? "--"
        return value.count > 10 ? String(value.prefix(9)) + "…" : value
    }
}

private struct IslandMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                .tracking(0.35)
                .foregroundStyle(.white.opacity(0.40))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
