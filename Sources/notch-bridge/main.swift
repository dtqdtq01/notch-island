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
        "ZELLIJ_SESSION_NAME",
    ]

    static func capture() -> [String: Any] {
        var info: [String: Any] = [:]
        let env = ProcessInfo.processInfo.environment
        for key in envKeys {
            if let value = env[key], !value.isEmpty { info[key] = value }
        }
        if let tty = controllingTTY() { info["tty"] = tty }
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

    static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}

func send(_ event: [String: Any]) -> Int32? {
    guard let fd = UnixSocket.connect(to: NotchPaths.socket) else { return nil }
    let envelope: [String: Any] = ["source": source, "event": event, "terminal": TerminalProbe.capture()]
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

guard let fd = send(event) else { exit(0) }

if eventName == "PermissionRequest" {
    // 앱이 결정을 보낼 때까지 블록. 사용자가 터미널에서 먼저 답하면 에이전트가 이 프로세스를 정리한다.
    if let response = LineReader(fd: fd).readLine(), !response.isEmpty {
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

close(fd)
exit(0)
