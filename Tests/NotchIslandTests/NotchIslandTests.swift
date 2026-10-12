import Foundation
import NotchShared
import Testing
@testable import NotchIsland

/// socketpair 한쪽을 Responder에 주고, 다른 쪽에서 앱이 bridge에 보낸 응답을 읽는다.
private func makePair() -> (Responder, LineReader, Int32, Int32) {
    var fds: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    return (Responder(fd: fds[0]), LineReader(fd: fds[1]), fds[0], fds[1])
}

private func readJSON(_ reader: LineReader) -> [String: Any]? {
    guard let line = reader.readLine() else { return nil }
    return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

private func decision(_ json: [String: Any]?) -> [String: Any]? {
    ((json?["hookSpecificOutput"] as? [String: Any])?["decision"]) as? [String: Any]
}

private func permissionEvent(tool: String, input: [String: Any], suggestions: [Any]? = nil) -> [String: Any] {
    var event: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/proj",
        "tool_name": tool, "tool_input": input,
    ]
    if let suggestions { event["permission_suggestions"] = suggestions }
    return event
}

@Suite struct DecisionTests {
    let store = SessionStore(prefs: Prefs())

    @Test func allowWritesPermissionDecision() throws {
        let (responder, reader, a, b) = makePair()
        defer { close(a); close(b) }
        store.ingestPermission(permissionEvent(tool: "Bash", input: ["command": "ls"]), source: "claude", terminal: nil, id: UUID(), responder: responder)
        let request = try #require(store.pending.first)
        #expect(store.sessions["s1"]?.status == .waitingApproval)

        store.decide(request, .allow)
        let json = readJSON(reader)
        #expect((json?["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String == "PermissionRequest")
        #expect(decision(json)?["behavior"] as? String == "allow")
        #expect(store.pending.isEmpty)
        #expect(store.sessions["s1"]?.status == .running)
    }

