import Foundation
import NotchShared
import SwiftUI

enum SessionStatus {
    case idle, running, waitingApproval, waitingInput, compacting, error, done

    var color: Color {
        switch self {
        case .running: return .green
        case .waitingApproval: return .orange
        case .waitingInput: return .yellow
        case .compacting: return .purple
        case .error: return .red
        case .idle, .done: return .gray
        }
    }

    var label: String {
        switch self {
        case .idle: return "대기"
        case .running: return "작업 중"
        case .waitingApproval: return "승인 필요"
        case .waitingInput: return "입력 대기"
        case .compacting: return "압축 중"
        case .error: return "오류"
        case .done: return "완료"
        }
    }

    /// 접힌 노치에 어떤 색을 띄울지 고를 때 쓰는 우선순위
    var urgency: Int {
        switch self {
        case .waitingApproval: return 6
        case .waitingInput: return 5
        case .error: return 4
        case .running, .compacting: return 3
        case .done: return 2
        case .idle: return 1
        }
    }
}

/// bridge가 보내는 터미널 정보 (점프용)
struct TerminalInfo {
    var tty: String?
    var termProgram: String?
    var bundleID: String?
    var tmuxPane: String?
    var kittyWindow: String?
    var kittyListen: String?
    var weztermPane: String?
    var warpFocusURL: String?
    var agentPID: Int32?
    var ancestorBundles: [String] = []

    init(_ info: [String: Any]?) {
        let info = info ?? [:]
        tty = info["tty"] as? String
        termProgram = info["TERM_PROGRAM"] as? String
        bundleID = info["__CFBundleIdentifier"] as? String
        tmuxPane = info["TMUX_PANE"] as? String
        kittyWindow = info["KITTY_WINDOW_ID"] as? String
        kittyListen = info["KITTY_LISTEN_ON"] as? String
        weztermPane = info["WEZTERM_PANE"] as? String
        warpFocusURL = info["WARP_FOCUS_URL"] as? String
        agentPID = (info["agent_pid"] as? NSNumber).map { Int32(truncating: $0) }
        ancestorBundles = info["ancestor_bundles"] as? [String] ?? []
    }

    var isEmpty: Bool {
        tty == nil && bundleID == nil && termProgram == nil && agentPID == nil && ancestorBundles.isEmpty
    }

    /// 실제 창을 띄운 앱의 번들 ID
    var hostBundleID: String? {
        if let bundleID { return bundleID }
        switch termProgram {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WezTerm": return "com.github.wez.wezterm"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "vscode": return "com.microsoft.VSCode"
        default: return kittyWindow != nil ? "net.kovidgoyal.kitty" : nil
        }
    }
}

struct Session: Identifiable {
    let id: String
    var source: String
    var cwd = ""
    var status: SessionStatus = .idle
    var detail = ""
    var model: String?
    var contextPercent: Double?
    var subagents = 0
    var firstPrompt: String?
    var terminal = TerminalInfo(nil)
    var updatedAt = Date()

    var projectName: String {
        cwd.isEmpty ? String(id.prefix(8)) : (cwd as NSString).lastPathComponent
    }

    var sourceLabel: String {
        switch source {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return source.capitalized
        }
    }
}

struct QuestionOption: Hashable {
    let label: String
    let description: String
}

struct AgentQuestion: Identifiable {
    let id: Int
    let text: String
    let header: String
    let options: [QuestionOption]
    let multiSelect: Bool
}

enum RequestKind {
    case permission
    case question([AgentQuestion])
    case plan(String)
}

struct PendingRequest: Identifiable {
    let id: UUID
    let sessionID: String
    let projectName: String
    let source: String
    let toolName: String
    let kind: RequestKind
    let preview: String
    let input: [String: Any]
    /// "항상 허용" 때 적용할 규칙 (에이전트가 제안한 것)
    let suggestions: [Any]?
    let responder: Responder

    var isPermission: Bool {
        if case .permission = kind { return true }
        return false
    }
}

enum Decision {
    case allow, always, deny
    /// 거부하면서 에이전트에게 이유/수정 요청을 전달
    case denyWithMessage(String)
    /// 계획 승인 + 이후 권한 모드 (nil이면 그대로)
    case approvePlan(mode: String?)
    /// AskUserQuestion 답변: 질문 원문 → 문자열 또는 [문자열]
    case answer([String: Any])
    /// 노치에서는 답하지 않고 터미널 프롬프트로 넘김
    case terminal
}

enum PeekKind { case complete, error, usage, info }

