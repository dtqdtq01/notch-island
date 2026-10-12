import Carbon.HIToolbox
import NotchShared
import Foundation

enum SoundCategory: String, CaseIterable, Identifiable {
    case sessionStart, taskAcknowledge, inputRequired, taskComplete, taskError
    case idleReminder, resourceLimit, usageWarning, userSpam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionStart: return "세션 시작"
        case .taskAcknowledge: return "프롬프트 전송"
        case .inputRequired: return "승인 필요"
        case .taskComplete: return "작업 완료"
        case .taskError: return "작업 오류"
        case .idleReminder: return "입력 대기"
        case .resourceLimit: return "컨텍스트 한도"
        case .usageWarning: return "사용량 경고"
        case .userSpam: return "연타 감지"
        }
    }

    var detail: String {
        switch self {
        case .sessionStart: return "새 Claude / Codex 세션"
        case .taskAcknowledge: return "프롬프트를 보냈을 때"
        case .inputRequired: return "권한 요청이나 질문이 왔을 때"
        case .taskComplete: return "AI가 턴을 마쳤을 때"
        case .taskError: return "턴 실패나 API 오류"
        case .idleReminder: return "AI가 입력을 기다릴 때"
        case .resourceLimit: return "컨텍스트 자동 압축 시작"
        case .usageWarning: return "사용 한도 경고선 넘음"
        case .userSpam: return "10초 안에 프롬프트 3번 이상"
        }
    }

    var defaultSound: String {
        switch self {
        case .sessionStart: return "Bottle"
        case .taskAcknowledge: return "Tink"
        case .inputRequired: return "Glass"
        case .taskComplete: return "Hero"
        case .taskError: return "Basso"
        case .idleReminder: return "Purr"
        case .resourceLimit: return "Funk"
        case .usageWarning: return "Sosumi"
        case .userSpam: return "Frog"
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .inputRequired, .taskComplete, .taskError, .usageWarning: return true
        default: return false
        }
    }
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon 수식키 플래그
    var label: String

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + label
    }

    var encoded: String { "\(keyCode)|\(modifiers)|\(label)" }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, let key = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: key, modifiers: mods, label: parts[2])
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case switcher, approve, deny, jumpLatest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .switcher: return "세션 스위처 열기"
        case .approve: return "맨 앞 요청 허용"
        case .deny: return "맨 앞 요청 거부"
        case .jumpLatest: return "가장 급한 세션으로 점프"
        }
    }

    var defaultShortcut: Shortcut {
        let mods = UInt32(cmdKey | optionKey)
        switch self {
        case .switcher: return Shortcut(keyCode: UInt32(kVK_ANSI_I), modifiers: mods, label: "I")
        case .approve: return Shortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: mods, label: "Y")
        case .deny: return Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: mods, label: "N")
        case .jumpLatest: return Shortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: mods, label: "J")
        }
    }
}

/// UserDefaults에 바로 저장되는 앱 설정
final class Prefs: ObservableObject {
    static let shared = Prefs()

