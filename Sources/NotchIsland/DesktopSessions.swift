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
    static var rootOverride: URL?
    private static var root: URL {
        rootOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    private let queue = DispatchQueue(label: "notch.desktop", qos: .utility)
    private var entries: [String: Entry] = [:]  // cliSessionId → Entry
    private var lastScan = Date.distantPast

    /// cliSessionId로 데스크톱 세션 정보를 찾는다. 처음 보는 ID면 폴더를 다시 훑는다.
    func lookup(cliSessionID: String, completion: @escaping (Entry?) -> Void) {
        queue.async {
            if self.entries[cliSessionID] == nil || Date().timeIntervalSince(self.lastScan) > 30 {
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

    /// ChatGPT 앱에서 Codex 대화 열기 (codex://threads/<thread id>, thread id = 훅의 session_id)
    static func openChatGPT(threadID: String) {
        if threadID.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil,
           let url = URL(string: "codex://threads/\(threadID)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: chatGPTBundleID).first {
            app.activate()
        }
    }

    /// 데스크톱 앱에서 그 세션 열기. 앱이 링크를 막아 두었으면 앱만 앞으로 가져온다.
    static func open(desktopID: String?) {
        if let desktopID, desktopID.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
           let url = URL(string: "claude://code/continue?session=\(desktopID)&source=notch_island") {
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
