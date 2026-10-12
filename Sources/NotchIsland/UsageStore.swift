import Foundation
import NotchShared

struct UsageTotals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0
    var messages = 0

    var tokens: Int { input + output + cacheRead + cacheWrite }

    static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(
            input: a.input + b.input, output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
            cost: a.cost + b.cost, messages: a.messages + b.messages)
    }
}

struct DayUsage: Identifiable {
    var id: Date { day }
    let day: Date
    let totals: UsageTotals
}

struct UsageSummary {
    var total = UsageTotals()
    var byModel: [(model: String, totals: UsageTotals)] = []
    var byDay: [DayUsage] = []
    var sessions = 0
}

/// 모델 가격 (US$ / 100만 토큰). LiteLLM 공개 가격표를 받아 쓰고, 못 받으면 내장값.
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double

    static func fallback(_ model: String) -> ModelPrice? {
        let m = model.lowercased()
        func price(_ input: Double, _ output: Double) -> ModelPrice {
            ModelPrice(input: input, output: output, cacheRead: input * 0.1, cacheWrite: input * 1.25)
        }
        if m.contains("opus-4-1") || m.contains("opus-4-0") || m.contains("opus-4-2025") || m.contains("3-opus") { return price(15, 75) }
        if m.contains("opus") { return price(5, 25) }
        if m.contains("sonnet") { return price(3, 15) }
        if m.contains("haiku-3-5") || m.contains("3-5-haiku") { return price(0.8, 4) }
        if m.contains("haiku-3") || m.contains("3-haiku") { return price(0.25, 1.25) }
        if m.contains("haiku") { return price(1, 5) }
        return nil
    }
}

/// ~/.claude/projects/**/*.jsonl 의 토큰 사용 기록을 집계한다 (로컬 추정치).
final class UsageStore: ObservableObject {
    @Published private(set) var days: [Date: [String: UsageTotals]] = [:]
    @Published private(set) var sessionDays: [Date: Set<String>] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?

    private var prices: [String: ModelPrice] = [:]
    private let queue = DispatchQueue(label: "notch.usage", qos: .utility)
    private static let pricingURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static var pricingCache: URL { NotchPaths.cacheDir.appendingPathComponent("pricing.json") }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async {
            self.loadPrices()
            let (days, sessionDays) = self.scan()
            DispatchQueue.main.async {
                self.days = days
                self.sessionDays = sessionDays
                self.scanning = false
                self.lastScan = Date()
            }
        }
    }

    /// days: nil이면 전체, 0이면 오늘
    func summary(days period: Int?) -> UsageSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = period.flatMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var summary = UsageSummary()
        var models: [String: UsageTotals] = [:]
        var sessions = Set<String>()
        for (day, perModel) in days where start == nil || day >= start! {
            var dayTotal = UsageTotals()
            for (model, totals) in perModel {
                models[model, default: UsageTotals()] = models[model, default: UsageTotals()] + totals
                dayTotal = dayTotal + totals
            }
            summary.total = summary.total + dayTotal
            summary.byDay.append(DayUsage(day: day, totals: dayTotal))
            sessions.formUnion(sessionDays[day] ?? [])
        }
        summary.byDay.sort { $0.day < $1.day }
        summary.byModel = models.map { ($0.key, $0.value) }.sorted { $0.totals.cost > $1.totals.cost }
        summary.sessions = sessions.count
        return summary
    }

    // MARK: - 스캔

    private func scan() -> ([Date: [String: UsageTotals]], [Date: Set<String>]) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return ([:], [:]) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let calendar = Calendar.current
        var days: [Date: [String: UsageTotals]] = [:]
        var sessionDays: [Date: Set<String>] = [:]
        var seen = Set<String>()
        let usageMarker = Data("\"usage\"".utf8)

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            for line in data.split(separator: 0x0A) where line.range(of: usageMarker) != nil {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let stamp = object["timestamp"] as? String,
                      let date = iso.date(from: stamp)
                else { continue }
                // 스트리밍 조각이 같은 메시지로 여러 줄 기록되므로 중복 제거
                let key = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? "")"
                if key != "|" {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                let model = message["model"] as? String ?? "unknown"
                if model == "<synthetic>" { continue }
                func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                var totals = UsageTotals(
                    input: int("input_tokens"), output: int("output_tokens"),
                    cacheRead: int("cache_read_input_tokens"), cacheWrite: int("cache_creation_input_tokens"),
                    messages: 1)
                if let price = price(for: model) {
                    totals.cost = (Double(totals.input) * price.input + Double(totals.output) * price.output
                        + Double(totals.cacheRead) * price.cacheRead + Double(totals.cacheWrite) * price.cacheWrite) / 1_000_000
                }
                let day = calendar.startOfDay(for: date)
                days[day, default: [:]][model, default: UsageTotals()] = days[day, default: [:]][model, default: UsageTotals()] + totals
                if let session = object["sessionId"] as? String { sessionDays[day, default: []].insert(session) }
            }
        }
        return (days, sessionDays)
    }

    // MARK: - 가격표

    private func price(for model: String) -> ModelPrice? {
        if let exact = prices[model] { return exact }
        let trimmed = model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return prices[trimmed] ?? ModelPrice.fallback(model)
    }

    private func loadPrices() {
        let cache = Self.pricingCache
        let fresh = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            .map { Date().timeIntervalSince($0) < 24 * 3600 } ?? false
        if !fresh, let data = try? Data(contentsOf: Self.pricingURL) {
            try? FileManager.default.createDirectory(at: NotchPaths.cacheDir, withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
        guard let data = try? Data(contentsOf: cache),
              let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var result: [String: ModelPrice] = [:]
        for (name, value) in table {
            guard let entry = value as? [String: Any],
                  let input = (entry["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let output = (entry["output_cost_per_token"] as? NSNumber)?.doubleValue else { continue }
            let read = (entry["cache_read_input_token_cost"] as? NSNumber)?.doubleValue ?? input * 0.1
            let write = (entry["cache_creation_input_token_cost"] as? NSNumber)?.doubleValue ?? input * 1.25
            result[name] = ModelPrice(input: input * 1e6, output: output * 1e6, cacheRead: read * 1e6, cacheWrite: write * 1e6)
        }
        prices = result
    }
}
