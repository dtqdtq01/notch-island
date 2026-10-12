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

final class NotchViewModel: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var geometry = NotchGeometry.current()

    static let sideWidth: CGFloat = 40
    static let expandedWidth: CGFloat = 500
    static let approvalHeight: CGFloat = 262
    static let rowHeight: CGFloat = 46
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
    private let model = NotchViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var collapseWork: DispatchWorkItem?
    private var lastFrame: NSRect = .zero

    init(store: SessionStore) {
        self.store = store
        let host = HoverHostingView(rootView: NotchRootView(store: store, model: model))
        host.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host

        store.objectWillChange
            .merge(with: model.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.layout() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.model.geometry = NotchGeometry.current()
            }
            .store(in: &cancellables)

        layout()
        panel.orderFrontRegardless()
    }

    private func hoverChanged(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            model.hovering = true
        } else {
            // 패널이 줄어들며 생기는 깜빡임 방지용 짧은 유예
            let work = DispatchWorkItem { [weak self] in self?.model.hovering = false }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func layout() {
        let wantExpanded = model.hovering || !store.pending.isEmpty
        if model.expanded != wantExpanded { model.expanded = wantExpanded }

        let size = wantExpanded ? expandedSize() : collapsedSize()
        let screenFrame = model.geometry.screen.frame
        let frame = NSRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: screenFrame.maxY - size.height,
            width: size.width, height: size.height)
        if frame != lastFrame {
            lastFrame = frame
            panel.setFrame(frame, display: true)
        }
    }

    private func collapsedSize() -> CGSize {
        let g = model.geometry
        let sides: CGFloat = store.sessions.isEmpty ? 0 : NotchViewModel.sideWidth * 2
        return CGSize(width: g.notchWidth + sides, height: g.notchHeight)
    }

    private func expandedSize() -> CGSize {
        let g = model.geometry
        var height = g.notchHeight + 8
        if !store.pending.isEmpty { height += NotchViewModel.approvalHeight }
        let rows = min(store.sessions.count, 5)
        height += rows == 0 ? 52 : CGFloat(rows) * NotchViewModel.rowHeight + 12
        return CGSize(width: max(NotchViewModel.expandedWidth, g.notchWidth + 120), height: min(height, 600))
    }
}
