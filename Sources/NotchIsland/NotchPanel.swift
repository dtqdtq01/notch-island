import AppKit
import Combine
import SwiftUI

/// 노치 크기 정보. 노치 없는 화면에서는 메뉴바 높이의 가짜 노치를 쓴다.
struct NotchGeometry {
    var screen: NSScreen
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    static func current() -> NotchGeometry {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        let screen = notched ?? NSScreen.main ?? screens[0]
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return NotchGeometry(
                screen: screen,
                notchWidth: screen.frame.width - left.width - right.width,
                notchHeight: screen.safeAreaInsets.top,
                hasNotch: true)
        }
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(screen: screen, notchWidth: 180, notchHeight: menuBar, hasNotch: false)
    }
}

enum NotchMode { case collapsed, peek, expanded }

/// 뷰와 컨트롤러가 같이 쓰는 크기 값
enum Metrics {
    static let sideWidth: CGFloat = 40
    /// "자세히" 레이아웃에서 접힌 노치 양옆 폭
    static let detailedSideWidth: CGFloat = 120
    static func sideWidth(detailed: Bool) -> CGFloat { detailed ? detailedSideWidth : sideWidth }
    static let expandedWidth: CGFloat = 540
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 48
    static let maxRows = 6
    static let peekHeight: CGFloat = 76
    /// 메뉴바와 이어지는 위쪽 오목한 모서리
    static func topRadius(_ mode: NotchMode) -> CGFloat { mode == .collapsed ? 6 : 14 }
    static func bottomRadius(_ mode: NotchMode) -> CGFloat {
        switch mode {
        case .collapsed: return 10
        case .peek: return 22
        case .expanded: return 26
        }
    }
    /// 그림자가 잘리지 않도록 창에 두는 여백
    static let shadowMargin: CGFloat = 40

    static func cardHeight(_ request: PendingRequest) -> CGFloat {
        switch request.kind {
        case .permission: return 270
        case .question(let questions):
            let options = questions.first?.options.count ?? 0
            return min(220 + CGFloat(options) * 34, 420)
        case .plan: return 372
        }
    }
}

final class NotchViewModel: ObservableObject {
    @Published var mode: NotchMode = .collapsed
    /// 노치 몸통의 목표 크기 (위쪽 귀 제외). 뷰가 스프링으로 따라간다.
    @Published var size: CGSize = .zero
    @Published var hovering = false
    @Published var pinned = false
    @Published var switcherIndex: Int?
    @Published var geometry = NotchGeometry.current()
}

