import Foundation

/// Claude Code가 키체인에 저장한 로그인 토큰으로 Anthropic 사용량 API를 조회한다.
/// 상태줄 연동 없이도 5시간/7일 한도를 보여주기 위한 것. 토큰은 이 API에만 보내고, 갱신은 하지 않는다.
final class ClaudeUsageFetcher: ObservableObject {
    enum Status: Error, Equatable {
        case off, loading, ok(Date), noCredentials, expired, rateLimited, failed(String)

        var text: String {
            switch self {
            case .off: return "꺼짐"
            case .loading: return "불러오는 중…"
            case .ok(let date): return "갱신됨 · \(date.formatted(date: .omitted, time: .shortened))"
            case .noCredentials: return "Claude Code 로그인 정보를 찾지 못했어요 (키체인 접근을 거부했거나 로그인 전)"
            case .expired: return "토큰이 만료됐어요 — Claude Code를 한 번 실행하면 다시 받아요"
            case .rateLimited: return "요청이 많아 잠시 쉬는 중 (15분 뒤 재시도)"
            case .failed(let reason): return "실패: \(reason)"
            }
        }
    }

    @Published private(set) var status: Status = .off

    private let prefs: Prefs
    private let store: SessionStore
    private var timer: Timer?
    private var token: (value: String, expiresAt: Date?)?
    private var pausedUntil: Date?
    private var inFlight = false
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let interval: TimeInterval = 300

    init(prefs: Prefs, store: SessionStore) {
        self.prefs = prefs
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private var lastFetch: Date?

    private func tick() {
        guard prefs.useClaudeSignInForUsage else {
            if status != .off { status = .off }
            token = nil
            return
        }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < Self.interval { return }
        refresh()
    }

    func refresh() {
        guard prefs.useClaudeSignInForUsage, !inFlight else { return }
        if let pausedUntil, pausedUntil > Date() { return }
        inFlight = true
        status = .loading
        DispatchQueue.global(qos: .utility).async {
            let result = self.fetch()
            DispatchQueue.main.async {
                self.inFlight = false
                self.lastFetch = Date()
                switch result {
                case .success(let limits):
                    self.store.applyRateLimits(limits)
                    self.status = .ok(Date())
                case .failure(let status):
                    self.status = status
                }
            }
        }
    }

    // MARK: - 네트워크


    private func fetch() -> Result<RateLimits, Status> {
        if token == nil || (token?.expiresAt.map { $0 < Date() } ?? false) {
            token = Self.readKeychainToken()
        }
        guard let token else { return .failure(.noCredentials) }
        if let expiry = token.expiresAt, expiry < Date() { self.token = nil; return .failure(.expired) }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("notch-island", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var output: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: request) { output = ($0, $1, $2); semaphore.signal() }.resume()
        semaphore.wait()

        if let error = output.2 { return .failure(.failed(error.localizedDescription)) }
        let code = (output.1 as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403:
            self.token = nil
            return .failure(.expired)
        case 429:
            pausedUntil = Date().addingTimeInterval(900)
            return .failure(.rateLimited)
        default:
            return .failure(.failed("HTTP \(code)"))
        }
        guard let data = output.0, let limits = Self.parse(data) else { return .failure(.failed("응답 형식이 달라요")) }
        return .success(limits)
    }

    /// 응답: {"five_hour": {"utilization": 3, "resets_at": "2026-10-12T07:00:00.429331+00:00"}, "seven_day": {...}}
    static func parse(_ data: Data) -> RateLimits? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ key: String) -> RateWindow? {
            guard let entry = root[key] as? [String: Any],
                  let used = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return RateWindow(usedPercent: used, resetsAt: (entry["resets_at"] as? String).flatMap(parseDate))
        }
        let limits = RateLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
        return limits.fiveHour == nil && limits.sevenDay == nil ? nil : limits
    }

    /// 마이크로초까지 붙은 ISO 8601도 읽는다
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    // MARK: - 키체인

    /// `security` 도구로 Claude Code의 키체인 항목을 읽는다 (처음엔 macOS가 허용 여부를 묻는다)
    private static func readKeychainToken() -> (value: String, expiresAt: Date?)? {
        guard let raw = TerminalJumper.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
              let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty
        else { return nil }
        let expiry = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (access, expiry)
    }
}
