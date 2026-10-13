import Foundation
import NotchShared

/// PermissionRequest 연결을 붙잡고 있다가 결정을 한 번만 써 준다.
final class Responder {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false

    init(fd: Int32) { self.fd = fd }

    /// 결정 전송. 이미 응답했거나 연결이 끊겼으면 false.
    @discardableResult
    func respond(_ object: Any) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        let ok = UnixSocket.sendLine(fd, object)
        shutdown(fd, SHUT_WR)
        return ok
    }

    func markClosed() {
        lock.lock(); finished = true; lock.unlock()
    }

    /// 응답 없이 연결을 닫음 → bridge가 아무것도 출력하지 않아 에이전트가 터미널에서 묻는다.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        shutdown(fd, SHUT_RDWR)
    }
}

/// ~/.notch-island/run/notch.sock 에서 bridge 연결을 받는다.
/// 일반 이벤트는 큐에서 짧게 처리하고, 결정을 오래 기다리는 PermissionRequest만 전용 스레드를 쓴다.
/// (연결마다 Thread를 만들면 스레드마다 생기는 run loop 메모리가 해제되지 않고 쌓인다)
final class SocketServer {
    enum StartError: Error { case alreadyRunning, socket(String) }

    private let path = NotchPaths.socket
    private var listenFD: Int32 = -1
    private let store: SessionStore
    private let queue = DispatchQueue(label: "notch.socket", qos: .userInitiated, attributes: .concurrent)

    init(store: SessionStore) { self.store = store }

    func start() throws {
        try FileManager.default.createDirectory(
            at: NotchPaths.runDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // 이미 다른 인스턴스가 듣고 있으면 중단
        if let probe = UnixSocket.connect(to: path) {
            close(probe)
            throw StartError.alreadyRunning
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket("socket() failed") }
        var addr = sockaddr_un()
        guard UnixSocket.fill(&addr, path: path) else { throw StartError.socket("path too long") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw StartError.socket("bind() errno \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { close(fd); throw StartError.socket("listen() errno \(errno)") }
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "notch.accept"
        thread.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if listenFD < 0 { return }
                continue
            }
            UnixSocket.disableSigpipe(client)
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        // bridge는 연결하자마자 한 줄을 보낸다. 아무것도 안 오면 큐 스레드를 오래 붙잡지 않는다.
        Self.setReadTimeout(client, seconds: 5)
        let reader = LineReader(fd: client)
        guard let line = reader.readLine(),
              let envelope = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let event = envelope["event"] as? [String: Any]
        else { close(client); return }

        let source = envelope["source"] as? String ?? "claude"
        let terminal = envelope["terminal"] as? [String: Any]
        guard event["hook_event_name"] as? String == "PermissionRequest" else {
            close(client)
            DispatchQueue.main.async { self.store.ingest(event, source: source, terminal: terminal) }
            return
        }

        let id = UUID()
        let responder = Responder(fd: client)
        DispatchQueue.main.async {
            self.store.ingestPermission(event, source: source, terminal: terminal, id: id, responder: responder)
        }
        // 결정까지 몇 시간 걸릴 수 있어 공용 큐 스레드를 붙잡지 않도록 전용 스레드에서 기다린다
        Self.setReadTimeout(client, seconds: 0)
        let thread = Thread { [weak self] in
            // bridge가 응답을 받고 끝나거나, Claude가 bridge를 죽이면 EOF가 온다.
            while reader.readLine() != nil {}
            responder.markClosed()
            close(client)
            DispatchQueue.main.async { self?.store.permissionConnectionClosed(id) }
        }
        thread.start()
    }

    /// 0이면 제한 없음
    private static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
