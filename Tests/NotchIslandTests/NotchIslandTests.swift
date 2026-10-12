import Foundation
import NotchShared
import Testing
@testable import NotchIsland

/// socketpair 한쪽을 Responder에 주고, 다른 쪽에서 앱이 bridge에 보낸 응답을 읽는다.
/// 테스트가 영원히 멈추지 않도록 읽기 타임아웃 2초
private func setReadTimeout(_ fd: Int32) {
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

private func makePair() -> (Responder, LineReader, Int32, Int32) {
    var fds: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    setReadTimeout(fds[1])
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

@Suite(.serialized) struct SilenceTests {
    private func makePrefs() -> Prefs {
        let prefs = Prefs()
        prefs.blockedLaunchers = Prefs.defaultBlockedLaunchers
        prefs.silencedDirectories = []
        prefs.silencedPromptPrefixes = []
        prefs.silencedPromptContains = []
        prefs.hideSessionsWithoutTTY = false
        return prefs
    }

    @Test func blockedLauncherSessionNeverAppears() throws {
        let store = SessionStore(prefs: makePrefs())
        let terminal: [String: Any] = ["ancestor_bundles": ["com.steipete.codexbar"], "agent_pid": 99999]
        store.ingest(["hook_event_name": "SessionStart", "session_id": "bg", "cwd": "/tmp"], source: "claude", terminal: terminal)
        #expect(store.sessions["bg"] == nil)
        #expect(store.silenced.contains("bg"))

        // 같은 세션의 권한 요청은 응답 없이 닫혀서 터미널 프롬프트로 간다
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        setReadTimeout(fds[1])
        defer { close(fds[0]); close(fds[1]) }
        store.ingestPermission(["hook_event_name": "PermissionRequest", "session_id": "bg", "tool_name": "Bash", "tool_input": ["command": "ls"]],
                               source: "claude", terminal: nil, id: UUID(), responder: Responder(fd: fds[0]))
        #expect(store.pending.isEmpty)
        #expect(LineReader(fd: fds[1]).readLine() == nil)

        store.ingest(["hook_event_name": "SessionEnd", "session_id": "bg"], source: "claude", terminal: nil)
        #expect(!store.silenced.contains("bg"))
    }

    @Test func directoryAndPromptRules() {
        let prefs = makePrefs()
        let store = SessionStore(prefs: prefs)
        store.ingest(["hook_event_name": "SessionStart", "session_id": "a", "cwd": "/work/experiments/x"], source: "claude", terminal: nil)
        store.ingest(["hook_event_name": "SessionStart", "session_id": "b", "cwd": "/work/app"], source: "claude", terminal: nil)
        #expect(store.sessions.count == 2)

        store.addSilenceRule(directory: "/experiments")
        #expect(store.sessions["a"] == nil)
        #expect(store.sessions["b"] != nil)

        prefs.silencedPromptPrefixes = ["Generate a title"]
        store.ingest(["hook_event_name": "UserPromptSubmit", "session_id": "b", "prompt": "Generate a title for this chat"], source: "claude", terminal: nil)
        #expect(store.sessions["b"] == nil)

        // 두 번째 프롬프트는 규칙 대상이 아니다 (첫 프롬프트만)
        store.ingest(["hook_event_name": "UserPromptSubmit", "session_id": "c", "cwd": "/work/c", "prompt": "버그 고쳐줘"], source: "claude", terminal: nil)
        store.ingest(["hook_event_name": "UserPromptSubmit", "session_id": "c", "prompt": "Generate a title"], source: "claude", terminal: nil)
        #expect(store.sessions["c"] != nil)
    }

    @Test func noTTYRuleOnlyWhenEnabled() {
        let prefs = makePrefs()
        let store = SessionStore(prefs: prefs)
        let headless: [String: Any] = ["agent_pid": 4242]
        store.ingest(["hook_event_name": "SessionStart", "session_id": "h1", "cwd": "/w"], source: "claude", terminal: headless)
        #expect(store.sessions["h1"] != nil)
        prefs.hideSessionsWithoutTTY = true
        store.ingest(["hook_event_name": "SessionStart", "session_id": "h2", "cwd": "/w"], source: "claude", terminal: headless)
        #expect(store.sessions["h2"] == nil)
    }

    @Test func deadAgentProcessIsReaped() {
        let store = SessionStore(prefs: makePrefs())
        // 살아 있는 프로세스(자기 자신)와 존재하지 않는 pid
        store.ingest(["hook_event_name": "SessionStart", "session_id": "alive", "cwd": "/w"], source: "claude",
                     terminal: ["agent_pid": Int(getpid()), "tty": "/dev/ttys001"])
        store.ingest(["hook_event_name": "SessionStart", "session_id": "dead", "cwd": "/w"], source: "claude",
                     terminal: ["agent_pid": 99_998, "tty": "/dev/ttys002"])
        store.reapDeadSessions()
        #expect(store.sessions["alive"] != nil)
        #expect(store.sessions["dead"] == nil)
    }

    @Test func quietSuppressesPeek() {
        let store = SessionStore(prefs: makePrefs())
        store.isQuiet = { true }
        store.ingest(["hook_event_name": "StopFailure", "session_id": "q", "error": "x"], source: "claude", terminal: nil)
        #expect(store.peek == nil)
        store.isQuiet = { false }
        store.notify("안내")
        #expect(store.peek?.kind == .info)
    }
}

extension IntegrationTests {
    @Test func restoresRemovedHooks() throws {
        NotchPaths.homeOverride = home
        let prefs = Prefs()
        prefs.autoRepairHooks = true
        prefs.managedIntegrations = ["claude"]
        let store = SessionStore(prefs: prefs)
        let watcher = HookWatcher(prefs: prefs, store: store)

        try Integrations.install(.claude)
        // 다른 도구가 settings.json을 통째로 덮어씀
        try Data(#"{"model":"opus"}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        #expect(!Integrations.isInstalled(.claude))

        watcher.check()
        #expect(Integrations.isInstalled(.claude))
        #expect(store.peek?.title == "훅을 복구했어요")

        // 10분 안에 계속 지워지면 포기
        for _ in 0..<4 {
            try Data(#"{"model":"opus"}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
            watcher.check()
        }
        #expect(store.peek?.title == "훅이 계속 지워지고 있어요")
        try Data(#"{"model":"opus"}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        watcher.check()
        #expect(!Integrations.isInstalled(.claude))
        prefs.managedIntegrations = []
    }
}

@Suite struct DailyFeatureTests {
    let store = SessionStore(prefs: Prefs())

    private func planRequest() -> (PendingRequest, LineReader, Int32, Int32) {
        let (responder, reader, a, b) = makePair()
        store.ingestPermission(permissionEvent(tool: "ExitPlanMode", input: ["plan": "1. 고치기"]),
                               source: "claude", terminal: nil, id: UUID(), responder: responder)
        return (store.pending.first!, reader, a, b)
    }

    @Test func approvePlanSetsMode() {
        let (request, reader, a, b) = planRequest()
        defer { close(a); close(b) }
        store.decide(request, .approvePlan(mode: "acceptEdits"))
        let body = decision(readJSON(reader))
        #expect(body?["behavior"] as? String == "allow")
        let update = (body?["updatedPermissions"] as? [[String: Any]])?.first
        #expect(update?["type"] as? String == "setMode")
        #expect(update?["mode"] as? String == "acceptEdits")
        #expect(update?["destination"] as? String == "session")
    }

    @Test func approvePlanDefaultKeepsMode() {
        let (request, reader, a, b) = planRequest()
        defer { close(a); close(b) }
        store.decide(request, .approvePlan(mode: nil))
        #expect(decision(readJSON(reader))?["updatedPermissions"] == nil)
    }

    @Test func feedbackIsSentAsDenyMessage() {
        let (request, reader, a, b) = planRequest()
        defer { close(a); close(b) }
        store.decide(request, .denyWithMessage("계획 수정 요청: 테스트부터"))
        let body = decision(readJSON(reader))
        #expect(body?["behavior"] as? String == "deny")
        #expect(body?["message"] as? String == "계획 수정 요청: 테스트부터")
    }

    @Test func draftSurvivesUntilRequestEnds() {
        let (request, _, a, b) = planRequest()
        defer { close(a); close(b) }
        let draft = store.draft(for: request)
        draft.feedback = "쓰던 내용"
        draft.step = 1
        // 노치가 접혔다 펼쳐지면 같은 초안을 다시 받는다
        #expect(store.draft(for: request) === draft)
        #expect(store.draft(for: request).feedback == "쓰던 내용")
        store.decide(request, .approvePlan(mode: nil))
        #expect(store.draft(for: request) !== draft)  // 끝난 요청의 초안은 버려짐
    }

    @Test func parsesUsageAPIResponse() throws {
        let json = #"{"five_hour":{"utilization":3,"resets_at":"2026-10-12T07:00:00.429331+00:00","used_dollars":null},"seven_day":{"utilization":11.5,"resets_at":"2026-10-16T11:00:00.429351+00:00"},"seven_day_opus":null}"#
        let limits = try #require(ClaudeUsageFetcher.parse(Data(json.utf8)))
        #expect(limits.fiveHour?.usedPercent == 3)
        #expect(limits.sevenDay?.usedPercent == 11.5)
        let reset = try #require(limits.fiveHour?.resetsAt)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: reset).hour == 7)
        #expect(ClaudeUsageFetcher.parse(Data(#"{"error":"x"}"#.utf8)) == nil)
    }

    @Test func idleReminderFiresOnReturn() {
        let prefs = Prefs()
        prefs.idleReminder = true
        prefs.idleMinutes = 2
        let store = SessionStore(prefs: prefs)
        var sounds: [SoundCategory] = []
        let watcher = IdleWatcher(prefs: prefs, store: store) { sounds.append($0) }
        let now = Date()

        watcher.check(idle: 30, now: now)  // 아직 자리 비움 아님
        watcher.check(idle: 300, now: now)  // 5분째 입력 없음 → 자리 비움 시작
        store.ingest(["hook_event_name": "Notification", "session_id": "w", "cwd": "/w/app",
                      "notification_type": "idle_prompt", "message": "기다려요"], source: "claude", terminal: nil)
        watcher.check(idle: 1, now: now.addingTimeInterval(10))  // 돌아옴
        #expect(store.peek?.title == "자리 비운 사이 1개 세션이 기다려요")
        #expect(sounds == [.idleReminder])

        // 기다리는 세션이 없으면 조용히
        store.clearPeek()
        watcher.check(idle: 300, now: now.addingTimeInterval(20))
        store.ingest(["hook_event_name": "SessionEnd", "session_id": "w"], source: "claude", terminal: nil)
        watcher.check(idle: 1, now: now.addingTimeInterval(30))
        #expect(store.peek == nil)
    }
}
