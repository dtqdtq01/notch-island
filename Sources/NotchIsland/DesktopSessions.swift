import AppKit
import Foundation

/// Claude 데스크톱 앱의 Code 탭 세션 목록.
/// ~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json 에
/// 데스크톱 세션 ID(local_…)와 Claude Code 세션 ID(cliSessionId), 제목이 들어 있다.
final class DesktopSessionIndex {
    static let shared = DesktopSessionIndex()
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// ChatGPT 데스크톱 앱 (안에 Codex 엔진이 들어 있다)
    static let chatGPTBundleID = "com.openai.codex"

    struct Entry: Equatable {
        let desktopID: String
        let title: String?
        let cwd: String?
        let model: String?
        let permissionMode: String?
        let archived: Bool
    }

    /// 테스트에서 다른 폴더를 쓰기 위한 경로
    static var rootOverride: URL? {
        didSet { shared.reset() }
    }
    private static var root: URL {
        rootOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    private let queue = DispatchQueue(label: "notch.desktop", qos: .utility)
    private var entries: [String: Entry] = [:]  // cliSessionId → Entry
    private var lastScan = Date.distantPast

    func reset() {
        queue.sync {
            entries = [:]
            lastScan = .distantPast
        }
    }

    /// cliSessionId로 데스크톱 세션 정보를 찾는다. 처음 보는 ID면 폴더를 다시 훑는다.
    func lookup(cliSessionID: String, completion: @escaping (Entry?) -> Void) {
        queue.async {
            let age = Date().timeIntervalSince(self.lastScan)
            // 없는 ID는 다시 훑되 1초에 한 번까지만, 있는 ID도 30초마다 새로 (제목 변경 반영)
            if (self.entries[cliSessionID] == nil && age > 1) || age > 30 {
                self.entries = Self.scan()
                self.lastScan = Date()
            }
            let entry = self.entries[cliSessionID]
            DispatchQueue.main.async { completion(entry) }
        }
    }

    /// 폴더 전체 훑기 (파일이 작고 몇 개 안 돼서 가볍다)
    static func scan() -> [String: Entry] {
        var result: [String: Entry] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return result }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cli = object["cliSessionId"] as? String,
                  let desktopID = object["sessionId"] as? String else { continue }
            result[cli] = Entry(
                desktopID: desktopID,
                title: object["title"] as? String,
                cwd: object["cwd"] as? String,
                model: object["model"] as? String,
                permissionMode: object["permissionMode"] as? String,
                archived: object["isArchived"] as? Bool ?? false)
        }
        return result
    }

    static func continueURL(desktopID: String?) -> URL? {
        guard let desktopID, desktopID.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(desktopID)&source=notch_island")
    }

    /// 앱 코드의 CLI 세션 ID 형식(UUID)과 같을 때만
    static func resumeURL(cliSessionID: String?) -> URL? {
        guard let id = cliSessionID,
              id.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: "claude://resume?session=\(id)")
    }

    /// ChatGPT 앱에서 Codex 대화 열기 (codex://threads/<thread id>, thread id = 훅의 session_id)
    static func openChatGPT(threadID: String) {
        if threadID.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil,
           let url = URL(string: "codex://threads/\(threadID)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: chatGPTBundleID).first {
            app.activate()
        }
    }

    /// 데스크톱 앱에서 그 세션 열기:
    /// 앱 세션 ID(local_…)가 있으면 code/continue, 없으면 CLI 세션 ID로 resume, 둘 다 안 되면 앱만 앞으로.
    static func open(desktopID: String?, cliSessionID: String? = nil) {
        if let url = continueURL(desktopID: desktopID) ?? resumeURL(cliSessionID: cliSessionID) {
            NSWorkspace.shared.open(url)
            return
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
