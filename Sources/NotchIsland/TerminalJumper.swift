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

        // Warp가 알려준 세션 전용 주소
        if let url = terminal.warpFocusURL, url.contains("://"), run("/usr/bin/open", [url]) != nil { return }

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
            // 창을 먼저 앞으로(메인 창으로) 올린 뒤 앱을 활성화해야
            // macOS가 그 창이 있는 데스크톱 공간(Space)으로 넘어간다
            if !raiseWindow(pid: app.processIdentifier, containing: marker(for: session.id)) {
                raiseWindow(pid: app.processIdentifier, containing: session.projectName)
            }
            app.activate()
        }
    }

    // MARK: - 답장 보내기

    enum SendResult { case sent, pasted, failed(String) }

    /// 세션의 터미널에 글을 입력하고 Enter. 정확히 보낼 수 없는 앱은 창으로 이동해 붙여넣는다.
    static func send(_ rawText: String, to session: Session, completion: @escaping (SendResult) -> Void) {
        // 여러 줄은 중간에 제출되지 않도록 한 줄로
        let text = rawText.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = deliver(text, to: session)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func deliver(_ text: String, to session: Session) -> SendResult {
        let terminal = session.terminal
        if let pane = terminal.tmuxPane, let tmux = firstExisting(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]) {
            if run(tmux, ["send-keys", "-t", pane, "-l", text]) != nil, run(tmux, ["send-keys", "-t", pane, "Enter"]) != nil {
                return .sent
            }
        }
        switch terminal.hostBundleID {
        case "com.googlecode.iterm2":
            if let tty = terminal.tty.flatMap(safeTTY), osascript(itermWriteScript(tty, text)) == "ok" { return .sent }
        case "com.apple.Terminal":
            if let tty = terminal.tty.flatMap(safeTTY), osascript(appleTerminalWriteScript(tty, text)) == "ok" { return .sent }
        case "net.kovidgoyal.kitty":
            if let window = terminal.kittyWindow, let listen = terminal.kittyListen,
               let kitty = firstExisting(["/Applications/kitty.app/Contents/MacOS/kitty", "/opt/homebrew/bin/kitty"]),
               run(kitty, ["@", "--to", listen, "send-text", "--match", "id:\(window)", text + "\r"]) != nil {
                return .sent
            }
        case "com.github.wez.wezterm":
            if let pane = terminal.weztermPane,
               let wezterm = firstExisting(["/Applications/WezTerm.app/Contents/MacOS/wezterm", "/opt/homebrew/bin/wezterm"]),
               run(wezterm, ["cli", "send-text", "--pane-id", pane, "--no-paste", text]) != nil,
               run(wezterm, ["cli", "send-text", "--pane-id", pane, "--no-paste", "\r"]) != nil {
                return .sent
            }
        default:
            break
        }
        return pasteIntoFocusedWindow(text, session: session)
    }

    /// 창으로 이동 → 클립보드에 넣고 ⌘V → Enter → 클립보드 되돌리기
    private static func pasteIntoFocusedWindow(_ text: String, session: Session) -> SendResult {
        guard AXIsProcessTrusted() else { return .failed("이 터미널은 손쉬운 사용 권한이 있어야 답장할 수 있어요") }
        perform(session)
        Thread.sleep(forTimeInterval: 0.4)
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            postKey(9, flags: .maskCommand)  // V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                postKey(36, flags: [])  // Return
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let saved {
                        pasteboard.clearContents()
                        pasteboard.setString(saved, forType: .string)
                    }
                    semaphore.signal()
                }
            }
        }
        semaphore.wait()
        return .pasted
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func appleScriptString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func itermWriteScript(_ tty: String, _ text: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell s to write text "\(appleScriptString(text))"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    static func appleTerminalWriteScript(_ tty: String, _ text: String) -> String {
        """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        do script "\(appleScriptString(text))" in t
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    // MARK: - 지금 보고 있는 세션

    /// 맨 앞 터미널에서 지금 선택된 tty (iTerm2·Terminal만 정확히 알 수 있음)
    static func focusedTTY(bundleID: String) -> String? {
        switch bundleID {
        case "com.googlecode.iterm2":
            return osascript(#"tell application id "com.googlecode.iterm2" to tty of current session of current window"#)
        case "com.apple.Terminal":
            return osascript(#"tell application id "com.apple.Terminal" to tty of selected tab of front window"#)
        default:
            return nil
        }
    }

    /// 맨 앞 창의 제목 (손쉬운 사용 권한 필요)
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
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

    /// bridge의 TitleMarker와 같은 형식
    static func marker(for sessionID: String) -> String { "‹\(sessionID.prefix(8))›" }

    @discardableResult
    private static func raiseWindow(pid: pid_t, containing name: String) -> Bool {
        guard AXIsProcessTrusted(), !name.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            if let text = title as? String, text.localizedCaseInsensitiveContains(name) {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return true
            }
        }
        return false
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
