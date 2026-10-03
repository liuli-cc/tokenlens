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
final class IslandPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var motionStyle: IslandMotionStyle { didSet { defaults.set(motionStyle.rawValue, forKey: "island.motionStyle") } }
    @Published var glowEnabled: Bool { didSet { defaults.set(glowEnabled, forKey: "island.glow") } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "island.sound") } }
    @Published var followSystemMotion: Bool { didSet { defaults.set(followSystemMotion, forKey: "island.followSystemMotion") } }
    @Published var noticeDuration: Double { didSet { defaults.set(noticeDuration, forKey: "island.noticeDuration") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        motionStyle = IslandMotionStyle(rawValue: defaults.string(forKey: "island.motionStyle") ?? "jelly") ?? .jelly
        glowEnabled = defaults.object(forKey: "island.glow") as? Bool ?? true
        soundEnabled = defaults.bool(forKey: "island.sound")
        followSystemMotion = defaults.object(forKey: "island.followSystemMotion") as? Bool ?? true
        let duration = defaults.double(forKey: "island.noticeDuration")
        noticeDuration = [6.0, 10.0, 14.0].contains(duration) ? duration : 6
    }
}

enum IslandPage { case overview, history, settings }

@MainActor
final class IslandViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var completionNotice: TaskCompletionNotice?
    @Published var completionRevealed = false
    @Published var bodyHeight: CGFloat = 0
    @Published var surfaceWidth: CGFloat = 446
    @Published var edgeGlow: Double = 0
    @Published var glowAssistant: IslandAssistant?
    @Published var neckOffset: CGFloat = 0
    @Published var isPinned = false
    @Published var page: IslandPage = .overview
    @Published var completionMotion = IslandCompletionMotion.sample(at: -1)
    @Published var haloMargin: CGFloat = 24
    @Published var layout = IslandGeometry.layout(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeTopInset: 0, leftAux: nil, rightAux: nil)
}

@MainActor
final class IslandPanelController: NSObject {
    private let store: UsageStore
    private let onOpenAssistant: (IslandAssistant) -> Void
    private let preferences: IslandPreferences
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
    private var glowSpring = IslandSpring(position: 0, target: 0, frequency: 18, damping: 1)
    private var occupied: [CGRect] = []
    private var conservativeWings = true
    private var completionMotionStarted: Double?
    private var completionFromHeight: Double = 0
    private var completionFromWidth: Double = 400
    private let haloMargin: CGFloat = 24
    private let haloBottom: CGFloat = 26
    private var surfaceFrame = CGRect.zero
    private var activeCanvas: CGRect?
    private var canvasScreen: CGRect?
    private var canvasCrownBottom: CGFloat?
    #if TOKENLENS_PREVIEW
    private var bodyFrameUpdates = 0
    #endif