final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 첫 클릭도 바로 버튼에 전달하는 호스팅 뷰
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanelController {
    private let panel = NotchPanel()
    private let store: SessionStore
    private let prefs: Prefs
    private let quiet: QuietMonitor
    let model = NotchViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var lastFrame: NSRect = .zero
    private var mouseMonitors: [Any] = []
    private var mouseInside = false
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var frontIsFullscreen = false
    private var appBeforeSwitcher: NSRunningApplication?

    init(store: SessionStore, prefs: Prefs, quiet: QuietMonitor, openSettings: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.quiet = quiet
        let root = NotchRootView(
            store: store, model: model, prefs: prefs,
            onJump: { [weak self] session in self?.jump(session) },
            onToggle: { [weak self] in self?.togglePinned() },
            onSilence: { [weak store] session, kind in
                switch kind {
                case .directory: store?.addSilenceRule(directory: session.cwd)
                case .prompt: store?.addSilenceRule(promptPrefix: session.firstPrompt.map { String($0.prefix(40)) })
                case .dismiss: store?.dismiss(session.id)
                }
            },
            onSettings: openSettings)
        let host = FirstMouseHostingView(rootView: root)
        // 창 크기는 직접 관리한다 — SwiftUI가 매 업데이트마다 창 최소/최대 크기를 계산하지 않게
        host.sizingOptions = []
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        // 창은 크게 고정하고, 노치 밖 투명한 곳은 클릭이 아래(메뉴바 등)로 통과하게 한다
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        installMouseTracking()

        store.objectWillChange
            .merge(with: model.objectWillChange, prefs.objectWillChange, quiet.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.layout() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.model.geometry = NotchGeometry.current()
                self?.lastFrame = .zero
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.checkFullscreen() }
            .store(in: &cancellables)

        // 바깥을 클릭하면 고정 펼침 해제
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self, self.model.pinned || self.model.switcherIndex != nil else { return }
            self.model.pinned = false
            self.closeSwitcher()
        }

        layout()
        panel.orderFrontRegardless()
    }

    // MARK: - 외부 동작

    func jump(_ session: Session) {
        closeSwitcher()
        model.pinned = false
        TerminalJumper.jump(session)
    }

    func togglePinned() {
        model.pinned.toggle()
    }

    /// 단축키: 열려 있으면 다음 세션으로, 아니면 스위처 열기
    func switcherHotkey() {
        let count = store.sortedSessions.count
        guard count > 0 else { return }
        if let index = model.switcherIndex {
            model.switcherIndex = (index + 1) % count
            return
        }
        model.switcherIndex = 0
        appBeforeSwitcher = NSWorkspace.shared.frontmostApplication
        panel.makeKey()
        installKeyMonitor()
    }

    // MARK: - 스위처 키보드

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let index = self.model.switcherIndex else { return event }
            let sessions = self.store.sortedSessions
            guard !sessions.isEmpty else { self.closeSwitcher(); return nil }
            let backwards = event.modifierFlags.contains(.shift)
            switch Int(event.keyCode) {
            case 125:  // ↓
                self.model.switcherIndex = (index + 1) % sessions.count
            case 126:  // ↑
                self.model.switcherIndex = (index - 1 + sessions.count) % sessions.count
            case 48:  // Tab / ⇧Tab
                let step = backwards ? sessions.count - 1 : 1
                self.model.switcherIndex = (index + step) % sessions.count
            case 36, 76:  // Return, Enter
                let target = sessions[min(index, sessions.count - 1)]
                self.jump(target)
            case 53:  // Esc
                self.closeSwitcher()
            default:
                if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit), digit <= sessions.count {
                    self.jump(sessions[digit - 1])
                }
            }
            return nil
        }
    }

    private func closeSwitcher() {
        guard model.switcherIndex != nil else { return }
        model.switcherIndex = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // 키보드 포커스를 원래 앱에 돌려준다
        appBeforeSwitcher?.activate()
        appBeforeSwitcher = nil
    }

    // MARK: - 마우스 추적

    private func installMouseTracking() {
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] _ in self?.trackMouse() }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] event in
            self?.trackMouse()
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    /// 지금 보이는 노치 영역 (화면 좌표)
    private var visibleRect: NSRect {
        let screen = model.geometry.screen.frame
        let width = model.size.width + Metrics.topRadius(model.mode) * 2
        return NSRect(x: screen.midX - width / 2, y: screen.maxY - model.size.height, width: width, height: model.size.height)
    }

    private func trackMouse() {
        let inside = visibleRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != mouseInside else { return }
        mouseInside = inside
        hoverChanged(inside)
    }

    private func hoverChanged(_ inside: Bool) {
        hoverWork?.cancel()
        // 스쳐 지나갈 때 튀어나오지 않도록 펼침은 짧게 기다리고, 접힘은 조금 더 여유를 둔다
        let delay = inside ? 0.08 : 0.32
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if inside {
                if self.prefs.expandOnHover { self.model.hovering = true }
            } else {
                self.model.hovering = false
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 레이아웃

    private func desiredMode() -> NotchMode {
        if model.switcherIndex != nil || model.pinned || model.hovering { return .expanded }
        // 화면 공유·집중 모드 중에는 스스로 튀어나오지 않는다 (접힌 노치의 개수 표시는 유지)
        if quiet.isQuiet { return .collapsed }
        if !store.pending.isEmpty && prefs.autoExpandOnRequest { return .expanded }
        if store.peek != nil { return .peek }
        return .collapsed
    }

    private func layout() {
        let mode = desiredMode()
        let size: CGSize
        switch mode {
        case .collapsed: size = collapsedSize()
        case .peek: size = CGSize(width: Metrics.expandedWidth - 80, height: model.geometry.notchHeight + Metrics.peekHeight)
        case .expanded: size = expandedSize()
        }
        // 모드와 크기를 같은 트랜잭션에서 바꿔야 스프링이 한 번에 움직인다
        if model.mode != mode || model.size != size {
            withAnimation(NotchMotion.spring) {
                model.mode = mode
                model.size = size
            }
        }
        placePanel()
        updateVisibility(mode: mode)
        trackMouse()
    }

    /// 창은 펼쳤을 때의 최대 크기로 고정 — 노치 모양만 안에서 애니메이션된다
    private func placePanel() {
        let g = model.geometry
        let screen = g.screen.frame
        let width = max(Metrics.expandedWidth, g.notchWidth + 140) + Metrics.topRadius(.expanded) * 2 + Metrics.shadowMargin * 2
        let height = screen.height * 0.8 + Metrics.shadowMargin
        let frame = NSRect(x: (screen.midX - width / 2).rounded(), y: screen.maxY - height, width: width, height: height)
        if frame != lastFrame {
            lastFrame = frame
            panel.setFrame(frame, display: true)
        }
    }

    private func updateVisibility(mode: NotchMode) {
        var hidden = false
        if mode == .collapsed {
            if prefs.hideInFullscreen && frontIsFullscreen { hidden = true }
            if prefs.autoHideWhenIdle && store.sessions.isEmpty { hidden = true }
        }
        if hidden, panel.isVisible { panel.orderOut(nil) }
        if !hidden, !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func collapsedSize() -> CGSize {
        let g = model.geometry
        let sides: CGFloat = store.sessions.isEmpty ? 0 : Metrics.sideWidth(detailed: prefs.detailedLayout) * 2
        return CGSize(width: g.notchWidth + sides, height: g.notchHeight)
    }

    private func expandedSize() -> CGSize {
        let g = model.geometry
        var height = g.notchHeight + 6 + Metrics.headerHeight
        if let request = store.pending.first { height += Metrics.cardHeight(request) + 8 }
        let rows = min(store.sessions.count, Metrics.maxRows)
        height += rows == 0 ? 44 : CGFloat(rows) * Metrics.rowHeight
        height += 14
        let maxHeight = g.screen.frame.height * 0.8
        return CGSize(width: max(Metrics.expandedWidth, g.notchWidth + 140), height: min(height, maxHeight))
    }

    // MARK: - 전체화면 감지

    private func checkFullscreen() {
        frontIsFullscreen = Self.frontmostIsFullscreen(on: model.geometry.screen)
        layout()
    }

    private static func frontmostIsFullscreen(on screen: NSScreen) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let size = screen.frame.size
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return bounds["Width"] == size.width && bounds["Height"] == size.height
        }
    }
}
