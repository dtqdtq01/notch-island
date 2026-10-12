import AppKit
import SwiftUI
import Testing
@testable import NotchIsland

/// NOTCH_RENDER_DIR=<폴더> 일 때만 노치 상태별 PNG를 그린다 (화면 캡처 권한 없이 모양 확인용)
@Suite struct RenderPreviewTests {
    @MainActor @Test func renderStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] else { return }
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts").standardized
        NotchFonts.register(extraDirectory: fonts)

        let prefs = Prefs()
        prefs.detailedLayout = true
        let store = SessionStore(prefs: prefs)
        let ghostty: [String: Any] = ["tty": "/dev/ttys001", "TERM_PROGRAM": "ghostty"]
        func event(_ e: [String: Any], _ source: String = "claude", _ terminal: [String: Any]? = nil) {
            store.ingest(e, source: source, terminal: terminal)
        }
        event(["hook_event_name": "UserPromptSubmit", "session_id": "inbox", "cwd": "/w/inbox", "prompt": "Run test workflow now"], "codex", ghostty)
        event(["hook_event_name": "Stop", "session_id": "inbox", "last_assistant_message": "Test received."], "codex")
        event(["hook_event_name": "UserPromptSubmit", "session_id": "love", "cwd": "/w/vibe-island", "prompt": "Add \"Made with love\" to the end of CLAUDE.md"], "claude", ghostty)
        event(["hook_event_name": "Stop", "session_id": "love", "last_assistant_message": "Edward, I need to push back on this."])
        event(["hook_event_name": "UserPromptSubmit", "session_id": "demo", "cwd": "/w/vibe-island", "prompt": "hi demo day!"], "claude", ghostty)
        event(["hook_event_name": "UserPromptSubmit", "session_id": "demo", "prompt": "Create a file called hello.txt with \"Hello from Vibe Island\""])
        event(["hook_event_name": "PreToolUse", "session_id": "demo", "tool_name": "Write", "tool_input": ["file_path": "/w/hello.txt"]])

        store.markSeen("inbox")  // 읽은 완료 세션은 흐리게
        let model = NotchViewModel()
        let g = model.geometry
        func render(_ name: String, mode: NotchMode, width: CGFloat, height: CGFloat) throws {
            model.mode = mode
            model.size = CGSize(width: width, height: height)
            let view = NotchRootView(store: store, model: model, prefs: prefs,
                                     onJump: { _ in }, onToggle: {}, onSilence: { _, _ in }, onSettings: {})
                .frame(width: 760, height: height + 40)
                .background(LinearGradient(colors: [Color(red: 0.98, green: 0.72, blue: 0.5), Color(red: 0.95, green: 0.55, blue: 0.4)],
                                           startPoint: .top, endPoint: .bottom))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let side = Metrics.sideWidth(detailed: true) * 2
        try render("v1-collapsed-working", mode: .collapsed, width: g.notchWidth + side, height: g.notchHeight)
        try render("v2-list", mode: .expanded, width: 620, height: 330)

        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[0]); close(fds[1]) }
        store.ingestPermission(["hook_event_name": "PermissionRequest", "session_id": "demo", "cwd": "/w/vibe-island", "tool_name": "Write",
                                "tool_input": ["file_path": "/w/hello.txt", "content": "Hello from Vibe Island\n"]],
                               source: "claude", terminal: nil, id: UUID(), responder: Responder(fd: fds[0]))
        try render("v3-collapsed-question", mode: .collapsed, width: g.notchWidth + side, height: g.notchHeight)
        try render("v4-approval", mode: .expanded, width: 620, height: 360)
        store.decide(store.pending.first!, .allow)
        event(["hook_event_name": "Stop", "session_id": "demo", "last_assistant_message": "Done. hello.txt created at the project root."])
        try render("v5-done", mode: .peek, width: 620, height: 250)
    }
}