    private static func load<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }
    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    // 표시
    @Published var expandOnHover = Prefs.load("expandOnHover", true) { didSet { save("expandOnHover", expandOnHover) } }
    @Published var hideInFullscreen = Prefs.load("hideInFullscreen", true) { didSet { save("hideInFullscreen", hideInFullscreen) } }
    @Published var autoHideWhenIdle = Prefs.load("autoHideWhenIdle", false) { didSet { save("autoHideWhenIdle", autoHideWhenIdle) } }
    @Published var autoExpandOnRequest = Prefs.load("autoExpandOnRequest", true) { didSet { save("autoExpandOnRequest", autoExpandOnRequest) } }
    @Published var autoExpandOnComplete = Prefs.load("autoExpandOnComplete", true) { didSet { save("autoExpandOnComplete", autoExpandOnComplete) } }
    @Published var completionDwell = Prefs.load("completionDwell", 4.0) { didSet { save("completionDwell", completionDwell) } }
    @Published var showModel = Prefs.load("showModel", true) { didSet { save("showModel", showModel) } }
    @Published var showSubagents = Prefs.load("showSubagents", true) { didSet { save("showSubagents", showSubagents) } }
    @Published var showUsage = Prefs.load("showUsage", true) { didSet { save("showUsage", showUsage) } }
    @Published var disableClickToJump = Prefs.load("disableClickToJump", false) { didSet { save("disableClickToJump", disableClickToJump) } }

    // 사용량 경고
    @Published var usageAlert = Prefs.load("usageAlert", true) { didSet { save("usageAlert", usageAlert) } }
    @Published var usageThreshold = Prefs.load("usageThreshold", 80.0) { didSet { save("usageThreshold", usageThreshold) } }

    // 사운드
    @Published var soundsEnabled = Prefs.load("soundsEnabled", true) { didSet { save("soundsEnabled", soundsEnabled) } }
    @Published var volume = Prefs.load("volume", 0.6) { didSet { save("volume", volume) } }
    @Published var soundOn: [String: Bool] = Prefs.load("soundOn", [:]) { didSet { save("soundOn", soundOn) } }
    @Published var soundName: [String: String] = Prefs.load("soundName", [:]) { didSet { save("soundName", soundName) } }
    @Published var quietHoursEnabled = Prefs.load("quietHoursEnabled", false) { didSet { save("quietHoursEnabled", quietHoursEnabled) } }
    @Published var quietStart = Prefs.load("quietStart", 23 * 60) { didSet { save("quietStart", quietStart) } }  // 자정부터 분
    @Published var quietEnd = Prefs.load("quietEnd", 8 * 60) { didSet { save("quietEnd", quietEnd) } }

    // 숨김 규칙 (세션 입장 필터)
    static let defaultBlockedLaunchers = ["com.steipete.codexbar"]
    @Published var blockedLaunchers: [String] = Prefs.load("blockedLaunchers", Prefs.defaultBlockedLaunchers) { didSet { save("blockedLaunchers", blockedLaunchers) } }
    @Published var silencedDirectories: [String] = Prefs.load("silencedDirectories", []) { didSet { save("silencedDirectories", silencedDirectories) } }
    @Published var silencedPromptPrefixes: [String] = Prefs.load("silencedPromptPrefixes", []) { didSet { save("silencedPromptPrefixes", silencedPromptPrefixes) } }
    @Published var silencedPromptContains: [String] = Prefs.load("silencedPromptContains", []) { didSet { save("silencedPromptContains", silencedPromptContains) } }
    @Published var hideSessionsWithoutTTY = Prefs.load("hideSessionsWithoutTTY", false) { didSet { save("hideSessionsWithoutTTY", hideSessionsWithoutTTY) } }

    // 방해 금지
    @Published var quietDuringScreenShare = Prefs.load("quietDuringScreenShare", true) { didSet { save("quietDuringScreenShare", quietDuringScreenShare) } }
    @Published var quietDuringFocus = Prefs.load("quietDuringFocus", true) { didSet { save("quietDuringFocus", quietDuringFocus) } }

    // 연동 유지
    @Published var autoRepairHooks = Prefs.load("autoRepairHooks", true) { didSet { save("autoRepairHooks", autoRepairHooks) } }
    /// 사용자가 앱에서 설치한 연동 (claude, codex, statusline) — 이것만 자동 복구한다
    @Published var managedIntegrations: [String] = Prefs.load("managedIntegrations", []) { didSet { save("managedIntegrations", managedIntegrations) } }
    @Published var titleMarkerEnabled = Prefs.load("titleMarkerEnabled", true) {
        didSet {
            save("titleMarkerEnabled", titleMarkerEnabled)
            Prefs.syncTitleMarkerFlag(titleMarkerEnabled)
        }
    }

    /// bridge는 UserDefaults를 못 읽으므로 파일 하나로 끔/켬을 알린다
    static func syncTitleMarkerFlag(_ enabled: Bool) {
        let flag = NotchPaths.titleMarkerDisabled
        if enabled {
            try? FileManager.default.removeItem(at: flag)
        } else {
            try? FileManager.default.createDirectory(at: NotchPaths.root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: Data())
        }
    }

    func setManaged(_ id: String, _ managed: Bool) {
        if managed {
            if !managedIntegrations.contains(id) { managedIntegrations.append(id) }
        } else {
            managedIntegrations.removeAll { $0 == id }
        }
    }

    // 단축키
    @Published var shortcutsEnabled = Prefs.load("shortcutsEnabled", true) { didSet { save("shortcutsEnabled", shortcutsEnabled) } }
    @Published var shortcuts: [String: String] = Prefs.load("shortcuts", [:]) { didSet { save("shortcuts", shortcuts) } }

    func isSoundOn(_ category: SoundCategory) -> Bool { soundOn[category.rawValue] ?? category.defaultEnabled }
    func sound(for category: SoundCategory) -> String { soundName[category.rawValue] ?? category.defaultSound }

    func shortcut(for action: HotkeyAction) -> Shortcut? {
        guard let encoded = shortcuts[action.rawValue] else { return action.defaultShortcut }
        return encoded.isEmpty ? nil : Shortcut(encoded: encoded)
    }

    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        shortcuts[action.rawValue] = shortcut?.encoded ?? ""
    }

    func inQuietHours(_ date: Date = Date()) -> Bool {
        guard quietHoursEnabled else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if quietStart <= quietEnd { return now >= quietStart && now < quietEnd }
        return now >= quietStart || now < quietEnd  // 자정을 넘는 구간
    }
}
