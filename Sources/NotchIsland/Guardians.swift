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
        timer?.tolerance = 1
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
    /// 마지막으로 확인한 설정 파일 상태. 그대로면 JSON을 다시 읽지 않는다.
    private var checkedSignature: [String]?

    init(prefs: Prefs, store: SessionStore) {
        self.prefs = prefs
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 1.5
    }

    func check() {
        guard prefs.autoRepairHooks, !gaveUp else { return }
        let signature = Self.signature(prefs.managedIntegrations)
        guard signature != checkedSignature else { return }
        defer { checkedSignature = Self.signature(prefs.managedIntegrations) }
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

    private static func signature(_ ids: [String]) -> [String] {
        let files = Integrations.Agent.allCases.map(\.configFile)
        return ids.sorted() + files.map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0):\(values?.fileSize ?? -1)"
        }
    }

    /// 사용자가 연동 화면에서 다시 손대면 자동 복구 재개
    func reset() {
        checkedSignature = nil
        gaveUp = false
        repairs.removeAll()
    }
}

/// 자리를 비웠다 돌아왔을 때 기다리는 세션이 있으면 다시 알려준다.
final class IdleWatcher {
    private let prefs: Prefs
    private let store: SessionStore
    private let onSound: (SoundCategory) -> Void
    private var timer: Timer?
    private var awaySince: Date?

    init(prefs: Prefs, store: SessionStore, onSound: @escaping (SoundCategory) -> Void) {
        self.prefs = prefs
        self.store = store
        self.onSound = onSound
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 1.5
    }

    /// 마지막 키보드·마우스 입력 이후 초
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func check(idle: TimeInterval = IdleWatcher.idleSeconds, now: Date = Date()) {
        guard prefs.idleReminder else { awaySince = nil; return }
        if idle >= prefs.idleMinutes * 60 {
            if awaySince == nil { awaySince = now.addingTimeInterval(-idle) }
            return
        }
        guard let since = awaySince, idle < 10 else { return }
        awaySince = nil
        let waiting = store.sessions.values.filter { session in
            switch session.status {
            case .waitingApproval, .waitingInput: return true
            case .done, .error: return session.updatedAt >= since
            default: return false
            }
        }
        guard !waiting.isEmpty else { return }
        let names = waiting.prefix(3).map(\.projectName).joined(separator: ", ")
        store.notify("자리 비운 사이 \(waiting.count)개 세션이 기다려요", names)
        onSound(.idleReminder)
    }
}

/// 사용자가 어떤 세션의 터미널을 보고 있는지 알아내 그 세션을 읽음 처리한다.
/// 앱 전환과 (손쉬운 사용 권한이 있으면) 창 포커스·제목 변화를 듣고, 읽지 않은 세션이 있을 때만 확인한다.
final class FocusWatcher {
    private let store: SessionStore
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "notch.focus", qos: .utility)

    init(store: SessionStore) {
        self.store = store
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.observe(app)
            self?.schedule()
        }
        observe(NSWorkspace.shared.frontmostApplication)
    }

    /// 창 포커스·제목이 바뀌면 다시 확인 (탭 전환도 제목이 바뀌어서 잡힌다)
    private func observe(_ app: NSRunningApplication?) {
        guard let app, AXIsProcessTrusted(), app.processIdentifier != observedPID else { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = app.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue().schedule()
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private var lastCheck = Date.distantPast

    /// 작업 중인 에이전트는 창 제목을 계속 바꾸므로, 확인은 최대 1.5초에 한 번만
    func schedule() {
        guard store.hasUnread, pending == nil else { return }
        let wait = max(0.35, 1.5 - Date().timeIntervalSince(lastCheck))
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.lastCheck = Date()
            self?.check()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func check() {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return }
        let candidates = store.sessions.values.filter { $0.unread && $0.terminal.hostBundleID == bundle }
        guard !candidates.isEmpty else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            let tty = TerminalJumper.focusedTTY(bundleID: bundle)
            let title = TerminalJumper.focusedWindowTitle(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                for session in Self.matches(candidates, tty: tty, title: title) { self.store.markSeen(session.id) }
            }
        }
    }

    /// 보고 있는 창과 맞는 세션 고르기: tty → 제목 속 세션 표식 → 제목 속 프로젝트 이름(한 개일 때만)
    static func matches(_ candidates: [Session], tty: String?, title: String?) -> [Session] {
        if let tty, !tty.isEmpty {
            let byTTY = candidates.filter { $0.terminal.tty == tty && $0.terminal.tmuxPane == nil }
            if !byTTY.isEmpty { return byTTY }
        }
        guard let title, !title.isEmpty else { return [] }
        let byMarker = candidates.filter { title.contains(TerminalJumper.marker(for: $0.id)) }
        if !byMarker.isEmpty { return byMarker }
        let byName = candidates.filter { title.localizedCaseInsensitiveContains($0.projectName) }
        return byName.count == 1 ? byName : []
    }
}
