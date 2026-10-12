import Foundation
import Testing
@testable import NotchIsland

/// NOTCH_TMUX_PANE=<pane> 일 때만: 실제 tmux 패널로 답장을 보내 본다
@Suite struct ReplyLiveTests {
    @Test func sendsToTmuxPane() async throws {
        guard let pane = ProcessInfo.processInfo.environment["NOTCH_TMUX_PANE"] else { return }
        var session = Session(id: "live", source: "claude", cwd: "/tmp")
        session.terminal = TerminalInfo(["TMUX_PANE": pane, "TMUX": "x", "tty": "/dev/ttys999"])
        let result: TerminalJumper.SendResult = await withCheckedContinuation { continuation in
            TerminalJumper.send("안녕 \"따옴표\" \\ 백슬래시\n둘째 줄", to: session) { continuation.resume(returning: $0) }
        }
        guard case .sent = result else { Issue.record("보내지 못함: \(result)"); return }
    }
}

@Suite struct ReplyScriptTests {
    /// 따옴표·백슬래시가 섞여도 AppleScript가 문법 오류 없이 컴파일되는지 (실행은 하지 않음)
    @Test func scriptsCompileWithTrickyText() throws {
        let text = #"say "hi" \ and \"done\""#
        for script in [TerminalJumper.itermWriteScript("/dev/ttys999", text), TerminalJumper.appleTerminalWriteScript("/dev/ttys999", text)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", FileManager.default.temporaryDirectory.appendingPathComponent("notch-\(UUID().uuidString).scpt").path, "-e", script]
            let err = Pipe()
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(process.terminationStatus == 0, "\(message)")
        }
    }
}
