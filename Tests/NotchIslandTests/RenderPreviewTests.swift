import AppKit
import SwiftUI
import Testing
@testable import NotchIsland

/// NOTCH_RENDER_DIR=<폴더> 일 때만 노치 상태별 PNG를 그린다 (화면 캡처 권한 없이 모양 확인용)
@Suite struct RenderPreviewTests {
    @MainActor @Test func renderStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] else { return }
        let prefs = Prefs()
        let store = SessionStore(prefs: prefs)
        let tty: [String: Any] = ["tty": "/dev/ttys001", "TERM_PROGRAM": "iTerm.app"]
        store.ingest(["hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/w/notch-island", "prompt": "애니메이션 다듬어줘"], source: "claude", terminal: tty)
        store.ingest(["hook_event_name": "PreToolUse", "session_id": "a", "tool_name": "Edit", "tool_input": ["file_path": "/w/NotchViews.swift"]], source: "claude", terminal: nil)
        store.ingest(["hook_event_name": "Stop", "session_id": "b", "cwd": "/w/dino-passport"], source: "claude", terminal: tty)
        store.ingest(["hook_event_name": "UserPromptSubmit", "session_id": "c", "cwd": "/w/api-server", "prompt": "테스트 돌려줘"], source: "codex", terminal: tty)

        let model = NotchViewModel()
        let g = model.geometry
        func render(_ name: String, mode: NotchMode, size: CGSize) throws {
            model.mode = mode
            model.size = size
            let view = NotchRootView(store: store, model: model, prefs: prefs,
                                     onJump: { _ in }, onToggle: {}, onSilence: { _, _ in }, onSettings: {})
                .frame(width: 700, height: size.height + 40)
                .background(Color(white: 0.75))  // 메뉴바 대신 회색 배경
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        try render("1-collapsed", mode: .collapsed, size: CGSize(width: g.notchWidth + 80, height: g.notchHeight))
        try render("2-expanded", mode: .expanded, size: CGSize(width: 540, height: g.notchHeight + 6 + 28 + 3 * 48 + 14))

        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[0]); close(fds[1]) }
        store.ingestPermission(["hook_event_name": "PermissionRequest", "session_id": "a", "cwd": "/w/notch-island", "tool_name": "Edit",
                                "tool_input": ["file_path": "/w/NotchViews.swift", "old_string": "let spring = 0.3", "new_string": "let spring = 0.42\nlet damping = 0.8"],
                                "permission_suggestions": [["type": "setMode", "mode": "acceptEdits"]]],
                               source: "claude", terminal: nil, id: UUID(), responder: Responder(fd: fds[0]))
        try render("3-approval", mode: .expanded, size: CGSize(width: 540, height: g.notchHeight + 6 + 28 + 270 + 8 + 3 * 48 + 14))
        store.notify("훅을 복구했어요", "Claude Code 설정을 다른 도구가 바꿨어요")
        try render("4-peek", mode: .peek, size: CGSize(width: 460, height: g.notchHeight + 76))
    }
}
