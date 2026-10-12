import Foundation
import NotchShared
import ServiceManagement

/// 에이전트 설정 파일에 훅을 설치/제거한다. 수정 전에는 항상 백업을 남긴다.
enum Integrations {
    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }

        var title: String { self == .claude ? "Claude Code" : "Codex CLI" }

        var configFile: URL {
            let home = NotchPaths.home
            return self == .claude
                ? home.appendingPathComponent(".claude/settings.json")
                : home.appendingPathComponent(".codex/hooks.json")
        }

        var command: String { "\"$HOME/.notch-island/bin/notch-bridge\" --source \(rawValue) || true" }

        /// 이벤트 → (matcher, timeout초)
        var events: [(String, String?, Int?)] {
            switch self {
            case .claude:
                return [
                    ("SessionStart", nil, nil), ("SessionEnd", nil, nil), ("UserPromptSubmit", nil, nil),
                    ("PreToolUse", "*", nil), ("PostToolUse", "*", nil), ("PermissionRequest", "*", 86400),
                    ("Notification", "*", nil), ("Stop", nil, nil), ("StopFailure", nil, nil),
                    ("SubagentStart", nil, nil), ("SubagentStop", nil, nil),
                    ("PreCompact", nil, nil), ("PostCompact", nil, nil),
                ]
            case .codex:
                // Codex(ChatGPT 앱 포함)가 지원하는 이벤트
                return [
                    ("SessionStart", nil, 5), ("SessionEnd", nil, 3), ("UserPromptSubmit", nil, 5),
                    ("PreToolUse", "", 5), ("PostToolUse", "", 5), ("PermissionRequest", nil, 7200),
                    ("Stop", nil, 5), ("SubagentStart", nil, 5), ("SubagentStop", nil, 5),
                    ("PreCompact", nil, 5), ("PostCompact", nil, 5),
                ]
            }
        }
    }

    static let ourMarker = "notch-bridge"
    static let vibeMarker = "vibe-island-bridge"

    // MARK: - 상태

    static func isInstalled(_ agent: Agent) -> Bool {
        containsCommand(agent, marker: ourMarker)
    }

    static func hasVibeIslandHooks(_ agent: Agent) -> Bool {
        containsCommand(agent, marker: vibeMarker)
    }

    static func isAgentPresent(_ agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: agent.configFile.deletingLastPathComponent().path)
    }

    static var isStatusLineInstalled: Bool {
        let command = (load(.claude)["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        return command.contains(ourMarker)
    }

    // MARK: - 설치/제거

    static func install(_ agent: Agent) throws {
        var settings = load(agent)
        var hooks = strip(settings["hooks"] as? [String: Any] ?? [:], marker: ourMarker)
        for (event, matcher, timeout) in agent.events {
            var hook: [String: Any] = ["type": "command", "command": agent.command]
            if let timeout { hook["timeout"] = timeout }
            var entry: [String: Any] = ["hooks": [hook]]
            if let matcher { entry["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
        }
        settings["hooks"] = hooks
        try save(settings, agent)
    }

    static func uninstall(_ agent: Agent) throws {
        var settings = load(agent)
        settings["hooks"] = strip(settings["hooks"] as? [String: Any] ?? [:], marker: ourMarker)
        try save(settings, agent)
    }

    /// Vibe Island가 넣은 훅만 제거 (두 앱이 같은 요청을 동시에 잡지 않도록)
    static func removeVibeIslandHooks(_ agent: Agent) throws {
        var settings = load(agent)
        settings["hooks"] = strip(settings["hooks"] as? [String: Any] ?? [:], marker: vibeMarker)
        try save(settings, agent)
    }

    /// Claude statusLine을 bridge로 교체. 기존 명령은 bridge가 이어서 실행한다.
    static func installStatusLine() throws {
        var settings = load(.claude)
        let existing = (settings["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        if !existing.contains(ourMarker) {
            try FileManager.default.createDirectory(at: NotchPaths.root, withIntermediateDirectories: true)
            // Vibe Island 상태줄은 Vibe 전용이므로 이어 붙이지 않는다
            let keep = existing.contains("vibe-island") ? "" : existing
            try keep.write(to: NotchPaths.previousStatusLine, atomically: true, encoding: .utf8)
        }
        settings["statusLine"] = ["type": "command", "command": "\"$HOME/.notch-island/bin/notch-bridge\" --statusline"]
        try save(settings, .claude)
    }

    static func uninstallStatusLine() throws {
        var settings = load(.claude)
        let previous = (try? String(contentsOf: NotchPaths.previousStatusLine, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        settings["statusLine"] = previous.isEmpty ? nil : ["type": "command", "command": previous]
        try save(settings, .claude)
        try? FileManager.default.removeItem(at: NotchPaths.previousStatusLine)
    }

    // MARK: - bridge 설치

    /// 앱 번들 안의 bridge를 ~/.notch-island/bin 으로 복사 (훅 경로를 고정하기 위해)
    static func installBridge() {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notch-bridge")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let target = URL(fileURLWithPath: NotchPaths.bridge)
        let fm = FileManager.default
        if fm.contentsEqual(atPath: source.path, andPath: target.path) { return }
        try? fm.createDirectory(at: NotchPaths.binDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: source, to: target)
        chmod(target.path, 0o755)
    }

    // MARK: - 로그인 시 실행

    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    // MARK: - 파일 처리

    private static func containsCommand(_ agent: Agent, marker: String) -> Bool {
        let hooks = load(agent)["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { entries in
            (entries as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains(marker) }
            }
        }
    }

    private static func strip(_ hooks: [String: Any], marker: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { result[event] = value; continue }
            let kept: [[String: Any]] = entries.compactMap { entry in
                var entry = entry
                let remaining = (entry["hooks"] as? [[String: Any]] ?? []).filter {
                    !($0["command"] as? String ?? "").contains(marker)
                }
                if remaining.isEmpty { return nil }
                entry["hooks"] = remaining
                return entry
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func load(_ agent: Agent) -> [String: Any] {
        guard let data = try? Data(contentsOf: agent.configFile),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }

    private static func save(_ settings: [String: Any], _ agent: Agent) throws {
        let fm = FileManager.default
        let file = agent.configFile
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path) {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.lastPathComponent).notch-backup-\(stamp)")
            // 같은 순간의 백업이 이미 있으면 그게 더 이전 상태이므로 그대로 둔다
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: file, to: backup) }
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }
}