struct Peek: Identifiable {
    let id = UUID()
    let sessionID: String?
    let kind: PeekKind
    let title: String
    let body: String
}

struct RateWindow {
    var usedPercent: Double
    var resetsAt: Date?
}

struct RateLimits {
    var fiveHour: RateWindow?
    var sevenDay: RateWindow?
    var updatedAt = Date()
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var pending: [PendingRequest] = [] {
        didSet {
            let alive = Set(pending.map(\.id))
            drafts = drafts.filter { alive.contains($0.key) }
        }
    }
    @Published private(set) var peek: Peek?
    @Published private(set) var rateLimits: RateLimits?

    var onSound: ((SoundCategory) -> Void)?
    /// 요청별 답변 초안 — 노치가 접혔다 펼쳐져도 쓰던 내용 유지
    private var drafts: [UUID: RequestDraft] = [:]
    /// 화면 공유·집중 모드 등 조용히 해야 하는 상황인지
    var isQuiet: () -> Bool = { false }
    /// 숨김 규칙에 걸린 세션 — 이후 이벤트도 무시
    private(set) var silenced = Set<String>()

    private let prefs: Prefs
    private var pruneTimer: Timer?
    private var livenessTimer: Timer?
    private var peekWork: DispatchWorkItem?
    private var promptTimes: [Date] = []
    private var alertedWindows = Set<String>()

