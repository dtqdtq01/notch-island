import Foundation
import SwiftUI

enum SessionStatus {
    case idle, running, waitingApproval, waitingInput, done

    var color: Color {
        switch self {
        case .running: return .green
        case .waitingApproval: return .orange
        case .waitingInput: return .yellow
        case .idle, .done: return .gray
        }
    }

    var label: String {
        switch self {
        case .idle: return "대기"
        case .running: return "작업 중"
        case .waitingApproval: return "승인 필요"
        case .waitingInput: return "입력 대기"
        case .done: return "완료"
        }
    }

    /// 접힌 노치에 어떤 색을 띄울지 고를 때 쓰는 우선순위
    var urgency: Int {
        switch self {
        case .waitingApproval: return 4
        case .waitingInput: return 3
        case .running: return 2
        case .done: return 1
        case .idle: return 0
        }
    }
}

struct Session: Identifiable {
    let id: String
    var source: String
    var cwd: String
    var status: SessionStatus = .idle
    var detail: String = ""
    var updatedAt = Date()

    var projectName: String {
        cwd.isEmpty ? id.prefix(8).description : (cwd as NSString).lastPathComponent
    }
}

struct PermissionRequest: Identifiable {
    let id: UUID
    let sessionID: String
    let projectName: String
    let toolName: String
    let preview: String
    /// Claude가 제안한 "항상 허용" 규칙. 있으면 Always 버튼 노출.
    let suggestions: [Any]?
    let responder: Responder
}

enum Decision { case allow, always, deny }

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var pending: [PermissionRequest] = []

    private var pruneTimer: Timer?

    init() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.prune()
        }
    }

    var sortedSessions: [Session] {
        sessions.values.sorted {
            if $0.status.urgency != $1.status.urgency { return $0.status.urgency > $1.status.urgency }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var mostUrgent: SessionStatus? { sortedSessions.first?.status }

    // MARK: - 이벤트 수신

    func ingest(_ event: [String: Any], source: String) {
        guard let name = event["hook_event_name"] as? String else { return }
        let sid = event["session_id"] as? String ?? "unknown"

        if name == "SessionEnd" {
            sessions[sid] = nil
            for request in pending where request.sessionID == sid { request.responder.markClosed() }
            pending.removeAll { $0.sessionID == sid }
            return
        }

        var session = touch(sid, event: event, source: source)
        switch name {
        case "SessionStart":
            session.status = .idle
            session.detail = "세션 시작"
        case "UserPromptSubmit":
            session.status = .running
            session.detail = oneLine(event["prompt"] as? String ?? "")
        case "PreToolUse":
            session.status = hasPending(sid) ? .waitingApproval : .running
            session.detail = toolSummary(event)
        case "PostToolUse":
            if !hasPending(sid) { session.status = .running }
        case "Notification":
            let type = event["notification_type"] as? String
            if type == "idle_prompt" {
                session.status = .waitingInput
                session.detail = oneLine(event["message"] as? String ?? "입력을 기다리는 중")
            }
            // permission_prompt는 PermissionRequest 훅이 따로 처리
        case "Stop":
            session.status = .done
            session.detail = "턴 완료"
        default:
            break
        }
        sessions[sid] = session
    }

    func ingestPermission(_ event: [String: Any], source: String, id: UUID, responder: Responder) {
        let sid = event["session_id"] as? String ?? "unknown"
        var session = touch(sid, event: event, source: source)
        let toolName = event["tool_name"] as? String ?? "Tool"
        let input = event["tool_input"] as? [String: Any] ?? [:]

        session.status = .waitingApproval
        session.detail = "\(toolName) 승인 대기"
        sessions[sid] = session

        pending.append(PermissionRequest(
            id: id,
            sessionID: sid,
            projectName: session.projectName,
            toolName: toolName,
            preview: ToolPreview.render(tool: toolName, input: input),
            suggestions: event["permission_suggestions"] as? [Any],
            responder: responder))
    }

    /// bridge 연결이 끊김 (응답 완료 또는 사용자가 터미널에서 답함)
    func permissionConnectionClosed(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let sid = pending[index].sessionID
        pending.remove(at: index)
        settleStatus(sid)
    }

    // MARK: - 사용자 결정

    func decide(_ request: PermissionRequest, _ decision: Decision) {
        var body: [String: Any]
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
        case .always:
            body = ["behavior": "allow"]
            if let suggestions = request.suggestions, !suggestions.isEmpty {
                body["updatedPermissions"] = suggestions
            }
        case .deny:
            body = ["behavior": "deny", "message": "Notch Island에서 거부됨"]
        }
        request.responder.respond([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": body,
            ]
        ])
        pending.removeAll { $0.id == request.id }
        if var session = sessions[request.sessionID] {
            session.detail = decision == .deny ? "\(request.toolName) 거부함" : "\(request.toolName) 허용함"
            sessions[request.sessionID] = session
        }
        settleStatus(request.sessionID)
    }

    // MARK: - 내부

    private func touch(_ sid: String, event: [String: Any], source: String) -> Session {
        var session = sessions[sid] ?? Session(id: sid, source: source, cwd: "")
        if let cwd = event["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
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

    private func prune() {
        let cutoff = Date().addingTimeInterval(-2 * 60 * 60)
        let stale = sessions.values.filter { $0.updatedAt < cutoff && !hasPending($0.id) }.map(\.id)
        for sid in stale { sessions[sid] = nil }
    }

    private func toolSummary(_ event: [String: Any]) -> String {
        let tool = event["tool_name"] as? String ?? "Tool"
        let input = event["tool_input"] as? [String: Any] ?? [:]
        if let command = input["command"] as? String { return "\(tool): \(oneLine(command))" }
        if let path = input["file_path"] as? String { return "\(tool): \((path as NSString).lastPathComponent)" }
        if let pattern = input["pattern"] as? String { return "\(tool): \(oneLine(pattern))" }
        return tool
    }

    private func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }
}
