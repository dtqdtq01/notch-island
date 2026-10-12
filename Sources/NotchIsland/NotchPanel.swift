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
    static let expandedWidth: CGFloat = 540
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 48
    static let maxRows = 6
    static let peekHeight: CGFloat = 76

    static func cardHeight(_ request: PendingRequest) -> CGFloat {
        switch request.kind {
        case .permission: return 270
        case .question(let questions):
            let options = questions.first?.options.count ?? 0
            return min(220 + CGFloat(options) * 34, 420)
        case .plan: return 340
        }
    }
}

final class NotchViewModel: ObservableObject {
    @Published var mode: NotchMode = .collapsed
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

/// 첫 클릭도 바로 버튼에 전달하고, 창이 key가 아니어도 hover를 감지하는 호스팅 뷰.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

final class NotchPanelController {
    private let panel = NotchPanel()
    private let store: SessionStore
    private let prefs: Prefs
    let model = NotchViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var collapseWork: DispatchWorkItem?
    private var lastFrame: NSRect = .zero
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var frontIsFullscreen = false
    private var appBeforeSwitcher: NSRunningApplication?

    init(store: SessionStore, prefs: Prefs, openSettings: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        let root = NotchRootView(
            store: store, model: model, prefs: prefs,
            onJump: { [weak self] session in self?.jump(session) },
            onToggle: { [weak self] in self?.togglePinned() },
            onSettings: openSettings)
        let host = HoverHostingView(rootView: root)
        host.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host

        store.objectWillChange
            .merge(with: model.objectWillChange, prefs.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.layout() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.model.geometry = NotchGeometry.current() }
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

    // MARK: - 레이아웃

    private func hoverChanged(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            if prefs.expandOnHover { model.hovering = true }
        } else {
            // 패널이 줄어들며 생기는 깜빡임 방지용 짧은 유예
            let work = DispatchWorkItem { [weak self] in self?.model.hovering = false }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func desiredMode() -> NotchMode {
        if model.switcherIndex != nil || model.pinned || model.hovering { return .expanded }
        if !store.pending.isEmpty && prefs.autoExpandOnRequest { return .expanded }
        if store.peek != nil { return .peek }
        return .collapsed
    }

    private func layout() {
        let mode = desiredMode()
        if model.mode != mode { model.mode = mode }

        let size: CGSize
        switch mode {
        case .collapsed: size = collapsedSize()
        case .peek: size = CGSize(width: Metrics.expandedWidth - 80, height: model.geometry.notchHeight + Metrics.peekHeight)
        case .expanded: size = expandedSize()
        }
        let screenFrame = model.geometry.screen.frame
        let frame = NSRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: screenFrame.maxY - size.height,
            width: size.width, height: size.height)
        if frame != lastFrame {
            lastFrame = frame
            panel.setFrame(frame, display: true)
        }
        updateVisibility(mode: mode)
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
        let sides: CGFloat = store.sessions.isEmpty ? 0 : Metrics.sideWidth * 2
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
