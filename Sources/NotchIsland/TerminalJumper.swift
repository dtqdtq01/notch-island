import AppKit
import ApplicationServices

/// 세션이 돌고 있는 터미널 창/탭/패널로 이동한다.
/// 정확한 이동이 안 되는 앱은 앱 활성화 + (손쉬운 사용 권한이 있으면) 프로젝트 이름이 들어간 창을 앞으로.
enum TerminalJumper {
    private static let vscodeFamily: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.vscodium", "dev.zed.Zed", "com.trae.app",
    ]

    static func jump(_ session: Session) {
        DispatchQueue.global(qos: .userInitiated).async { perform(session) }
    }

    private static func perform(_ session: Session) {
        let terminal = session.terminal
        var outerTTY = terminal.tty

        // tmux: 패널 선택 후 tmux 클라이언트가 붙은 바깥 터미널의 tty로 이동
        if let pane = terminal.tmuxPane, let tmux = firstExisting(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]) {
            run(tmux, ["select-window", "-t", pane])
            run(tmux, ["select-pane", "-t", pane])
            if let client = run(tmux, ["display-message", "-p", "-t", pane, "#{client_tty}"]), client.hasPrefix("/dev/") {
                outerTTY = client
            }
        }

        let bundle = terminal.hostBundleID
        var precise = false
        switch bundle {
        case "com.googlecode.iterm2":
            if let tty = outerTTY.flatMap(safeTTY) { precise = osascript(itermScript(tty)) == "ok" }
        case "com.apple.Terminal":
            if let tty = outerTTY.flatMap(safeTTY) { precise = osascript(appleTerminalScript(tty)) == "ok" }
        case "net.kovidgoyal.kitty":
            if let window = terminal.kittyWindow, let listen = terminal.kittyListen,
               let kitty = firstExisting(["/Applications/kitty.app/Contents/MacOS/kitty", "/opt/homebrew/bin/kitty"]) {
                precise = run(kitty, ["@", "--to", listen, "focus-window", "--match", "id:\(window)"]) != nil
            }
        case "com.github.wez.wezterm":
            if let pane = terminal.weztermPane,
               let wezterm = firstExisting(["/Applications/WezTerm.app/Contents/MacOS/wezterm", "/opt/homebrew/bin/wezterm"]) {
                precise = run(wezterm, ["cli", "activate-pane", "--pane-id", pane]) != nil
            }
        case let id? where vscodeFamily.contains(id):
            // 폴더를 열면 그 폴더의 기존 창이 앞으로 온다
            if !session.cwd.isEmpty {
                run("/usr/bin/open", ["-b", id, session.cwd])
                return
            }
        default:
            break
        }
        if precise { return }

        DispatchQueue.main.async {
            guard let bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
            app.activate()
            raiseWindow(pid: app.processIdentifier, containing: session.projectName)
        }
    }

    // MARK: - AppleScript

    private static func itermScript(_ tty: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    private static func appleTerminalScript(_ tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    // MARK: - 손쉬운 사용(AX) 창 올리기

    private static func raiseWindow(pid: pid_t, containing name: String) {
        guard AXIsProcessTrusted(), !name.isEmpty else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            if let text = title as? String, text.localizedCaseInsensitiveContains(name) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }

    // MARK: - 프로세스 실행

    private static func safeTTY(_ tty: String) -> String? {
        tty.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" } ? tty : nil
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func osascript(_ script: String) -> String? {
        run("/usr/bin/osascript", ["-e", script])
    }

    /// 성공(exit 0)하면 stdout(trim), 실패하면 nil
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
