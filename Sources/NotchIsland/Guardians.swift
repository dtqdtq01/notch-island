import AppKit
import Foundation

/// 화면 공유·녹화, 집중 모드처럼 노치가 튀어나오면 곤란한 상황을 감지한다.
final class QuietMonitor: ObservableObject {
    @Published private(set) var screenShared = false
    @Published private(set) var focusActive = false
    /// 집중 모드 상태 파일을 읽을 수 있는지 (전체 디스크 접근 권한 필요)
    @Published private(set) var focusReadable = false

    private let prefs: Prefs
    private var timer: Timer?
    private typealias WatcherFn = @convention(c) () -> Bool
    private let screenWatcher: WatcherFn? = {
        // 공개 API가 없어 SkyLight의 화면 감시자 확인 함수를 쓴다. 없으면 감지 안 함.
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSIsScreenWatcherPresent") ?? dlsym(handle, "SLSIsScreenWatcherPresent")
        else { return nil }
        return unsafeBitCast(symbol, to: WatcherFn.self)
    }()
    private static var assertionsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }

    init(prefs: Prefs) {
        self.prefs = prefs
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var isQuiet: Bool {
        (prefs.quietDuringScreenShare && screenShared) || (prefs.quietDuringFocus && focusActive)
    }

    var reason: String? {
        if prefs.quietDuringScreenShare && screenShared { return "화면 공유·녹화 중" }
        if prefs.quietDuringFocus && focusActive { return "집중 모드" }
        return nil
    }

    func refresh() {
        let shared = screenWatcher?() ?? false
        if shared != screenShared { screenShared = shared }

        // 집중 모드: 활성 assertion 레코드가 하나라도 있으면 켜진 것
        let data = try? Data(contentsOf: Self.assertionsFile)
        if (data != nil) != focusReadable { focusReadable = data != nil }
        var active = false
        if let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for entry in root["data"] as? [[String: Any]] ?? [] {
                if let records = entry["storeAssertionRecords"] as? [Any], !records.isEmpty { active = true }
            }
        }
        if active != focusActive { focusActive = active }
    }
}

/// 다른 도구가 설정 파일을 덮어써서 훅이 사라지면 다시 설치한다.
final class HookWatcher {
    private let prefs: Prefs
    private let store: SessionStore
    private var timer: Timer?
    private var repairs: [Date] = []
    private var gaveUp = false

    init(prefs: Prefs, store: SessionStore) {
        self.prefs = prefs
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        guard prefs.autoRepairHooks, !gaveUp else { return }
        var restored: [String] = []
        for id in prefs.managedIntegrations {
            do {
                if id == "statusline" {
                    if !Integrations.isStatusLineInstalled {
                        try Integrations.installStatusLine()
                        restored.append("Claude 상태줄")
                    }
                } else if let agent = Integrations.Agent(rawValue: id), !Integrations.isInstalled(agent) {
                    try Integrations.install(agent)
                    restored.append(agent.title)
                }
            } catch {
                NSLog("NotchIsland: 훅 복구 실패 \(id): \(error)")
            }
        }
        guard !restored.isEmpty else { return }

        let now = Date()
        repairs = repairs.filter { now.timeIntervalSince($0) < 600 } + [now]
        if repairs.count > 3 {
            // 다른 도구와 계속 싸우지 않는다
            gaveUp = true
            store.notify("훅이 계속 지워지고 있어요", "설정 → 연동에서 확인해 주세요. 자동 복구를 멈췄어요.")
        } else {
            store.notify("훅을 복구했어요", restored.joined(separator: ", ") + " 설정을 다른 도구가 바꿨어요")
        }
    }

    /// 사용자가 연동 화면에서 다시 손대면 자동 복구 재개
    func reset() {
        gaveUp = false
        repairs.removeAll()
    }
}
