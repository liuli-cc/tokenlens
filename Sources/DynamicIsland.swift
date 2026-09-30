import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var completionNotice: TaskCompletionNotice?
    @Published var completionRevealed = false
    @Published var bodyHeight: CGFloat = 0
    @Published var layout = IslandGeometry.layout(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeTopInset: 0, leftAux: nil, rightAux: nil)
}

@MainActor
final class IslandPanelController: NSObject {
    private let store: UsageStore
    private let onOpenCurrentAssistant: () -> Void
    private let viewModel = IslandViewModel()
    // Two adjoining windows keep the widened body entirely below the menu band.
    // There is no large transparent expanded window sitting on system icons.
    private let bodyPanel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let crown = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var currentScreen: NSScreen?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables = Set<AnyCancellable>()
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var occupancyTask: Task<Void, Never>?
    private var occupancyTimer: Timer?
    private var pointerTimer: Timer?
    private var lastSampledPointer: CGPoint?
    private var motionTimer: Timer?
    private var lastMotionTime = CACurrentMediaTime()
    private var heightSpring = IslandSpring(position: 0, target: 0)
    private var widthSpring = IslandSpring(position: 400, target: 400)
    private var occupied: [CGRect] = []
    private var conservativeWings = true

    init(store: UsageStore, onOpenDetails: @escaping () -> Void, onOpenCurrentAssistant: @escaping () -> Void) {
        self.store = store
        self.onOpenCurrentAssistant = onOpenCurrentAssistant
        super.init()
        bodyPanel.title = "TokenLens · 展开状态"
        crown.title = "TokenLens · 顶部"
        for panel in [crown, bodyPanel] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            // isFloatingPanel mutates NSPanel's level; set the camera/menu-band
            // level last so macOS's menu-bar background cannot cover the island.
            panel.level = .statusBar
        }
        for (panel, part) in [(crown, IslandPart.crown), (bodyPanel, IslandPart.body)] {
            let host = IslandHostingView(rootView: DynamicIslandView(
                part: part, viewModel: viewModel,
                onHover: { [weak self] inside in self?.hover(inside) },
                onTap: { [weak self] in self?.handleTap() },
                onOpenDetails: onOpenDetails, onOpenCurrentAssistant: onOpenCurrentAssistant
            ).environmentObject(store))
            host.sizingOptions = []
            panel.contentView = host
        }
        store.$completionNotice.compactMap { $0 }.removeDuplicates(by: { $0.id == $1.id })
            .sink { [weak self] notice in Task { @MainActor in self?.presentCompletionNotice(notice) } }
            .store(in: &cancellables)
        store.$activeAssistant.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                guard let self, let notice = self.viewModel.completionNotice,
                      IslandAssistant.completionSource(notice.source) != self.store.activeAssistant else { return }
                self.finishCompletionNotice(notice)
            }
        }.store(in: &cancellables)
    }

    func start() {
        currentScreen = NSScreen.main ?? NSScreen.screens.first
        updateLayout(animated: false)
        crown.orderFrontRegardless()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }
            if !NSScreen.screens.contains(where: { $0 == self.currentScreen }) {
                self.currentScreen = NSScreen.main ?? NSScreen.screens.first
            }
            self.updateLayout(animated: false)
            self.refreshOccupancy()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.refreshOccupancy() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.updateTargets(animated: false) }
        occupancyTimer = Timer(timeInterval: 5, target: self, selector: #selector(refreshOccupancy), userInfo: nil, repeats: true)
        if let occupancyTimer { RunLoop.main.add(occupancyTimer, forMode: .common) }
        // Window hover events may stop inside the hardware cutout. Sampling the
        // position also detects a cursor that has become invisible there.
        pointerTimer = Timer(timeInterval: 0.05, target: self, selector: #selector(samplePointer), userInfo: nil, repeats: true)
        if let pointerTimer { RunLoop.main.add(pointerTimer, forMode: .common) }
        refreshOccupancy()
        samplePointer()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    func stop() {
        hoverTask?.cancel(); collapseTask?.cancel(); completionTask?.cancel(); occupancyTask?.cancel()
        occupancyTimer?.invalidate(); pointerTimer?.invalidate(); motionTimer?.invalidate()
        cancellables.removeAll()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        crown.orderOut(nil); bodyPanel.orderOut(nil)
    }

    @objc private func refreshOccupancy() {
        guard occupancyTask == nil else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
        var excluded = Set(apps.filter { ($0.bundleIdentifier ?? "").hasPrefix("cn.liuli.tokenlens") || ($0.localizedName ?? "").hasPrefix("TokenLens") }.map(\.processIdentifier))
        excluded.insert(ownPID)
        let excludedPIDs = excluded
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let systemMenus: Set<String> = ["com.apple.systemuiserver", "com.apple.controlcenter"]
        let preferred = apps.filter { $0.processIdentifier == front || systemMenus.contains(($0.bundleIdentifier ?? "").lowercased()) }
        var seen = Set<pid_t>()
        let ids = (preferred + apps.filter { $0.activationPolicy != .prohibited })
            .map(\.processIdentifier).filter { !excludedPIDs.contains($0) && seen.insert($0).inserted }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        occupancyTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                MenuBarOccupancy.read(processIDs: ids, frontmostPID: front, primaryTop: primaryTop, excludedPIDs: excludedPIDs)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.occupied = result.rectangles
            self.conservativeWings = result.needsConservativeWings
            self.occupancyTask = nil
            self.updateLayout(animated: true)
            if ProcessInfo.processInfo.environment["TOKENLENS_DIAGNOSTICS"] == "1" {
                print("TokenLens diagnostics: pid=\(ownPID) axTrusted=\(result.accessibilityTrusted) cgItems=\(result.windowItems) axItems=\(result.accessibilityItems) conservative=\(result.needsConservativeWings) leftWing=\(self.viewModel.layout.leftWing) rightWing=\(self.viewModel.layout.rightWing) crownLevel=\(self.crown.level.rawValue) bodyLevel=\(self.bodyPanel.level.rawValue)")
                fflush(stdout)
            }
        }
    }

    private func resolvedLayout(on screen: NSScreen) -> IslandLayout {
        IslandGeometry.layout(screen: screen.frame, safeTopInset: screen.safeAreaInsets.top,
                              leftAux: screen.auxiliaryTopLeftArea, rightAux: screen.auxiliaryTopRightArea,
                              menuBarHeight: NSStatusBar.system.thickness, occupied: occupied,
                              conservativeWings: conservativeWings)
    }

    private func updateLayout(animated: Bool) {
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let layout = resolvedLayout(on: screen)
        guard layout != viewModel.layout || !animated else { return }
        viewModel.layout = layout
        crown.setFrame(layout.crownFrame, display: true)
        updateTargets(animated: animated)
    }

    // This method is also exercised by the separate, explicitly synthetic preview.
    func presentCompletionNotice(_ notice: TaskCompletionNotice) {
        guard IslandAssistant.completionSource(notice.source) == store.activeAssistant else { return }
        completionTask?.cancel(); hoverTask?.cancel(); collapseTask?.cancel()
        viewModel.completionNotice = notice
        viewModel.completionRevealed = false
        viewModel.isExpanded = true
        updateTargets(animated: true)
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled, let self else { return }
            self.viewModel.completionRevealed = true
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self.finishCompletionNotice(notice)
        }
    }

    private func finishCompletionNotice(_ notice: TaskCompletionNotice) {
        guard viewModel.completionNotice?.id == notice.id else { return }
        completionTask?.cancel()
        viewModel.completionNotice = nil
        viewModel.completionRevealed = false
        store.dismissCompletionNotice(id: notice.id)
        viewModel.isExpanded = contains(NSEvent.mouseLocation)
        updateTargets(animated: true)
    }

    private func contains(_ point: CGPoint) -> Bool {
        viewModel.layout.cameraContains(point) || crownContains(point) || bodyContains(point)
    }
    private func crownContains(_ point: CGPoint) -> Bool {
        guard viewModel.layout.crownContains(point) else { return false }
        return CrownShape(radius: crownRadius).path(in: CGRect(origin: .zero, size: crown.frame.size))
            .contains(CGPoint(x: point.x - crown.frame.minX, y: crown.frame.maxY - point.y))
    }
    private var crownRadius: CGFloat { max(0, viewModel.layout.bandHeight / 2 * (1 - min(1, viewModel.bodyHeight / 28))) }
    private func bodyContains(_ point: CGPoint) -> Bool {
        guard bodyPanel.isVisible, bodyPanel.frame.contains(point) else { return false }
        return bodyShape.path(in: CGRect(origin: .zero, size: bodyPanel.frame.size))
            .contains(CGPoint(x: point.x - bodyPanel.frame.minX, y: bodyPanel.frame.maxY - point.y))
    }
    private var bodyShape: IslandBodyShape {
        IslandBodyShape(neckWidth: viewModel.layout.crownFrame.width)
    }
    private func updateHitTesting() {
        let point = NSEvent.mouseLocation
        crown.ignoresMouseEvents = !crownContains(point)
        bodyPanel.ignoresMouseEvents = !bodyContains(point)
    }
    @objc private func samplePointer() {
        let point = NSEvent.mouseLocation
        guard lastSampledPointer != point else { return }
        lastSampledPointer = point
        pointerMoved()
    }
    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        updateHitTesting()
        if contains(point) { hover(true) }
        else if !viewModel.isExpanded,
                let target = NSScreen.screens.first(where: { resolvedLayout(on: $0).crownHoverContains(point) }),
                target != currentScreen {
            currentScreen = target
            updateLayout(animated: false)
            hover(true)
        } else { hover(false) }
    }
    private func hover(_ reportedInside: Bool) {
        guard viewModel.completionNotice == nil else { return }
        // Leaving a visible wing for the invisible camera gap produces a SwiftUI
        // exit event, but the cursor is still hovering over the same island.
        let inside = reportedInside || contains(NSEvent.mouseLocation)
        if inside {
            collapseTask?.cancel(); collapseTask = nil
            guard !viewModel.isExpanded, hoverTask == nil else { return }
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.hoverTask = nil
                guard self.contains(NSEvent.mouseLocation) else { return }
                self.viewModel.isExpanded = true
                self.updateTargets(animated: true)
            }
        } else {
            hoverTask?.cancel(); hoverTask = nil
            guard viewModel.isExpanded, collapseTask == nil else { return }
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                self.collapseTask = nil
                guard !self.contains(NSEvent.mouseLocation) else { return }
                self.viewModel.isExpanded = false
                self.updateTargets(animated: true)
            }
        }
    }
    private func handleTap() {
        if let notice = viewModel.completionNotice { finishCompletionNotice(notice) }
        onOpenCurrentAssistant()
    }

    private func updateTargets(animated: Bool) {
        advanceMotion()
        heightSpring.target = viewModel.completionNotice != nil ? 88 : (viewModel.isExpanded ? 152 : 0)
        widthSpring.target = Double(viewModel.isExpanded ? viewModel.layout.expandedWidth : viewModel.layout.bodyBaseWidth)
        heightSpring.damping = viewModel.isExpanded ? 0.62 : 0.76
        widthSpring.damping = heightSpring.damping
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            heightSpring.settle(); widthSpring.settle()
            motionTimer?.invalidate(); motionTimer = nil
            applyMotion()
            return
        }
        if motionTimer == nil {
            lastMotionTime = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1 / 120, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            motionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func advanceMotion() {
        let now = CACurrentMediaTime()
        if motionTimer != nil {
            heightSpring.advance(by: now - lastMotionTime)
            widthSpring.advance(by: now - lastMotionTime)
        }
        lastMotionTime = now
    }
    @objc private func tick() {
        advanceMotion()
        if heightSpring.isSettled && widthSpring.isSettled {
            heightSpring.settle(); widthSpring.settle()
            motionTimer?.invalidate(); motionTimer = nil
        }
        applyMotion()
        // A stationary pointer must track the contour as the spring moves it.
        if viewModel.completionNotice == nil { hover(contains(NSEvent.mouseLocation)) }
    }
    private func applyMotion() {
        let height = max(0, CGFloat(heightSpring.position))
        let width = max(viewModel.layout.bodyBaseWidth, CGFloat(widthSpring.position))
        viewModel.bodyHeight = height
        if height > 0.25 {
            bodyPanel.setFrame(viewModel.layout.bodyFrame(width: width, height: height), display: true)
            if !bodyPanel.isVisible { bodyPanel.orderFrontRegardless() }
        } else { bodyPanel.orderOut(nil) }
        updateHitTesting()
    }
}