    init(store: UsageStore, onOpenDetails: @escaping () -> Void, onOpenAssistant: @escaping (IslandAssistant) -> Void,
         preferences: IslandPreferences? = nil) {
        let preferences = preferences ?? IslandPreferences()
        self.store = store
        self.onOpenAssistant = onOpenAssistant
        self.preferences = preferences
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
                part: part, viewModel: viewModel, preferences: preferences,
                onHover: { [weak self] inside in self?.hover(inside) },
                onTap: { [weak self] in self?.handleTap() },
                onOpenDetails: onOpenDetails, onOpenAssistant: onOpenAssistant,
                onDismiss: { [weak self] in
                    guard let self, let notice = self.viewModel.completionNotice else { return }
                    self.finishCompletionNotice(notice)
                },
                onPage: { [weak self] page in self?.setPage(page) },
                onPin: { [weak self] in self?.togglePin() },
                onPreview: { [weak self] in self?.previewMotion() }
            ).environmentObject(store))
            host.sizingOptions = []
            panel.contentView = host
        }
        store.$completionNotice.compactMap { $0 }.removeDuplicates(by: { $0.id == $1.id })
            .sink { [weak self] notice in Task { @MainActor in self?.presentCompletionNotice(notice) } }
            .store(in: &cancellables)
        preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateTargets(animated: true) }
        }.store(in: &cancellables)
    }

    func start() {
        currentScreen = NSScreen.main ?? NSScreen.screens.first
        updateLayout(animated: false)
        crown.orderFrontRegardless()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // AppKit invokes both event monitors on the main thread. Handle the
            // click synchronously, before the pointer or notice source changes.
            MainActor.assumeIsolated { _ = self?.handlePointerEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handlePointerEvent(event) ?? false }
            // At the cutout boundary the wing can also receive the event.
            // Consuming a handled local click prevents a second SwiftUI tap.
            return handled ? nil : event
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
        guard IslandAssistant.completionSource(notice.source) != nil,
              viewModel.completionNotice?.id != notice.id else { return }
        completionTask?.cancel(); hoverTask?.cancel(); collapseTask?.cancel()
        hoverTask = nil; collapseTask = nil
        advanceMotion()
        completionFromHeight = heightSpring.position
        completionFromWidth = widthSpring.position
        viewModel.completionNotice = notice
        viewModel.glowAssistant = IslandAssistant.completionSource(notice.source)
        viewModel.completionRevealed = false
        viewModel.completionMotion = .sample(at: 0, style: preferences.motionStyle,
                                            reduceMotion: preferences.followSystemMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        viewModel.isExpanded = true
        completionMotionStarted = CACurrentMediaTime()
        updateTargets(animated: true)
        if preferences.soundEnabled && notice.provider != "Preview" { NSSound(named: "Glass")?.play() }
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(540))
            guard !Task.isCancelled, let self else { return }
            self.viewModel.completionRevealed = true
            try? await Task.sleep(for: .seconds(self.preferences.noticeDuration))
            guard !Task.isCancelled else { return }
            // Keep the target steady while the user reads or reaches its action.
            for _ in 0..<60 {
                guard self.contains(NSEvent.mouseLocation) else { break }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            self.finishCompletionNotice(notice)
        }
    }

    private func finishCompletionNotice(_ notice: TaskCompletionNotice) {
        guard viewModel.completionNotice?.id == notice.id else { return }
        completionTask?.cancel()
        heightSpring.position = Double(viewModel.bodyHeight)
        widthSpring.position = Double(viewModel.surfaceWidth)
        heightSpring.velocity = 0; widthSpring.velocity = 0
        viewModel.completionNotice = nil
        viewModel.completionRevealed = false
        completionMotionStarted = nil
        viewModel.completionMotion = .sample(at: -1)
        viewModel.isExpanded = viewModel.isPinned || contains(NSEvent.mouseLocation)
        updateTargets(animated: true)
        store.dismissCompletionNotice(id: notice.id)
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
        guard bodyPanel.isVisible, surfaceFrame.contains(point) else { return false }
        return bodyShape.path(in: CGRect(origin: .zero, size: surfaceFrame.size))
            .contains(CGPoint(x: point.x - surfaceFrame.minX, y: surfaceFrame.maxY - point.y))
    }
    private var bodyShape: IslandBodyShape {
        IslandBodyShape(neckWidth: viewModel.layout.crownFrame.width, reveal: min(1, viewModel.bodyHeight / 100), neckOffset: viewModel.neckOffset)
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
    private func handlePointerEvent(_ event: NSEvent) -> Bool {
        pointerMoved()
        guard event.type == .leftMouseDown, crown.isVisible else { return false }
        let point: CGPoint
        if let mouseEvent = event.cgEvent, let primary = NSScreen.screens.first {
            // Quartz events use the primary display's top-left origin. Convert
            // the event snapshot, rather than reading a later cursor position.
            point = IslandGeometry.screenPoint(fromQuartz: mouseEvent.location, primaryScreen: primary.frame)
        } else if let window = event.window {
            point = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            point = event.locationInWindow
        }
        guard viewModel.layout.cameraContains(point) else { return false }
        handleTap()
        return true
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
        guard viewModel.completionNotice == nil, !viewModel.isPinned else { return }
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
        let assistant = viewModel.completionNotice.flatMap { IslandAssistant.completionSource($0.source) } ?? store.activeAssistant
        if let notice = viewModel.completionNotice { finishCompletionNotice(notice) }
        onOpenAssistant(assistant)
    }

    private func setPage(_ page: IslandPage) {
        viewModel.page = page
        viewModel.isExpanded = true
        updateTargets(animated: true)
    }
    private func togglePin() {
        viewModel.isPinned.toggle()
        hoverTask?.cancel(); hoverTask = nil
        collapseTask?.cancel(); collapseTask = nil
        viewModel.isExpanded = viewModel.isPinned || contains(NSEvent.mouseLocation)
        updateTargets(animated: true)
    }
    private func previewMotion() {
        advanceMotion()
        completionFromHeight = heightSpring.position
        completionFromWidth = widthSpring.position
        viewModel.glowAssistant = store.activeAssistant
        completionMotionStarted = CACurrentMediaTime()
        updateTargets(animated: true)
    }

    private var reduceMotion: Bool {
        preferences.followSystemMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var glowTarget: Double {
        guard preferences.glowEnabled else { return 0 }
        let holding = viewModel.completionNotice != nil ? 0.38 : 0
        return reduceMotion ? holding : max(holding, viewModel.completionMotion.glow)
    }
    private func updateTargets(animated: Bool) {
        advanceMotion()
        heightSpring.target = viewModel.completionNotice != nil ? 118 : (viewModel.isExpanded ? (viewModel.page == .overview ? 218 : 246) : 0)
        widthSpring.target = Double(viewModel.isExpanded ? viewModel.layout.expandedWidth : viewModel.layout.bodyBaseWidth)
        // Hover and closing are critically damped. Only the single completion
        // timeline supplies deformation; no independent spring can fight it.
        heightSpring.damping = 1
        widthSpring.damping = 1
        heightSpring.frequency = viewModel.isExpanded ? 20 : 24
        widthSpring.frequency = heightSpring.frequency
        glowSpring.target = glowTarget
        if !animated || reduceMotion {
            heightSpring.settle(); widthSpring.settle(); glowSpring.settle()
            completionMotionStarted = nil
            viewModel.completionMotion = .sample(at: -1)
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
    private func sampleCompletion(elapsed: Double) {
        let sample = IslandCompletionMotion.sample(at: elapsed, style: preferences.motionStyle, reduceMotion: reduceMotion)
        viewModel.completionMotion = sample
        heightSpring.position = completionFromHeight + (heightSpring.target - completionFromHeight) * sample.openingProgress
        widthSpring.position = completionFromWidth + (widthSpring.target - completionFromWidth) * sample.openingProgress
        heightSpring.velocity = 0; widthSpring.velocity = 0
    }
    private func advanceMotion() {
        let now = CACurrentMediaTime()
        let delta = max(0, now - lastMotionTime)
        if let started = completionMotionStarted {
            let elapsed = now - started
            sampleCompletion(elapsed: elapsed)
            if elapsed >= IslandCompletionMotion.duration { completionMotionStarted = nil }
        } else if motionTimer != nil {
            heightSpring.advance(by: delta)
            widthSpring.advance(by: delta)
        }
        glowSpring.target = glowTarget
        glowSpring.advance(by: delta)
        lastMotionTime = now
    }
    @objc private func tick() {
        advanceMotion()
        if heightSpring.isSettled && widthSpring.isSettled && glowSpring.isSettled && completionMotionStarted == nil {
            heightSpring.settle(); widthSpring.settle(); glowSpring.settle()
            motionTimer?.invalidate(); motionTimer = nil
        }
        applyMotion()
        // A stationary pointer must track the contour as it deforms, including
        // the transparent halo of the fixed-size canvas.
        if viewModel.completionNotice == nil { hover(contains(NSEvent.mouseLocation)) }
    }
    private func applyMotion() {
        let height = max(0, CGFloat(heightSpring.position + viewModel.completionMotion.heightOffset))
        let width = max(viewModel.layout.bodyBaseWidth, CGFloat(widthSpring.position + viewModel.completionMotion.widthOffset))
        if height > 0.25 && (activeCanvas == nil || canvasScreen != viewModel.layout.screen || canvasCrownBottom != crown.frame.minY) {
            let canvasWidth = min(viewModel.layout.bodyMaximumWidth, max(viewModel.layout.expandedWidth + 12, viewModel.layout.bodyBaseWidth))
            let margin = min(haloMargin, max(0, (viewModel.layout.bodyMaximumWidth - canvasWidth) / 2))
            viewModel.haloMargin = margin
            var canvas = viewModel.layout.bodyFrame(width: canvasWidth + margin * 2, height: 264 + haloBottom)
            canvas.origin.y = crown.frame.minY - canvas.height
            bodyPanel.setFrame(canvas, display: true)
            // AppKit may round a fractional requested frame. Retain its actual
            // result so no subpixel mismatch retriggers a window resize.
            activeCanvas = bodyPanel.frame
            canvasScreen = viewModel.layout.screen
            canvasCrownBottom = crown.frame.minY
            #if TOKENLENS_PREVIEW
            bodyFrameUpdates += 1
            #endif
        }
        let anchor = activeCanvas?.midX ?? viewModel.layout.bodyAnchorX
        let capacity = max(1, 2 * min(anchor - viewModel.layout.screen.minX, viewModel.layout.screen.maxX - anchor))
        let visibleWidth = min(width, capacity)
        surfaceFrame = CGRect(x: anchor - visibleWidth / 2, y: (activeCanvas?.maxY ?? crown.frame.minY) - height,
                              width: visibleWidth, height: height)
        viewModel.bodyHeight = height
        viewModel.surfaceWidth = surfaceFrame.width
        viewModel.neckOffset = viewModel.layout.crownFrame.midX - anchor
        viewModel.edgeGlow = min(1, max(0, glowSpring.position))
        if viewModel.completionNotice == nil && completionMotionStarted == nil && viewModel.edgeGlow < 0.005 {
            viewModel.glowAssistant = nil
        }
        if height > 0.25 {
            // One fixed canvas for every body state. WindowServer no longer
            // resizes/repositions a native window at each animation frame.
            if !bodyPanel.isVisible { bodyPanel.orderFrontRegardless() }
        } else {
            bodyPanel.orderOut(nil)
            activeCanvas = nil; canvasScreen = nil; canvasCrownBottom = nil
        }
        updateHitTesting()
    }

    #if TOKENLENS_PREVIEW
    // Test-only access to the real routing method. Synthetic events are passed
    // directly to it; they are never posted to the system event stream.
    func previewHandlePointerEvent(_ event: NSEvent) -> Bool { handlePointerEvent(event) }
    var previewCompletionNoticeID: String? { viewModel.completionNotice?.id }
    func previewSetLayout(_ layout: IslandLayout) {
        hoverTask?.cancel(); hoverTask = nil
        collapseTask?.cancel(); collapseTask = nil
        viewModel.layout = layout
        crown.setFrame(layout.crownFrame, display: true)
        crown.orderFrontRegardless()
        updateTargets(animated: false)
    }
    func previewStep(elapsed: Double, by delta: Double) {
        motionTimer?.invalidate(); motionTimer = nil
        completionTask?.cancel(); completionTask = nil
        completionMotionStarted = nil
        sampleCompletion(elapsed: elapsed)
        glowSpring.target = glowTarget
        glowSpring.advance(by: delta)
        viewModel.completionRevealed = elapsed >= 0.54
        applyMotion()
    }
    func previewCloseNotice() {
        if let notice = viewModel.completionNotice { finishCompletionNotice(notice) }
    }
    func previewReset() {
        completionTask?.cancel(); completionTask = nil
        motionTimer?.invalidate(); motionTimer = nil
        completionMotionStarted = nil
        viewModel.isPinned = false
        viewModel.isExpanded = false
        viewModel.page = .overview
        viewModel.completionMotion = .sample(at: -1)
        heightSpring.target = 0; heightSpring.settle()
        widthSpring.target = Double(viewModel.layout.bodyBaseWidth); widthSpring.settle()
        glowSpring.target = 0; glowSpring.settle()
        applyMotion()
    }
    func previewPage(_ page: IslandPage) {
        setPage(page)
        viewModel.isPinned = true
    }
    func previewDiagnostics() -> [String: Any] {
        let frame = bodyPanel.frame
        let transparent = CGPoint(x: frame.minX + 2, y: frame.minY + 2)
        return ["visible": bodyPanel.isVisible, "canvas": [frame.minX, frame.minY, frame.width, frame.height],
                "surface": [surfaceFrame.minX, surfaceFrame.minY, surfaceFrame.width, surfaceFrame.height],
                "glow": viewModel.edgeGlow, "haloAcceptsClicks": bodyContains(transparent),
                "bodyFrameUpdates": bodyFrameUpdates, "crownBottom": crown.frame.minY]
    }
    /// Captures only this synthetic preview's own rendered views. No desktop,
    /// chat contents, user sessions or other applications enter the artifact.
    func previewCapture(to url: URL) throws {
        let canvas = NSSize(width: 680, height: 380)
        let image = NSImage(size: canvas)
        image.lockFocus()
        NSColor(srgbRed: 0.07, green: 0.075, blue: 0.09, alpha: 1).setFill()
        CGRect(origin: .zero, size: canvas).fill()
        func draw(_ panel: NSPanel, at origin: CGPoint) {
            guard panel.isVisible, let host = panel.contentView else { return }
            // SwiftUI reuses backing layers after motion settles. Force this
            // synthetic export's entire view tree to redraw into the bitmap.
            func invalidate(_ view: NSView) {
                view.needsDisplay = true
                for child in view.subviews { invalidate(child) }
            }
            invalidate(host)
            host.layoutSubtreeIfNeeded()
            host.display()
            CATransaction.flush()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let shot = NSImage(size: host.bounds.size)
            shot.addRepresentation(rep)
            shot.draw(in: CGRect(origin: origin, size: host.bounds.size))
        }
        let crownOrigin = CGPoint(x: (canvas.width - crown.frame.width) / 2, y: 328 - crown.frame.height)
        draw(crown, at: crownOrigin)
        draw(bodyPanel, at: CGPoint(x: crownOrigin.x + bodyPanel.frame.minX - crown.frame.minX,
                                   y: crownOrigin.y + bodyPanel.frame.minY - crown.frame.minY))
        let label = "TokenLens · 本地合成动效预览"
        (label as NSString).draw(at: CGPoint(x: 22, y: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35)
        ])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
    #endif
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
    var reveal: CGFloat = 1
    var neckOffset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let shoulder = min(23 + (1 - reveal) * 30, rect.height / 2)
        let bottom = min(28, rect.height / 2)
        let halfNeck = min(neckWidth, rect.width) / 2
        let l = max(0, min(rect.maxX, rect.midX + neckOffset - halfNeck))
        let r = max(l, min(rect.maxX, rect.midX + neckOffset + halfNeck))
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let part: IslandPart
    @ObservedObject var viewModel: IslandViewModel
    @ObservedObject var preferences: IslandPreferences
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    let onOpenDetails: () -> Void
    let onOpenAssistant: (IslandAssistant) -> Void
    let onDismiss: () -> Void
    let onPage: (IslandPage) -> Void
    let onPin: () -> Void
    let onPreview: () -> Void
    private var reduceMotion: Bool { systemReduceMotion && preferences.followSystemMotion }
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var presentationAssistant: IslandAssistant {
        viewModel.completionNotice.flatMap { IslandAssistant.completionSource($0.source) } ?? store.activeAssistant
    }
    private var data: UsageSnapshot { store.snapshot(for: presentationAssistant) }
    private var accent: Color { Color(presentationAssistant.palette.accent) }
    private var edgeAccent: Color { Color((viewModel.glowAssistant ?? presentationAssistant).palette.accent) }
    private var edgeGradient: LinearGradient {
        let palette = (viewModel.glowAssistant ?? presentationAssistant).palette
        return LinearGradient(colors: [Color(palette.start), Color(palette.accent), Color(palette.end)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var accentGradient: LinearGradient {
        LinearGradient(colors: [Color(presentationAssistant.palette.start), Color(presentationAssistant.palette.end)],
                       startPoint: .leading, endPoint: .trailing)
    }
    private var hasModel: Bool { !data.currentModel.hasPrefix("模型未") && !data.currentModel.hasPrefix("等待") }
    private var model: String { hasModel ? data.currentModel : presentationAssistant.displayName }
    private var assistant: String { presentationAssistant.displayName }
    private var activity: Bool { data.isTaskRunning }
    private var metric: String { viewModel.completionNotice != nil ? "完成" : store.activeMetricValue }
    private var metricTitle: String { store.activeMetricTitle }
    private var crownShape: CrownShape { CrownShape(radius: max(0, viewModel.layout.bandHeight / 2 * (1 - min(1, viewModel.bodyHeight / 28)))) }
    private var bodyShape: IslandBodyShape {
        IslandBodyShape(neckWidth: viewModel.layout.crownFrame.width, reveal: min(1, viewModel.bodyHeight / 100), neckOffset: viewModel.neckOffset)
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
            crownShape.stroke(edgeGradient.opacity(viewModel.edgeGlow * 0.78), lineWidth: 1.3)
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
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                // All glow contours live outside the content mask. A sharp
                // luminous rim remains visible even when background blur is
                // reduced by the system's compositor/accessibility settings.
                bodyShape.stroke(edgeGradient.opacity(viewModel.edgeGlow * 0.65), lineWidth: 1.3)
                    .frame(width: viewModel.surfaceWidth, height: viewModel.bodyHeight)
                    .shadow(color: edgeAccent.opacity(viewModel.edgeGlow * 0.55), radius: 8)
                    .shadow(color: edgeAccent.opacity(viewModel.edgeGlow * 0.3), radius: 3)
                    .allowsHitTesting(false)
                bodyShape.fill(Color.black)
                    .frame(width: viewModel.surfaceWidth, height: viewModel.bodyHeight)
                    .shadow(color: .black.opacity(0.32), radius: 7, x: 0, y: 4)
                ZStack(alignment: .top) {
                    bodyShape.fill(LinearGradient(colors: [.white.opacity(0.035), .black], startPoint: .top, endPoint: .bottom))
                    Group {
                        if let notice = viewModel.completionNotice { completion(notice) }
                        else {
                            VStack(spacing: 0) {
                                toolbar
                                switch viewModel.page {
                                case .overview: expanded
                                case .history: history
                                case .settings: settings
                                }
                            }
                        }
                    }
                    .frame(width: viewModel.layout.expandedWidth, height: viewModel.completionNotice != nil ? 118 : (viewModel.page == .overview ? 218 : 246), alignment: .top)
                    .opacity(viewModel.completionNotice != nil && !reduceMotion ? viewModel.completionMotion.reveal : 1)
                }
                .frame(width: viewModel.surfaceWidth, height: viewModel.bodyHeight, alignment: .top)
                .clipShape(bodyShape)
                bodyShape.stroke(LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0.035)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                    .frame(width: viewModel.surfaceWidth, height: viewModel.bodyHeight)
                    .allowsHitTesting(false)
                bodyShape.stroke(edgeGradient.opacity(viewModel.edgeGlow * 0.92), lineWidth: 1.35)
                    .frame(width: viewModel.surfaceWidth, height: viewModel.bodyHeight)
                    .allowsHitTesting(false)
            }
            .frame(width: viewModel.surfaceWidth, height: viewModel.bodyHeight, alignment: .top)
            .contentShape(bodyShape)
            .onHover(perform: onHover)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 4, height: 4)
                Text(viewModel.page == .overview ? "助手状态" : (viewModel.page == .history ? "最近完成" : "灵动岛偏好"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
            if viewModel.page != .overview {
                iconButton("返回状态", symbol: "arrow.left", active: false) { onPage(.overview) }
            }
            iconButton("最近完成", symbol: "clock.arrow.circlepath", active: viewModel.page == .history) { onPage(.history) }
            iconButton(viewModel.isPinned ? "取消固定" : "固定展开", symbol: viewModel.isPinned ? "pin.fill" : "pin", active: viewModel.isPinned, action: onPin)
            iconButton("动效与提醒设置", symbol: "slider.horizontal.3", active: viewModel.page == .settings) { onPage(.settings) }
        }
        .padding(.horizontal, 23).padding(.top, 15).padding(.bottom, 11)
    }

    private func iconButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? accent : .white.opacity(0.5)).frame(width: 23, height: 20)
                .background(active ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private var expanded: some View {
        VStack(spacing: 13) {
            HStack(spacing: 11) {
                AssistantGlyph(assistant: presentationAssistant, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.94)).lineLimit(1)
                    HStack(spacing: 5) {
                        if activity { signal.frame(width: 13, height: 11) }
                        Text(activity ? "正在处理任务" : assistant).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.48))
                    }
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(metric).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(accentGradient)
                    Text(metricTitle).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.43))
                }
            }
            HStack(spacing: 12) {
                IslandMetric(title: "今日 Token", value: data.tokenDisplayValue)
                IslandMetric(title: data.contextIsEstimate && data.contextPercent != nil ? "上下文估算" : "上下文", value: data.contextDisplayValue)
                IslandMetric(title: "缓存命中", value: data.cacheHitDisplayValue)
            }.help(data.metricsDiagnostic ?? data.metricsSource)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
            HStack(spacing: 9) {
                ForEach(IslandAssistant.allCases, id: \.self) { item in
                    Button { onOpenAssistant(item) } label: {
                        AssistantGlyph(assistant: item, size: 21)
                            .padding(4).background(item == presentationAssistant ? Color(item.palette.accent).opacity(0.12) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help("打开 " + item.displayName).accessibilityLabel("打开 " + item.displayName)
                }
                Spacer(minLength: 4)
                if let rechargeURL = data.providerRechargeURL {
                    Button("充值") { NSWorkspace.shared.open(rechargeURL) }.buttonStyle(IslandButtonStyle(accent: .white.opacity(0.6)))
                }
                Button("用量详情", action: onOpenDetails).buttonStyle(IslandButtonStyle(accent: .white.opacity(0.65)))
            }
            HStack {
                Button { onOpenAssistant(presentationAssistant) } label: { Label("返回 " + assistant, systemImage: "arrow.up.right") }
                    .buttonStyle(IslandButtonStyle(accent: accent))
                Spacer()
                if let notice = store.recentCompletions.first {
                    Text(notice.completedAt, style: .relative).font(.system(size: 9)).foregroundStyle(.white.opacity(0.32))
                    Text("前完成").font(.system(size: 9)).foregroundStyle(.white.opacity(0.32))
                }
            }
        }.padding(.horizontal, 23)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.recentCompletions.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24, weight: .light)).foregroundStyle(accent.opacity(0.7))
                    Text("完成的任务会留在这里").font(.system(size: 12, weight: .medium))
                    Text("只收录本次运行中收到的明确完成事件").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                }.frame(maxWidth: .infinity).padding(.top, 38)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(store.recentCompletions, id: \.id) { notice in
                            if let source = IslandAssistant.completionSource(notice.source) {
                                Button { onOpenAssistant(source) } label: {
                                    HStack(spacing: 9) {
                                        AssistantGlyph(assistant: source, size: 25)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(notice.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                                            Text(source.displayName).font(.system(size: 9)).foregroundStyle(Color(source.palette.accent).opacity(0.8))
                                        }
                                        Spacer(minLength: 6)
                                        Text(notice.completedAt, style: .time).font(.system(size: 9)).monospacedDigit().foregroundStyle(.white.opacity(0.38))
                                        Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(.white.opacity(0.3))
                                    }.padding(9).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(height: 175)
            }
        }.padding(.horizontal, 21)
    }

    private var settings: some View {
        VStack(spacing: 12) {
            HStack {
                Text("弹跳质感").font(.system(size: 11))
                Spacer()
                ForEach(IslandMotionStyle.allCases, id: \.self) { style in
                    Button { preferences.motionStyle = style } label: {
                        Text(style.title).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(preferences.motionStyle == style ? accent : .white.opacity(0.45))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(preferences.motionStyle == style ? accent.opacity(0.13) : .white.opacity(0.035), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Toggle("软件微光", isOn: $preferences.glowEnabled)
                Spacer(minLength: 25)
                Toggle("完成提示音", isOn: $preferences.soundEnabled)
            }.toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).tint(accent)
            HStack {
                Toggle("跟随系统减少动态效果", isOn: $preferences.followSystemMotion)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)).tint(accent)
                Spacer()
                Text(reduceMotion ? "轻静显示" : "完整动效").font(.system(size: 9)).foregroundStyle(.white.opacity(0.36))
            }
            HStack {
                Text("提醒停留").font(.system(size: 11))
                Spacer()
                ForEach([6.0, 10.0, 14.0], id: \.self) { duration in
                    Button { preferences.noticeDuration = duration } label: {
                        Text("\(Int(duration)) 秒").font(.system(size: 10)).foregroundStyle(preferences.noticeDuration == duration ? accent : .white.opacity(0.4))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(preferences.noticeDuration == duration ? accent.opacity(0.13) : .white.opacity(0.035), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
            HStack {
                Text(reduceMotion ? "已跟随系统减少动态效果" : "悬停可延长提醒 · 历史保留最近 20 条")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button("试试弹跳", action: onPreview).buttonStyle(IslandButtonStyle(accent: accent))
            }
            Text("GPT / Harness 有明确完成事件时自动提醒；其他软件接入可靠事件后启用。")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 23).padding(.top, 2)
    }

    private var signal: some View {
        ZStack {
            if viewModel.completionNotice != nil {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(accentGradient)
            } else if activity {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    HStack(spacing: 2.4) {
                        ForEach(0..<3) { index in
                            Capsule().fill(accentGradient).frame(width: 2.6, height: reduceMotion ? 10 : 5 + 8 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4.2 + Double(index) * 1.5)))
                        }
                    }
                }
            } else {
                Image(systemName: presentationAssistant.symbolName).font(.system(size: 12, weight: .semibold)).foregroundStyle(accentGradient)
            }
        }.accessibilityLabel(viewModel.completionNotice != nil ? "任务完成" : (activity ? "任务进行中" : "未观察到进行中的任务"))
    }

    private func completion(_ notice: TaskCompletionNotice) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 13) {
                ZStack(alignment: .bottomTrailing) {
                    AssistantGlyph(assistant: presentationAssistant, size: 39)
                        .scaleEffect(x: 1 + viewModel.completionMotion.iconSquash,
                                     y: 1 - viewModel.completionMotion.iconSquash, anchor: .bottom)
                        .offset(y: viewModel.completionMotion.iconLift)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent).background(.black, in: Circle())
                        .opacity(viewModel.completionRevealed ? 1 : 0)
                        .offset(x: 4, y: 4)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: viewModel.completionRevealed)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text("任务完成").foregroundStyle(accentGradient)
                        Text("· " + assistant).foregroundStyle(.white.opacity(0.42))
                    }.font(.system(size: 10, weight: .semibold))
                    Text(notice.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    Text(completionDetail(notice))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.46)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }.contentShape(Rectangle()).onTapGesture(perform: onTap)
            HStack {
                Text(store.pendingCompletionCount > 1 ? "另有 \(store.pendingCompletionCount - 1) 条提醒" : "点击返回查看 · 悬停继续停留")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.34))
                Spacer()
                Button(store.pendingCompletionCount > 1 ? "下一条" : "关闭提醒", action: onDismiss)
                    .buttonStyle(IslandButtonStyle(accent: .white.opacity(0.5)))
            }
        }.padding(.horizontal, 25).padding(.top, 20)
    }

    private func completionDetail(_ notice: TaskCompletionNotice) -> String {
        let tokens = notice.usageKnown ? notice.usageDisplayValue + " Token" : "计数未返回"
        if presentationAssistant == .chatGPT {
            return tokens + " · " + notice.secondaryMetricTitle + " " + notice.secondaryMetricValue
        }
        return notice.usageKnown ? tokens : "已收到明确完成事件"
    }
}

@MainActor
private enum AssistantIconCache {
    static var icons: [IslandAssistant: NSImage] = [:]
    static func icon(for assistant: IslandAssistant) -> NSImage? {
        if let cached = icons[assistant] { return cached }
        guard let url = assistant.bundleIdentifiers.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[assistant] = icon
        return icon
    }
}

private struct AssistantGlyph: View {
    let assistant: IslandAssistant
    let size: CGFloat
    var body: some View {
        Group {
            if let icon = AssistantIconCache.icon(for: assistant) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: assistant.symbolName).font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(Color(assistant.palette.accent)).frame(width: size, height: size)
                    .background(Color(assistant.palette.accent).opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.25))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
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
