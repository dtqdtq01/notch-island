import Foundation
import NotchShared

// Claude Code 훅에서 실행됨: stdin JSON → 앱 소켓.
// PermissionRequest만 앱의 결정을 기다렸다가 stdout으로 돌려준다.
// 앱이 없거나 응답이 없으면 아무것도 출력하지 않고 exit 0 → Claude가 원래대로 터미널에서 묻는다.

signal(SIGPIPE, SIG_IGN)

var source = "claude"
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--source"), i + 1 < args.count {
    source = args[i + 1]
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty,
      let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let eventName = event["hook_event_name"] as? String
else { exit(0) }

guard let fd = UnixSocket.connect(to: NotchPaths.socket) else { exit(0) }

let envelope: [String: Any] = [
    "source": source,
    "ppid": Int(getppid()),
    "event": event,
]
guard UnixSocket.sendLine(fd, envelope) else { close(fd); exit(0) }

if eventName == "PermissionRequest" {
    // 앱이 결정을 보낼 때까지 블록. 사용자가 터미널에서 먼저 답하면 Claude가 이 프로세스를 정리한다.
    if let response = LineReader(fd: fd).readLine(), !response.isEmpty {
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

close(fd)
exit(0)
