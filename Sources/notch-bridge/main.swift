import Foundation
import NotchShared

// Claude Code / Codex 훅에서 실행됨: stdin JSON → 앱 소켓.
// PermissionRequest만 앱의 결정을 기다렸다가 stdout으로 돌려준다.
// 앱이 없거나 응답이 없으면 아무것도 출력하지 않고 exit 0 → 에이전트가 원래대로 터미널에서 묻는다.
//
//   notch-bridge --source claude        훅 모드
//   notch-bridge --statusline           Claude statusLine 모드 (사용량·모델·컨텍스트 전달)

signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let source = argument("--source") ?? "claude"

/// 에이전트가 돌고 있는 터미널을 찾기 위한 정보 (점프용)
enum TerminalProbe {
    static let envKeys = [
        "TERM_PROGRAM", "__CFBundleIdentifier", "ITERM_SESSION_ID", "TERM_SESSION_ID",
        "TMUX", "TMUX_PANE", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON", "WEZTERM_PANE",
        "ZELLIJ_SESSION_NAME", "WARP_FOCUS_URL", "CLAUDE_CODE_ENTRYPOINT",
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "env", "nohup"]

    static func capture() -> [String: Any] {
        var info: [String: Any] = [:]
        let env = ProcessInfo.processInfo.environment
        for key in envKeys {
            if let value = env[key], !value.isEmpty { info[key] = value }
        }
        if let tty = controllingTTY() { info["tty"] = tty }
        let chain = ancestors()
        // 훅을 띄운 셸을 건너뛴 첫 조상 = 에이전트 프로세스 (앱이 생존 여부를 감시)
        if let agent = chain.first(where: { !shells.contains(($0.path as NSString).lastPathComponent) }) {
            info["agent_pid"] = Int(agent.pid)
        }
        // 세션을 띄운 앱들의 번들 ID (가까운 순서) — 백그라운드 도구 세션 걸러내기용
        var bundles: [String] = []
        for entry in chain {
            if let id = bundleID(forExecutable: entry.path), !bundles.contains(id) { bundles.append(id) }
        }
        if !bundles.isEmpty { info["ancestor_bundles"] = bundles }
        return info
    }

    /// 부모 프로세스를 거슬러 올라가며 처음 만나는 제어 터미널
    static func controllingTTY() -> String? {
        var pid = getppid()
        for _ in 0..<12 {
            guard pid > 1, let proc = kinfo(pid) else { return nil }
            let dev = proc.kp_eproc.e_tdev
            if dev != -1, let name = devname(dev, S_IFCHR) {
                let tty = String(cString: name)
                if tty != "??" { return "/dev/" + tty }
            }
            pid = proc.kp_eproc.e_ppid
        }
        return nil
    }

    /// 부모부터 launchd 직전까지의 (pid, 실행 파일 경로)
    static func ancestors() -> [(pid: pid_t, path: String)] {
        var result: [(pid_t, String)] = []
        var pid = getppid()
        for _ in 0..<25 {
            guard pid > 1, let proc = kinfo(pid) else { break }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                result.append((pid, String(cString: buffer)))
            }
            pid = proc.kp_eproc.e_ppid
        }
        return result
    }

    static func bundleID(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        let plist = String(path[..<range.lowerBound]) + ".app/Contents/Info.plist"
        return NSDictionary(contentsOfFile: plist)?["CFBundleIdentifier"] as? String
    }

    static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}

/// AppleScript로 창을 찾을 수 없는 터미널은 창 제목에 세션 표식을 넣어 두고, 앱이 그 제목으로 창을 찾는다.
enum TitleMarker {
    private static let markedTerminals: Set<String> = ["ghostty", "WarpTerminal", "Hyper", "alacritty", "Tabby", "rio"]
    private static let markedBundles: Set<String> = [
        "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "co.zeit.hyper",
        "org.alacritty", "org.tabby", "com.raphaelamorim.rio",
    ]

    static func marker(for sessionID: String) -> String { "‹\(sessionID.prefix(8))›" }

    static func applies(_ terminal: [String: Any]) -> Bool {
        guard terminal["TMUX"] == nil else { return false }  // tmux 안에서는 바깥 창 제목이 바뀌지 않음
        if FileManager.default.fileExists(atPath: NotchPaths.titleMarkerDisabled.path) { return false }
        if let program = terminal["TERM_PROGRAM"] as? String, markedTerminals.contains(program) { return true }
        if let bundle = terminal["__CFBundleIdentifier"] as? String, markedBundles.contains(bundle) { return true }
        // 원격 제어가 꺼진 kitty
        return terminal["KITTY_WINDOW_ID"] != nil && terminal["KITTY_LISTEN_ON"] == nil
    }