    @Test func alwaysPassesSuggestions() throws {
        let (responder, reader, a, b) = makePair()
        defer { close(a); close(b) }
        let suggestion: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        store.ingestPermission(permissionEvent(tool: "Edit", input: ["file_path": "/a"], suggestions: [suggestion]),
                               source: "claude", terminal: nil, id: UUID(), responder: responder)
        store.decide(try #require(store.pending.first), .always)
        let updated = decision(readJSON(reader))?["updatedPermissions"] as? [[String: Any]]
        #expect(updated?.first?["mode"] as? String == "acceptEdits")
    }

    @Test func denyIncludesMessage() throws {
        let (responder, reader, a, b) = makePair()
        defer { close(a); close(b) }
        store.ingestPermission(permissionEvent(tool: "Bash", input: ["command": "rm -rf x"]), source: "claude", terminal: nil, id: UUID(), responder: responder)
        store.decide(try #require(store.pending.first), .deny)
        let body = decision(readJSON(reader))
        #expect(body?["behavior"] as? String == "deny")
        #expect((body?["message"] as? String)?.isEmpty == false)
    }

    @Test func questionAnswerKeepsOriginalInput() throws {
        let (responder, reader, a, b) = makePair()
        defer { close(a); close(b) }
        let questions: [[String: Any]] = [
            ["question": "어떤 DB?", "header": "DB", "multiSelect": false,
             "options": [["label": "Postgres", "description": "관계형"], ["label": "SQLite", "description": "파일"]]],
            ["question": "기능은?", "header": "기능", "multiSelect": true,
             "options": [["label": "로그인", "description": ""], ["label": "결제", "description": ""]]],
        ]
        store.ingestPermission(permissionEvent(tool: "AskUserQuestion", input: ["questions": questions]),
                               source: "claude", terminal: nil, id: UUID(), responder: responder)
        let request = try #require(store.pending.first)
        guard case .question(let parsed) = request.kind else { Issue.record("question으로 파싱 안 됨"); return }
        #expect(parsed.count == 2)
        #expect(parsed[1].multiSelect)
        #expect(parsed[0].options.map(\.label) == ["Postgres", "SQLite"])

        store.decide(request, .answer(["어떤 DB?": "SQLite", "기능은?": ["로그인", "결제"]]))
        let body = try #require(decision(readJSON(reader)))
        #expect(body["behavior"] as? String == "allow")
        let updated = try #require(body["updatedInput"] as? [String: Any])
        // 에이전트는 표시했던 필드가 바뀌면 거부하므로 questions는 원본 그대로여야 한다
        #expect((updated["questions"] as? [[String: Any]])?.count == 2)
        let answers = try #require(updated["answers"] as? [String: Any])
        #expect(answers["어떤 DB?"] as? String == "SQLite")
        #expect(answers["기능은?"] as? [String] == ["로그인", "결제"])
    }

    @Test func planRequestParsed() throws {
        let (responder, _, a, b) = makePair()
        defer { close(a); close(b) }
        store.ingestPermission(permissionEvent(tool: "ExitPlanMode", input: ["plan": "1. 읽기\n2. 고치기"]),
                               source: "claude", terminal: nil, id: UUID(), responder: responder)
        guard case .plan(let text) = store.pending.first?.kind else { Issue.record("plan 아님"); return }
        #expect(text.contains("고치기"))
    }

    @Test func terminalDecisionSendsNothing() throws {
        let (responder, reader, a, b) = makePair()
        defer { close(a); close(b) }
        store.ingestPermission(permissionEvent(tool: "Bash", input: ["command": "ls"]), source: "claude", terminal: nil, id: UUID(), responder: responder)
        store.decide(try #require(store.pending.first), .terminal)
        #expect(reader.readLine() == nil)  // 응답 없이 EOF → bridge 무출력 → 터미널 프롬프트
        #expect(store.pending.isEmpty)
    }

    @Test func connectionClosedRemovesCard() throws {
        let (responder, _, a, b) = makePair()
        defer { close(a); close(b) }
        let id = UUID()
        store.ingestPermission(permissionEvent(tool: "Bash", input: ["command": "ls"]), source: "claude", terminal: nil, id: id, responder: responder)
        store.permissionConnectionClosed(id)
        #expect(store.pending.isEmpty)
        #expect(store.sessions["s1"]?.status == .running)
    }
}

@Suite struct EventTests {
    let store = SessionStore(prefs: Prefs())

    @Test func lifecycleUpdatesStatus() {
        let terminal: [String: Any] = ["tty": "/dev/ttys009", "TERM_PROGRAM": "iTerm.app", "TMUX_PANE": "%3"]
        store.ingest(["hook_event_name": "SessionStart", "session_id": "x", "cwd": "/w/app", "source": "startup"], source: "claude", terminal: terminal)
        #expect(store.sessions["x"]?.projectName == "app")
        #expect(store.sessions["x"]?.terminal.hostBundleID == "com.googlecode.iterm2")
        #expect(store.sessions["x"]?.terminal.tmuxPane == "%3")

        store.ingest(["hook_event_name": "UserPromptSubmit", "session_id": "x", "prompt": "고쳐줘"], source: "claude", terminal: nil)
        #expect(store.sessions["x"]?.status == .running)
        // 터미널 정보 없는 이벤트가 와도 기존 정보 유지
        #expect(store.sessions["x"]?.terminal.tty == "/dev/ttys009")

        store.ingest(["hook_event_name": "SubagentStart", "session_id": "x"], source: "claude", terminal: nil)
        #expect(store.sessions["x"]?.subagents == 1)

        store.ingest(["hook_event_name": "Stop", "session_id": "x"], source: "claude", terminal: nil)
        #expect(store.sessions["x"]?.status == .done)
        #expect(store.sessions["x"]?.subagents == 0)

        store.ingest(["hook_event_name": "SessionEnd", "session_id": "x"], source: "claude", terminal: nil)
        #expect(store.sessions["x"] == nil)
    }

    @Test func statusLineSetsModelContextAndLimits() {
        store.ingest([
            "hook_event_name": "StatusLine", "session_id": "y",
            "model": ["display_name": "Opus 5.5"],
            "context_window": ["used_percentage": 42],
            "rate_limits": ["five_hour": ["used_percentage": 12, "resets_at": 1_791_788_400],
                            "seven_day": ["used_percentage": 55, "resets_at": 1_792_148_400]],
        ], source: "claude", terminal: nil)
        #expect(store.sessions["y"]?.model == "Opus 5.5")
        #expect(store.sessions["y"]?.contextPercent == 42)
        #expect(store.rateLimits?.fiveHour?.usedPercent == 12)
        #expect(store.rateLimits?.sevenDay?.usedPercent == 55)
    }

    @Test func idleNotificationAndFailure() {
        store.ingest(["hook_event_name": "Notification", "session_id": "z", "notification_type": "idle_prompt", "message": "기다리는 중"], source: "claude", terminal: nil)
        #expect(store.sessions["z"]?.status == .waitingInput)
        store.ingest(["hook_event_name": "StopFailure", "session_id": "z", "error": "rate_limit"], source: "claude", terminal: nil)
        #expect(store.sessions["z"]?.status == .error)
        #expect(store.peek?.kind == .error)
    }
}

@Suite(.serialized) struct IntegrationTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("notch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        NotchPaths.homeOverride = home
    }

    private func settings() throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func installKeepsOtherSettingsAndRemovesOnlyOurs() throws {
        let original: [String: Any] = [
            "model": "opus",
            "statusLine": ["type": "command", "command": "my-status.sh"],
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-guard.sh"]]]],
                      "Stop": [["hooks": [["type": "command", "command": "/x/vibe-island-bridge --source claude"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: home.appendingPathComponent(".claude/settings.json"))

        try Integrations.install(.claude)
        try Integrations.install(.claude)  // 두 번 설치해도 중복 없음
        var current = try settings()
        #expect(current["model"] as? String == "opus")
        let hooks = try #require(current["hooks"] as? [String: Any])
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2)  // 기존 my-guard + 우리 것
        let permission = try #require((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(permission.first?["timeout"] as? Int == 86400)
        #expect(Integrations.isInstalled(.claude))
        #expect(Integrations.hasVibeIslandHooks(.claude))

        try Integrations.removeVibeIslandHooks(.claude)
        #expect(!Integrations.hasVibeIslandHooks(.claude))
        #expect(Integrations.isInstalled(.claude))

        try Integrations.uninstall(.claude)
        current = try settings()
        #expect(!Integrations.isInstalled(.claude))
        let remaining = try #require((current["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(remaining.count == 1)
        #expect(((remaining[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "my-guard.sh")

        // 백업이 남아야 한다
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path)
            .filter { $0.contains("notch-backup") }
        #expect(!backups.isEmpty)
    }

    @Test func statusLineInstallPreservesPrevious() throws {
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "my-status.sh"]]
        try JSONSerialization.data(withJSONObject: original).write(to: home.appendingPathComponent(".claude/settings.json"))

        try Integrations.installStatusLine()
        #expect(Integrations.isStatusLineInstalled)
        #expect(try String(contentsOf: NotchPaths.previousStatusLine, encoding: .utf8) == "my-status.sh")

        try Integrations.uninstallStatusLine()
        let restored = (try settings()["statusLine"] as? [String: Any])?["command"] as? String
        #expect(restored == "my-status.sh")
    }
}

@Suite struct PrefsTests {
    @Test func quietHoursCrossMidnight() {
        let prefs = Prefs()
        prefs.quietHoursEnabled = true
        prefs.quietStart = 23 * 60
        prefs.quietEnd = 8 * 60
        let calendar = Calendar.current
        let at = { (h: Int) in calendar.date(bySettingHour: h, minute: 0, second: 0, of: Date())! }
        #expect(prefs.inQuietHours(at(23)))
        #expect(prefs.inQuietHours(at(3)))
        #expect(!prefs.inQuietHours(at(12)))
        prefs.quietHoursEnabled = false
    }

    @Test func shortcutRoundTrip() throws {
        let shortcut = HotkeyAction.switcher.defaultShortcut
        let decoded = try #require(Shortcut(encoded: shortcut.encoded))
        #expect(decoded == shortcut)
        #expect(decoded.display == "⌥⌘I")
    }
}
