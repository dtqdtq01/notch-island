import Foundation

/// 앱과 bridge가 공유하는 경로. 프로토콜은 "JSON 한 줄 + \n".
public enum NotchPaths {
    /// 테스트용 홈 디렉터리 대체
    public static var homeOverride: URL?
    public static var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }
    public static var root: URL { home.appendingPathComponent(".notch-island") }
    public static var runDir: URL { root.appendingPathComponent("run") }
    public static var socket: String { runDir.appendingPathComponent("notch.sock").path }
}

public enum UnixSocket {
    @discardableResult
    public static func fill(_ addr: inout sockaddr_un, path: String) -> Bool {
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return true
    }

    public static func disableSigpipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 앱 소켓에 연결. 앱이 안 떠 있으면 nil.
    public static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        guard fill(&addr, path: path) else { close(fd); return nil }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        disableSigpipe(fd)
        return fd
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, pointer, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                left -= n
                pointer = pointer.advanced(by: n)
            }
            return true
        }
    }

    /// JSON 객체를 한 줄로 직렬화해서 보냄.
    @discardableResult
    public static func sendLine(_ fd: Int32, _ object: Any) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        return writeAll(fd, data)
    }
}

/// 개행 단위로 읽는 버퍼드 리더. EOF면 nil.
public final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    public init(fd: Int32) { self.fd = fd }

    public func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if buffer.isEmpty { return nil }
            let rest = buffer
            buffer = Data()
            return rest
        }
    }
}

public extension NotchPaths {
    static var binDir: URL { root.appendingPathComponent("bin") }
    static var bridge: String { binDir.appendingPathComponent("notch-bridge").path }
    static var cacheDir: URL { root.appendingPathComponent("cache") }
    static var soundsDir: URL { root.appendingPathComponent("sounds") }
    static var rateLimitsCache: URL { cacheDir.appendingPathComponent("rate-limits.json") }
    /// 연동 전에 쓰던 statusLine 명령. bridge가 이어서 실행해 준다.
    static var previousStatusLine: URL { root.appendingPathComponent("statusline-prev") }
    /// 이 파일이 있으면 bridge가 창 제목 표식을 쓰지 않는다
    static var titleMarkerDisabled: URL { root.appendingPathComponent("title-marker-disabled") }
}