private enum IslandPart { case crown, body }

private struct CrownShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: min(radius, rect.height / 2),
                               bottomTrailingRadius: min(radius, rect.height / 2), topTrailingRadius: 0,
                               style: .continuous).path(in: rect)
    }
}

private struct IslandBodyShape: Shape {
    let neckWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        let shoulder = min(23, rect.height / 2)
        let bottom = min(28, rect.height / 2)
        let halfNeck = min(neckWidth, rect.width) / 2
        let l = rect.midX - halfNeck, r = rect.midX + halfNeck
        return Path { p in
            p.move(to: CGPoint(x: l, y: 0))
            p.addLine(to: CGPoint(x: r, y: 0))
            p.addCurve(to: CGPoint(x: rect.maxX, y: shoulder), control1: CGPoint(x: r, y: shoulder * 0.6), control2: CGPoint(x: rect.maxX, y: 0))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: bottom, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - bottom), control: CGPoint(x: 0, y: rect.maxY))
            p.addLine(to: CGPoint(x: 0, y: shoulder))
            p.addCurve(to: CGPoint(x: l, y: 0), control1: CGPoint(x: 0, y: 0), control2: CGPoint(x: l, y: shoulder * 0.6))
            p.closeSubpath()
        }
    }
}

private struct DynamicIslandView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let part: IslandPart
    @ObservedObject var viewModel: IslandViewModel
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    let onOpenDetails: () -> Void
    let onOpenCurrentAssistant: () -> Void
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var data: UsageSnapshot { store.activeSnapshot }
    private var accent: Color { Color(store.activeAssistant.palette.accent) }
    private var accentGradient: LinearGradient {
        LinearGradient(colors: [Color(store.activeAssistant.palette.start), Color(store.activeAssistant.palette.end)],
                       startPoint: .leading, endPoint: .trailing)
    }
    private var hasModel: Bool { !data.currentModel.hasPrefix("模型未") && !data.currentModel.hasPrefix("等待") }
    private var model: String { hasModel ? data.currentModel : store.activeAssistant.displayName }
    private var assistant: String { store.activeAssistant.displayName }
    private var activity: Bool { data.isTaskRunning }
    private var metric: String { store.activeMetricValue }
    private var metricTitle: String { store.activeMetricTitle }
    private var crownShape: CrownShape { CrownShape(radius: max(0, viewModel.layout.bandHeight / 2 * (1 - min(1, viewModel.bodyHeight / 28)))) }
    private var bodyShape: IslandBodyShape {
        IslandBodyShape(neckWidth: viewModel.layout.crownFrame.width)
    }

    var body: some View {
        Group {
            if part == .crown { crownContent }
            else { expandedBody }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(viewModel.completionNotice != nil ? "任务完成，点击返回 \(assistant)" : "\(assistant) 灵动岛，\(activity ? "任务进行中" : "未观察到进行中的任务")")
    }

    private var crownContent: some View {
        ZStack {
            crownShape.fill(Color.black)
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    if viewModel.layout.leftWing >= 100 { signal.frame(width: 13, height: 18) }
                    VStack(spacing: 0.5) {
                        Text(IslandCompactText.model(model).primary)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.75).truncationMode(.middle)
                        if let detail = IslandCompactText.model(model).secondary {
                            Text(detail)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.75).truncationMode(.middle)
                        }
                        if activity && viewModel.layout.leftWing < 100 {
                            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
                                Capsule().fill(accentGradient)
                                    .opacity(reduceMotion ? 0.8 : 0.55 + 0.35 * sin(context.date.timeIntervalSinceReferenceDate * 4.2))
                            }
                            .frame(height: 1.5).padding(.top, 1)
                            .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(accentGradient)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, viewModel.layout.leftWing >= 50 ? 6 : 2)
                .frame(width: viewModel.layout.leftWing, height: viewModel.layout.bandHeight)
                .clipped().contentShape(Rectangle()).onHover(perform: onHover).onTapGesture(perform: onTap)
                .help("\(assistant) · 当前模型：\(data.currentModel)\n\(data.metricsSource)")
                .accessibilityLabel("当前模型 \(data.currentModel)，\(activity ? "任务进行中" : "未观察到进行中的任务")")
                Color.clear.frame(width: viewModel.layout.gapWidth).allowsHitTesting(false).accessibilityHidden(true)
                Text(IslandCompactText.metric(metric, characterBudget: viewModel.layout.rightWing < 38 ? 4 : 7))
                    .font(.system(size: viewModel.layout.rightWing >= 42 ? 10.5 : 9, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(accentGradient)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, viewModel.layout.rightWing >= 38 ? 3 : 1)
                    .frame(width: viewModel.layout.rightWing, height: viewModel.layout.bandHeight)
                    .clipped().contentShape(Rectangle()).onHover(perform: onHover).onTapGesture(perform: onTap)
                    .help("\(metricTitle)：\(metric)\n\(store.activeMetricDetail)")
                    .accessibilityLabel("\(metricTitle) \(metric)")
            }
        }
        .clipShape(crownShape)
        .onReceive(timer) { _ in store.refresh() }
    }

    private var expandedBody: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                bodyShape.fill(Color.black)
                Group {
                    if let notice = viewModel.completionNotice {
                        completion(notice)
                    } else { expanded }
                }
                .frame(width: geometry.size.width, height: viewModel.completionNotice == nil ? 152 : 88, alignment: .top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipShape(bodyShape)
            .contentShape(bodyShape)
            .onHover(perform: onHover).onTapGesture(perform: onTap)
        }
    }

    private var expanded: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                signal.frame(width: 24, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model).font(.system(size: 13, weight: .semibold)).foregroundStyle(accentGradient).lineLimit(1)
                    Text(activity ? "正在处理任务" : (hasModel ? assistant : "当前模型未读取"))
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(metric).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(accentGradient)
                    Text(metricTitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
            }
            HStack(spacing: 12) {
                IslandMetric(title: "今日 Token", value: data.tokenDisplayValue)
                IslandMetric(title: data.contextIsEstimate && data.contextPercent != nil ? "上下文估算" : "上下文", value: data.contextDisplayValue)
                IslandMetric(title: "缓存命中", value: data.cacheHitDisplayValue)
            }
            .help(data.metricsDiagnostic ?? data.metricsSource)
            HStack(spacing: 12) {
                Button(action: onOpenCurrentAssistant) { Label("返回 \(assistant)", systemImage: "arrow.up.right") }
                    .buttonStyle(IslandButtonStyle(accent: accent))
                Spacer()
                if let rechargeURL = data.providerRechargeURL {
                    Button("充值") { NSWorkspace.shared.open(rechargeURL) }
                        .buttonStyle(IslandButtonStyle(accent: .white.opacity(0.7)))
                        .help("打开当前 API 提供方的充值页面")
                }
                Button("用量详情", action: onOpenDetails).buttonStyle(IslandButtonStyle(accent: .white.opacity(0.7)))
            }
        }.padding(.horizontal, 23).padding(.top, 15).padding(.bottom, 14)
    }

    private var signal: some View {
        ZStack {
            if activity {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    HStack(spacing: 2.4) {
                        ForEach(0..<3) { index in
                            Capsule().fill(accentGradient).frame(width: 2.6, height: reduceMotion ? 10 : 5 + 8 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4.2 + Double(index) * 1.5)))
                        }
                    }
                }
            } else {
                Image(systemName: store.activeAssistant.symbolName)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(accentGradient)
            }
        }.accessibilityLabel(activity ? "任务进行中" : "未观察到进行中的任务")
    }

    private func completion(_ notice: TaskCompletionNotice) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.15))
                Circle().stroke(accent.opacity(viewModel.completionRevealed ? 0 : 0.45), lineWidth: 1)
                    .scaleEffect(reduceMotion ? 1 : (viewModel.completionRevealed ? 1.32 : 0.8))
                CheckmarkShape().trim(from: 0, to: viewModel.completionRevealed ? 1 : 0)
                    .stroke(accentGradient, style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 15)
            }.frame(width: 40, height: 40)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.48), value: viewModel.completionRevealed)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("任务完成").foregroundStyle(accentGradient)
                    Text("· \(assistant)").foregroundStyle(.white.opacity(0.45))
                }.font(.system(size: 10.5, weight: .semibold))
                Text(notice.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(store.activeAssistant != .chatGPT ? "已收到完成事件 · 点击返回查看" : "\(notice.usageKnown ? notice.usageDisplayValue + " Token" : "计数未返回") · \(notice.secondaryMetricTitle) \(notice.secondaryMetricValue)")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
}

extension Color {
    init(_ rgb: AssistantPalette.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}
private struct IslandButtonStyle: ButtonStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .foregroundStyle(accent.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.vertical, 3).contentShape(Rectangle())
    }
}
private struct IslandMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