    init(prefs: Prefs) {
        self.prefs = prefs
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.prune()
        }
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reapDeadSessions()
        }
        loadCachedRateLimits()
    }

    var sortedSessions: [Session] {
        sessions.values.sorted {
            if $0.status.urgency != $1.status.urgency { return $0.status.urgency > $1.status.urgency }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var mostUrgent: SessionStatus? { sortedSessions.first?.status }

    /// 점프 단축키 대상: 대기 중인 요청의 세션, 없으면 가장 급한 세션
    var jumpTarget: Session? {
        if let request = pending.first, let session = sessions[request.sessionID] { return session }
        return sortedSessions.first
    }

    // MARK: - 이벤트 수신

    func ingest(_ event: [String: Any], source: String, terminal: [String: Any]?) {
        guard let name = event["hook_event_name"] as? String else { return }
        let sid = event["session_id"] as? String ?? "unknown"

        if name == "SessionEnd" {
            endSession(sid)
            silenced.remove(sid)
            return
        }
        if silenced.contains(sid) { return }

        if name == "StatusLine" {
            ingestStatusLine(event, sid: sid, source: source, terminal: terminal)
            return
        }

        var session = touch(sid, event: event, source: source, terminal: terminal)
        if name == "UserPromptSubmit", session.firstPrompt == nil {
            session.firstPrompt = event["prompt"] as? String
        }
        if silenceReason(session) != nil {
            silence(sid)
            return
        }
        switch name {
        case "SessionStart":
            session.status = .idle
            session.detail = "세션 시작"
            if (event["source"] as? String) == "startup" { onSound?(.sessionStart) }
        case "UserPromptSubmit":
            session.status = .running
            session.detail = oneLine(event["prompt"] as? String ?? "")
            if peek?.sessionID == sid { clearPeek() }
            onSound?(.taskAcknowledge)
            detectSpam()
        case "PreToolUse":
            session.status = hasPending(sid) ? .waitingApproval : .running
            session.detail = toolSummary(event)
        case "PostToolUse":
            if !hasPending(sid) { session.status = .running }
        case "Notification":
            if (event["notification_type"] as? String) == "idle_prompt" {
                session.status = .waitingInput
                session.detail = oneLine(event["message"] as? String ?? "입력을 기다리는 중")
                onSound?(.idleReminder)
            }
        case "PreCompact":
            session.status = .compacting
            session.detail = "컨텍스트 압축 중"
            if (event["trigger"] as? String) == "auto" { onSound?(.resourceLimit) }
        case "PostCompact":
            session.status = .running
            session.detail = "컨텍스트 압축 완료"
        case "SubagentStart":
            session.subagents += 1
        case "SubagentStop":
            session.subagents = max(0, session.subagents - 1)
        case "Stop":
            session.status = .done
            session.subagents = 0
            session.detail = "턴 완료"
            onSound?(.taskComplete)
            showCompletion(sid: sid, event: event)
        case "StopFailure":
            session.status = .error
            let reason = oneLine(event["error"] as? String ?? event["message"] as? String ?? "턴 실패")
            session.detail = reason
            onSound?(.taskError)
            showPeek(Peek(sessionID: sid, kind: .error, title: "\(session.projectName) 오류", body: reason))
        default:
            break
        }
        sessions[sid] = session
    }

    func ingestPermission(_ event: [String: Any], source: String, terminal: [String: Any]?, id: UUID, responder: Responder) {
        let sid = event["session_id"] as? String ?? "unknown"
        var session = touch(sid, event: event, source: source, terminal: terminal)
        // 숨긴 세션은 노치에서 다루지 않고 터미널 프롬프트로 넘긴다
        if silenced.contains(sid) || silenceReason(session) != nil {
            responder.cancel()
            silence(sid)
            return
        }
        let toolName = event["tool_name"] as? String ?? "Tool"
        let input = event["tool_input"] as? [String: Any] ?? [:]

        let kind: RequestKind
        switch toolName {
        case "AskUserQuestion":
            let questions = Self.parseQuestions(input)
            kind = questions.isEmpty ? .permission : .question(questions)
        case "ExitPlanMode":
            kind = .plan(input["plan"] as? String ?? "")
        default:
            kind = .permission
        }

        session.status = .waitingApproval
        switch kind {
        case .question: session.detail = "질문에 답해 주세요"
        case .plan: session.detail = "계획 승인 대기"
        case .permission: session.detail = "\(toolName) 승인 대기"
        }
        sessions[sid] = session
        if peek?.sessionID == sid { clearPeek() }

        pending.append(PendingRequest(
            id: id,
            sessionID: sid,
            projectName: session.projectName,
            source: source,
            toolName: toolName,
            kind: kind,
            preview: ToolPreview.render(tool: toolName, input: input),
            input: input,
            suggestions: event["permission_suggestions"] as? [Any],
            responder: responder))
        onSound?(.inputRequired)
    }

    /// bridge 연결이 끊김 (응답 완료 또는 사용자가 터미널에서 답함)
    func permissionConnectionClosed(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let sid = pending[index].sessionID
        pending.remove(at: index)
        settleStatus(sid)
    }

    // MARK: - 사용자 결정

    func decide(_ request: PendingRequest, _ decision: Decision) {
        var body: [String: Any]
        var note: String
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
            note = "\(request.toolName) 허용함"
        case .always:
            body = ["behavior": "allow"]
            if let suggestions = request.suggestions, !suggestions.isEmpty {
                body["updatedPermissions"] = suggestions
            }
            note = "\(request.toolName) 항상 허용"
        case .deny:
            body = ["behavior": "deny", "message": "사용자가 Notch Island에서 거부했습니다"]
            note = "\(request.toolName) 거부함"
        case .denyWithMessage(let message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            body = ["behavior": "deny", "message": text.isEmpty ? "사용자가 Notch Island에서 거부했습니다" : text]
            note = "의견 보냄"
        case .approvePlan(let mode):
            body = ["behavior": "allow"]
            if let mode {
                body["updatedPermissions"] = [["type": "setMode", "mode": mode, "destination": "session"]]
            }
            note = "계획 승인"
        case .answer(let answers):
            // 원래 입력은 그대로 두고 answers만 추가해야 에이전트가 받아들인다
            var updated = request.input
            updated["answers"] = answers
            body = ["behavior": "allow", "updatedInput": updated]
            note = "질문에 답함"
        case .terminal:
            request.responder.cancel()
            pending.removeAll { $0.id == request.id }
            settleStatus(request.sessionID)
            if let session = sessions[request.sessionID] { TerminalJumper.jump(session) }
            return
        }
        request.responder.respond([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": body,
            ]
        ])
        pending.removeAll { $0.id == request.id }
        if var session = sessions[request.sessionID] {
            session.detail = note
            sessions[request.sessionID] = session
        }
        settleStatus(request.sessionID)
    }

    /// 대기 중인 일반 권한 요청 전부 허용/거부
    func decideAllPermissions(_ decision: Decision) {
        for request in pending where request.isPermission { decide(request, decision) }
    }

    /// 앱이 직접 띄우는 안내 (훅 복구 등)
    func notify(_ title: String, _ body: String = "") {
        showPeek(Peek(sessionID: nil, kind: .info, title: title, body: body))
    }

    /// 노치에서 세션 카드를 닫음 (다음 이벤트가 오면 다시 나타남)
    func dismiss(_ sid: String) {
        endSession(sid)
    }

    /// 숨김 규칙을 추가하고 지금 해당하는 세션을 모두 숨긴다
    func addSilenceRule(directory: String? = nil, promptPrefix: String? = nil) {
        if let directory, !directory.isEmpty, !prefs.silencedDirectories.contains(directory) {
            prefs.silencedDirectories.append(directory)
        }
        if let promptPrefix, !promptPrefix.isEmpty, !prefs.silencedPromptPrefixes.contains(promptPrefix) {
            prefs.silencedPromptPrefixes.append(promptPrefix)
        }
        for session in sessions.values where silenceReason(session) != nil { silence(session.id) }
    }

    /// 세션을 숨겨야 하는 이유 (없으면 nil)
    func silenceReason(_ session: Session) -> String? {
        if let bundle = session.terminal.ancestorBundles.first(where: prefs.blockedLaunchers.contains) {
            return "차단한 앱에서 실행됨: \(bundle)"
        }
        if prefs.hideSessionsWithoutTTY, session.terminal.tty == nil, session.terminal.agentPID != nil {
            return "터미널 없는 백그라운드 세션"
        }
        if let directory = prefs.silencedDirectories.first(where: { !$0.isEmpty && session.cwd.contains($0) }) {
            return "숨긴 폴더: \(directory)"
        }
        if let prompt = session.firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let prefix = prefs.silencedPromptPrefixes.first(where: { !$0.isEmpty && prompt.hasPrefix($0) }) {
                return "숨긴 프롬프트: \(prefix)"
            }
            if let part = prefs.silencedPromptContains.first(where: { !$0.isEmpty && prompt.contains($0) }) {
                return "숨긴 프롬프트: \(part)"
            }
        }
        return nil
    }

    private func silence(_ sid: String) {
        silenced.insert(sid)
        endSession(sid)
    }

    private func endSession(_ sid: String) {
        sessions[sid] = nil
        for request in pending where request.sessionID == sid { request.responder.cancel() }
        pending.removeAll { $0.sessionID == sid }
        if peek?.sessionID == sid { clearPeek() }
    }

    /// SessionEnd 없이 에이전트 프로세스가 죽은 세션 정리
    func reapDeadSessions() {
        for session in sessions.values {
            guard let pid = session.terminal.agentPID, pid > 1 else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { endSession(session.id) }
        }
    }

    func draft(for request: PendingRequest) -> RequestDraft {
        if let existing = drafts[request.id] { return existing }
        let draft = RequestDraft()
        drafts[request.id] = draft
        return draft
    }

    func clearPeek() {
        peekWork?.cancel()
        peek = nil
    }

    // MARK: - statusLine (모델, 컨텍스트, 사용량)

    private func ingestStatusLine(_ event: [String: Any], sid: String, source: String, terminal: [String: Any]?) {
        if sid != "unknown", !silenced.contains(sid) {
            var session = sessions[sid] ?? Session(id: sid, source: source)
            if let cwd = (event["workspace"] as? [String: Any])?["current_dir"] as? String ?? event["cwd"] as? String,
               session.cwd.isEmpty { session.cwd = cwd }
            if let model = (event["model"] as? [String: Any])?["display_name"] as? String { session.model = model }
            if let used = ((event["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
                session.contextPercent = used
            }
            if session.terminal.isEmpty { session.terminal = TerminalInfo(terminal) }
            sessions[sid] = session
        }
        if let limits = event["rate_limits"] as? [String: Any] {
            updateRateLimits(limits)
        }
    }

    private func updateRateLimits(_ raw: [String: Any]) {
        func window(_ key: String) -> RateWindow? {
            guard let dict = raw[key] as? [String: Any],
                  let used = (dict["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (dict["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return RateWindow(usedPercent: used, resetsAt: reset)
        }
        applyRateLimits(RateLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day")))
    }

    /// 상태줄·사용량 API 어느 쪽에서 오든 같은 경로로 반영 (경고선 알림 포함)
    func applyRateLimits(_ limits: RateLimits) {
        let previous = rateLimits
        rateLimits = limits

        guard prefs.usageAlert else { return }
        for (key, title, now, before) in [
            ("5h", "5시간 세션", limits.fiveHour, previous?.fiveHour),
            ("7d", "7일 주간", limits.sevenDay, previous?.sevenDay),
        ] {
            guard let now else { continue }
            if now.usedPercent >= prefs.usageThreshold {
                if !alertedWindows.contains(key) {
                    alertedWindows.insert(key)
                    onSound?(.usageWarning)
                    showPeek(Peek(sessionID: nil, kind: .usage, title: "\(title) 사용량 \(Int(now.usedPercent))%",
                                  body: now.resetsAt.map { "초기화 " + Self.relative($0) } ?? ""))
                }
            } else {
                alertedWindows.remove(key)
                if let before, before.usedPercent >= prefs.usageThreshold {
                    showPeek(Peek(sessionID: nil, kind: .usage, title: "\(title) 한도 초기화됨", body: "다시 쓸 수 있어요"))
                }
            }
        }
    }

    private func loadCachedRateLimits() {
        guard let data = try? Data(contentsOf: NotchPaths.rateLimitsCache),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        updateRateLimits(raw)
    }

    // MARK: - 완료 알림

    private func showCompletion(sid: String, event: [String: Any]) {
        guard prefs.autoExpandOnComplete else { return }
        let project = sessions[sid]?.projectName ?? "세션"
        if let message = event["last_assistant_message"] as? String, !message.isEmpty {
            showPeek(Peek(sessionID: sid, kind: .complete, title: "\(project) 완료", body: oneLine(message, limit: 220)))
            return
        }
        let transcript = event["transcript_path"] as? String
        DispatchQueue.global(qos: .utility).async {
            let text = transcript.flatMap(Self.lastAssistantText) ?? "턴을 마쳤어요"
            DispatchQueue.main.async {
                guard self.sessions[sid]?.status == .done else { return }
                self.showPeek(Peek(sessionID: sid, kind: .complete, title: "\(project) 완료", body: self.oneLine(text, limit: 220)))
            }
        }
    }

    private func showPeek(_ newPeek: Peek) {
        if isQuiet() { return }
        peekWork?.cancel()
        peek = newPeek
        let work = DispatchWorkItem { [weak self] in self?.peek = nil }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(prefs.completionDwell, 1), execute: work)
    }

    /// transcript 끝부분에서 마지막 assistant 텍스트를 찾는다
    static func lastAssistantText(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let data = handle.readDataToEndOfFile()
        for line in data.split(separator: 0x0A).reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    // MARK: - 내부

    private func touch(_ sid: String, event: [String: Any], source: String, terminal: [String: Any]?) -> Session {
        var session = sessions[sid] ?? Session(id: sid, source: source)
        if let cwd = event["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
        let info = TerminalInfo(terminal)
        if !info.isEmpty { session.terminal = info }
        session.updatedAt = Date()
        return session
    }

    private func hasPending(_ sid: String) -> Bool {
        pending.contains { $0.sessionID == sid }
    }

    private func settleStatus(_ sid: String) {
        guard var session = sessions[sid], session.status == .waitingApproval, !hasPending(sid) else { return }
        session.status = .running
        sessions[sid] = session
    }

    private func detectSpam() {
        let now = Date()
        promptTimes = promptTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
        if promptTimes.count >= 3 {
            promptTimes.removeAll()
            onSound?(.userSpam)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-2 * 60 * 60)
        let stale = sessions.values.filter { $0.updatedAt < cutoff && !hasPending($0.id) }.map(\.id)
        for sid in stale { sessions[sid] = nil }
    }

    static func parseQuestions(_ input: [String: Any]) -> [AgentQuestion] {
        let raw = input["questions"] as? [[String: Any]] ?? []
        return raw.enumerated().compactMap { index, item in
            guard let text = item["question"] as? String else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> QuestionOption? in
                guard let label = option["label"] as? String else { return nil }
                return QuestionOption(label: label, description: option["description"] as? String ?? "")
            }
            return AgentQuestion(
                id: index, text: text, header: item["header"] as? String ?? "",
                options: options, multiSelect: item["multiSelect"] as? Bool ?? false)
        }
    }

    private func toolSummary(_ event: [String: Any]) -> String {
        let tool = event["tool_name"] as? String ?? "Tool"
        let input = event["tool_input"] as? [String: Any] ?? [:]
        if let command = input["command"] as? String { return "\(tool): \(oneLine(command))" }
        if let path = input["file_path"] as? String { return "\(tool): \((path as NSString).lastPathComponent)" }
        if let pattern = input["pattern"] as? String { return "\(tool): \(oneLine(pattern))" }
        if let description = input["description"] as? String { return "\(tool): \(oneLine(description))" }
        return tool
    }

    func oneLine(_ text: String, limit: Int = 120) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 질문·계획 카드에서 쓰던 내용
final class RequestDraft: ObservableObject {
    @Published var step = 0
    @Published var selections: [Int: Set<String>] = [:]
    @Published var custom: [Int: String] = [:]
    @Published var feedback = ""
    @Published var planMode: String = "acceptEdits"
}