    /// OSC 2 (창 제목) 를 제어 터미널에 직접 쓴다
    static func write(sessionID: String, cwd: String?, tty: String?) {
        let project = cwd.map { ($0 as NSString).lastPathComponent } ?? "claude"
        let title = "\(project) \(marker(for: sessionID))"
            .replacingOccurrences(of: "\u{07}", with: "")
            .replacingOccurrences(of: "\u{1B}", with: "")
        var fd = open("/dev/tty", O_WRONLY | O_NOCTTY | O_NONBLOCK)
        if fd < 0, let tty { fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK) }
        guard fd >= 0 else { return }
        defer { close(fd) }
        UnixSocket.writeAll(fd, Data("\u{1B}]2;\(title)\u{07}".utf8))
    }
}

/// 앱이 쓰지 않는 큰 필드를 덜어내 소켓 부담을 줄인다
func slimmed(_ event: [String: Any]) -> [String: Any] {
    var event = event
    event["tool_response"] = nil  // PostToolUse 결과(파일 내용 등)는 쓰지 않음
    let tool = event["tool_name"] as? String
    if tool != "AskUserQuestion" && tool != "ExitPlanMode", var input = event["tool_input"] as? [String: Any] {
        let limit = 100_000
        for (key, value) in input {
            if let text = value as? String, text.count > limit {
                input[key] = String(text.prefix(limit)) + "\n… (Notch Island: 미리보기용으로 잘림)"
            }
        }
        event["tool_input"] = input
    }
    return event
}

func send(_ event: [String: Any], terminal: [String: Any] = TerminalProbe.capture()) -> Int32? {
    guard let fd = UnixSocket.connect(to: NotchPaths.socket) else { return nil }
    let envelope: [String: Any] = ["source": source, "event": event, "terminal": terminal]
    guard UnixSocket.sendLine(fd, envelope) else { close(fd); return nil }
    return fd
}

// MARK: - statusLine 모드

func runStatusLine() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]

    if !object.isEmpty {
        var event = object
        event["hook_event_name"] = "StatusLine"
        if let fd = send(event) { close(fd) }
        if let limits = object["rate_limits"],
           let data = try? JSONSerialization.data(withJSONObject: limits) {
            try? FileManager.default.createDirectory(at: NotchPaths.cacheDir, withIntermediateDirectories: true)
            try? data.write(to: NotchPaths.rateLimitsCache, options: .atomic)
        }
    }

    // 연동 전에 쓰던 statusLine이 있으면 그대로 이어서 실행
    if let previous = try? String(contentsOf: NotchPaths.previousStatusLine, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", previous]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.standardOutput
        if (try? process.run()) != nil {
            pipe.fileHandleForWriting.write(input)
            try? pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            exit(0)
        }
    }

    var parts: [String] = []
    if let model = (object["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let used = ((object["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
        parts.append("ctx \(Int(used))%")
    }
    if let five = ((object["rate_limits"] as? [String: Any])?["five_hour"] as? [String: Any])?["used_percentage"] as? NSNumber {
        parts.append("5h \(five.intValue)%")
    }
    print(parts.joined(separator: " · "))
    exit(0)
}

if args.contains("--statusline") { runStatusLine() }

// MARK: - 훅 모드

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty,
      let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let eventName = event["hook_event_name"] as? String
else { exit(0) }

/// ~/.notch-island/debug 파일이 있을 때만 호출 기록을 남긴다 (경로·내용은 남기지 않음)
func debugLog(_ eventName: String, _ terminal: [String: Any], _ event: [String: Any], note: String) {
    let root = NotchPaths.root
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("debug").path) else { return }
    let sid = (event["session_id"] as? String).map { String($0.prefix(8)) } ?? "-"
    let bundles = (terminal["ancestor_bundles"] as? [String] ?? []).joined(separator: ",")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(eventName) src=\(source) sid=\(sid) "
        + "tty=\(terminal["tty"] != nil) entry=\(terminal["CLAUDE_CODE_ENTRYPOINT"] as? String ?? "-") "
        + "bundles=[\(bundles)] \(note)\n"
    let url = root.appendingPathComponent("bridge.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

// 사용자가 끈 세션 (예: NOTCH_ISLAND_SKIP=1 claude -p ...)
if ProcessInfo.processInfo.environment["NOTCH_ISLAND_SKIP"] != nil { exit(0) }

let terminal = TerminalProbe.capture()
if ["SessionStart", "UserPromptSubmit", "Stop", "Notification"].contains(eventName),
   let sessionID = event["session_id"] as? String, TitleMarker.applies(terminal) {
    TitleMarker.write(sessionID: sessionID, cwd: event["cwd"] as? String, tty: terminal["tty"] as? String)
}

guard let fd = send(slimmed(event), terminal: terminal) else {
    debugLog(eventName, terminal, event, note: "app-unreachable")
    exit(0)
}
debugLog(eventName, terminal, event, note: "sent")

if eventName == "PermissionRequest" {
    // 앱이 결정을 보낼 때까지 블록. 사용자가 터미널에서 먼저 답하면 에이전트가 이 프로세스를 정리한다.
    if let response = LineReader(fd: fd).readLine(), !response.isEmpty {
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

close(fd)
exit(0)
