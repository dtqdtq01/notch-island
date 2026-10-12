import AppKit
import ApplicationServices
import NotchShared
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let prefs: Prefs
    private let usage: UsageStore
    private let sounds: SoundPlayer
    private let quiet: QuietMonitor
    private let claudeUsage: ClaudeUsageFetcher
    private let onShortcutsChanged: () -> Void
    private let onIntegrationsChanged: () -> Void

    init(prefs: Prefs, usage: UsageStore, sounds: SoundPlayer, quiet: QuietMonitor, claudeUsage: ClaudeUsageFetcher,
         onShortcutsChanged: @escaping () -> Void, onIntegrationsChanged: @escaping () -> Void) {
        self.claudeUsage = claudeUsage
        self.prefs = prefs
        self.usage = usage
        self.sounds = sounds
        self.quiet = quiet
        self.onShortcutsChanged = onShortcutsChanged
        self.onIntegrationsChanged = onIntegrationsChanged
    }

    func show(tab: SettingsTab = .general) {
        if window == nil {
            let view = SettingsView(
                prefs: prefs, usage: usage, sounds: sounds, quiet: quiet, claudeUsage: claudeUsage,
                initialTab: tab, onShortcutsChanged: onShortcutsChanged,
                onIntegrationsChanged: onIntegrationsChanged)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Notch Island 설정"
            window.contentViewController = NSHostingController(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, silence, sound, shortcuts, usage, integrations, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "일반"
        case .silence: return "숨김"
        case .sound: return "사운드"
        case .shortcuts: return "단축키"
        case .usage: return "사용량"
        case .integrations: return "연동"
        case .about: return "정보"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .silence: return "eye.slash"
        case .sound: return "speaker.wave.2"
        case .shortcuts: return "command"
        case .usage: return "chart.bar"
        case .integrations: return "puzzlepiece.extension"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var usage: UsageStore
    let sounds: SoundPlayer
    @ObservedObject var quiet: QuietMonitor
    @ObservedObject var claudeUsage: ClaudeUsageFetcher
    @State var initialTab: SettingsTab
    let onShortcutsChanged: () -> Void
    let onIntegrationsChanged: () -> Void

    var body: some View {
        TabView(selection: $initialTab) {
            ForEach(SettingsTab.allCases) { tab in
                content(tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .tag(tab)
            }
        }
        .frame(width: 640, height: 520)
    }

    @ViewBuilder
    private func content(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings(prefs: prefs, quiet: quiet, claudeUsage: claudeUsage)
        case .silence: SilenceSettings(prefs: prefs)
        case .sound: SoundSettings(prefs: prefs, sounds: sounds)
        case .shortcuts: ShortcutSettings(prefs: prefs, onChanged: onShortcutsChanged)
        case .usage: UsageDashboard(usage: usage)
        case .integrations: IntegrationSettings(prefs: prefs, onChanged: onIntegrationsChanged)
        case .about: AboutView()
        }
    }
}

// MARK: - 일반

struct GeneralSettings: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var quiet: QuietMonitor
    @ObservedObject var claudeUsage: ClaudeUsageFetcher
    @State private var launchAtLogin = Integrations.launchAtLogin
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("동작") {
                Toggle("마우스를 올리면 노치 펼치기", isOn: $prefs.expandOnHover)
                Toggle("권한 요청·질문이 오면 자동으로 펼치기", isOn: $prefs.autoExpandOnRequest)
                Toggle("작업 완료 알림 카드 띄우기", isOn: $prefs.autoExpandOnComplete)
                HStack {
                    Text("알림 카드 표시 시간")
                    Slider(value: $prefs.completionDwell, in: 2...15, step: 1)
                    Text("\(Int(prefs.completionDwell))초").monospacedDigit().frame(width: 36)
                }
                Toggle("세션 클릭 시 터미널 점프 끄기", isOn: $prefs.disableClickToJump)
            }
            Section("표시") {
                Picker("접힌 노치", selection: $prefs.detailedLayout) {
                    Text("깔끔 — 상태 점과 개수").tag(false)
                    Text("자세히 — 세션 이름과 상태").tag(true)
                }
                .pickerStyle(.radioGroup)
                Toggle("전체화면 앱에서는 숨기기", isOn: $prefs.hideInFullscreen)
                Toggle("세션이 없으면 숨기기", isOn: $prefs.autoHideWhenIdle)
                Toggle("AI 모델 표시", isOn: $prefs.showModel)
                Toggle("서브에이전트 수 표시", isOn: $prefs.showSubagents)
                Toggle("사용 한도(5시간/7일) 표시", isOn: $prefs.showUsage)
            }
            Section("자리 비움 리마인더") {
                Toggle("자리를 비웠다 돌아오면 기다리는 세션 알려주기", isOn: $prefs.idleReminder)
                HStack {
                    Text("자리 비움 기준")
                    Slider(value: $prefs.idleMinutes, in: 1...15, step: 1)
                    Text("\(Int(prefs.idleMinutes))분").monospacedDigit().frame(width: 40)
                }
                .disabled(!prefs.idleReminder)
            }
            Section("방해 금지") {
                Toggle("화면 공유·녹화 중에는 조용히", isOn: $prefs.quietDuringScreenShare)
                Toggle("집중 모드(방해 금지 등)에는 조용히", isOn: $prefs.quietDuringFocus)
                if prefs.quietDuringFocus && !quiet.focusReadable {
                    HStack {
                        Text("집중 모드를 감지하려면 '전체 디스크 접근 권한'이 필요해요.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("설정 열기") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
                Text(quiet.reason.map { "지금: \($0) — 노치가 저절로 펼쳐지지 않고 효과음도 꺼져요" } ?? "조용히 할 때는 노치가 저절로 펼쳐지지 않고 효과음도 꺼져요. 접힌 노치의 개수 표시는 그대로예요.")
                    .font(.caption).foregroundStyle(quiet.reason == nil ? Color.secondary : Color.orange)
            }
            Section("사용량 불러오기") {
                Toggle("Claude Code 로그인으로 사용 한도 조회", isOn: $prefs.useClaudeSignInForUsage)
                    .onChange(of: prefs.useClaudeSignInForUsage) { _, on in if on { claudeUsage.refresh() } }
                Text("키체인에 저장된 Claude Code 로그인 토큰을 읽어 Anthropic 사용량 API에만 보내요. 처음 켤 때 macOS가 키체인 접근을 물어봐요. 끄면 상태줄 연동 값만 써요.")
                    .font(.caption).foregroundStyle(.secondary)
                if prefs.useClaudeSignInForUsage {
                    HStack {
                        Text(claudeUsage.status.text).font(.caption)
                            .foregroundStyle(isError(claudeUsage.status) ? Color.orange : Color.secondary)
                        Spacer()
                        Button("지금 새로고침") { claudeUsage.refresh() }
                    }
                }
            }
            Section("사용량 경고") {
                Toggle("사용 한도 경고", isOn: $prefs.usageAlert)
                HStack {
                    Text("경고 기준")
                    Slider(value: $prefs.usageThreshold, in: 50...100, step: 5)
                    Text("\(Int(prefs.usageThreshold))%").monospacedDigit().frame(width: 40)
                }
            }
            Section("시스템") {
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        do {
                            try Integrations.setLaunchAtLogin(value)
                            loginError = nil
                        } catch {
                            loginError = "설정 실패: \(error.localizedDescription) (앱을 /Applications 또는 ~/Applications로 옮긴 뒤 다시 시도)"
                        }
                        launchAtLogin = Integrations.launchAtLogin
                    }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

private func isError(_ status: ClaudeUsageFetcher.Status) -> Bool {
    switch status {
    case .ok, .loading, .off: return false
    default: return true
    }
}

// MARK: - 사운드

struct SoundSettings: View {
    @ObservedObject var prefs: Prefs
    let sounds: SoundPlayer

    var body: some View {
        Form {
            Section {
                Toggle("효과음 켜기", isOn: $prefs.soundsEnabled)
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $prefs.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                }
            }
            Section("이벤트별 효과음") {
                ForEach(SoundCategory.allCases) { category in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { prefs.isSoundOn(category) },
                            set: { prefs.soundOn[category.rawValue] = $0 })) {
                            VStack(alignment: .leading) {
                                Text(category.title)
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { prefs.sound(for: category) },
                            set: { prefs.soundName[category.rawValue] = $0; sounds.preview(category, name: $0) })) {
                            ForEach(SoundPlayer.systemSounds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button { sounds.preview(category) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                Text("~/.notch-island/sounds/<이벤트>.wav 파일을 넣으면 그 소리를 우선 사용해요 (예: taskComplete.wav)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("조용한 시간") {
                Toggle("이 시간에는 효과음 끄기", isOn: $prefs.quietHoursEnabled)
                HStack {
                    MinutePicker(title: "시작", minutes: $prefs.quietStart)
                    MinutePicker(title: "끝", minutes: $prefs.quietEnd)
                }
                if prefs.inQuietHours() {
                    Text("지금은 조용한 시간이에요").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MinutePicker: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
    }
}

// MARK: - 단축키

struct ShortcutSettings: View {
    @ObservedObject var prefs: Prefs
    let onChanged: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("전역 단축키 사용", isOn: Binding(
                    get: { prefs.shortcutsEnabled },
                    set: { prefs.shortcutsEnabled = $0; onChanged() }))
            }
            Section("전역 단축키") {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(
                            get: { prefs.shortcut(for: action) },
                            set: { prefs.setShortcut($0, for: action); onChanged() }))
                        Button("기본값") { prefs.shortcuts[action.rawValue] = nil; onChanged() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("스위처 사용법") {
                Text("단축키를 누르면 세션 목록이 열려요. ↑↓ 또는 Tab/⇧Tab으로 고르고 Enter로 점프, 1~9로 바로 점프, Esc로 닫기. 열린 상태에서 단축키를 다시 누르면 다음 세션으로 넘어가요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "키를 누르세요…" : (shortcut?.display ?? "없음")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 110)
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { stop(); return nil }  // Esc = 취소
            let mods = HotKeyCenter.carbonModifiers(event.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }  // 수식키 필수
            shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, label: HotKeyCenter.keyLabel(event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - 사용량

struct UsageDashboard: View {
    @ObservedObject var usage: UsageStore
    @State private var period = 7

    var body: some View {
        let summary = usage.summary(days: period < 0 ? nil : period)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $period) {
                    Text("오늘").tag(0)
                    Text("7일").tag(7)
                    Text("30일").tag(30)
                    Text("90일").tag(-1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                if usage.scanning { ProgressView().controlSize(.small) }
                Button("새로고침") { usage.refresh() }.disabled(usage.scanning)
            }

            HStack(spacing: 12) {
                StatTile(title: "추정 비용", value: String(format: "$%.2f", summary.total.cost))
                StatTile(title: "토큰", value: Self.compact(summary.total.tokens))
                StatTile(title: "메시지", value: "\(summary.total.messages)")
                StatTile(title: "세션", value: "\(summary.sessions)")
            }

            HStack(spacing: 16) {
                TokenLegend(color: .blue, title: "입력", value: summary.total.input)
                TokenLegend(color: .green, title: "출력", value: summary.total.output)
                TokenLegend(color: .purple, title: "캐시 읽기", value: summary.total.cacheRead)
                TokenLegend(color: .orange, title: "캐시 쓰기", value: summary.total.cacheWrite)
            }

            DailyBars(days: summary.byDay)
                .frame(height: 110)

            Text("모델별").font(.headline)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(summary.byModel, id: \.model) { item in
                        HStack {
                            Text(item.model).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Text(Self.compact(item.totals.tokens)).foregroundStyle(.secondary).monospacedDigit()
                            Text(String(format: "$%.2f", item.totals.cost)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                    if summary.byModel.isEmpty {
                        Text(usage.lastScan == nil ? "새로고침을 눌러 집계하세요" : "이 기간 사용 기록이 없어요")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("~/.claude/projects 로컬 로그 기준 추정치 · 가격표: LiteLLM 공개 데이터")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .onAppear { if usage.lastScan == nil { usage.refresh() } }
    }

    static func compact(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        return "\(value)"
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct TokenLegend: View {
    let color: Color
    let title: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(UsageDashboard.compact(value)).font(.caption.monospacedDigit())
        }
    }
}

struct DailyBars: View {
    let days: [DayUsage]

    var body: some View {
        let maxCost = max(days.map(\.totals.cost).max() ?? 0, 0.01)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(height: max(2, geo.size.height * day.totals.cost / maxCost))
                        .help("\(day.day.formatted(date: .abbreviated, time: .omitted)) · $\(String(format: "%.2f", day.totals.cost))")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay {
            if days.isEmpty { Text("기록 없음").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - 연동

struct IntegrationSettings: View {
    @ObservedObject var prefs: Prefs
    let onChanged: () -> Void
    @State private var refresh = 0
    @State private var message: String?
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            ForEach(Integrations.Agent.allCases) { agent in
                Section(agent.title) {
                    let installed = Integrations.isInstalled(agent)
                    HStack {
                        Label(installed ? "연결됨" : "연결 안 됨", systemImage: installed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(installed ? .green : .secondary)
                        Spacer()
                        if installed {
                            Button("제거") {
                                perform { try Integrations.uninstall(agent) }
                                prefs.setManaged(agent.rawValue, false)
                            }
                        } else {
                            Button("설치") {
                                perform { try Integrations.install(agent) }
                                prefs.setManaged(agent.rawValue, true)
                            }
                                .disabled(!Integrations.isAgentPresent(agent))
                        }
                    }
                    Text(agent.configFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary)
                    if Integrations.hasVibeIslandHooks(agent) {
                        HStack {
                            Text("Vibe Island 훅이 남아 있어요. 둘 다 켜져 있으면 요청을 동시에 잡아요.")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Vibe Island 훅 제거") { perform { try Integrations.removeVibeIslandHooks(agent) } }
                        }
                    }
                }
            }
            Section("Claude 상태줄 (사용 한도·모델·컨텍스트)") {
                let installed = Integrations.isStatusLineInstalled
                HStack {
                    Label(installed ? "연결됨" : "연결 안 됨", systemImage: installed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(installed ? .green : .secondary)
                    Spacer()
                    Button(installed ? "제거" : "설치") {
                        perform { installed ? try Integrations.uninstallStatusLine() : try Integrations.installStatusLine() }
                        prefs.setManaged("statusline", !installed)
                    }
                }
                Text("기존 statusLine 명령은 보존해서 이어서 실행해요.").font(.caption).foregroundStyle(.secondary)
            }
            Section("데스크톱 앱") {
                Text("Claude 앱의 Code 탭 세션과 ChatGPT 앱의 Codex 작업도 노치에 떠요. Claude 앱은 위의 Claude Code 연동, ChatGPT 앱은 Codex 연동을 쓰고, 세션을 누르면 그 앱의 해당 대화가 열려요.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("데스크톱 앱 세션의 승인은 노치 대신 앱 화면에서 처리", isOn: $prefs.desktopApprovalsInApp)
                Text("ChatGPT 앱이 훅을 막으면 앱 설정 → Hooks(또는 Codex CLI에서 /hooks)에서 Notch Island 훅을 신뢰해 주세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("연동 유지·정밀 점프") {
                Toggle("다른 도구가 훅을 지우면 자동으로 복구", isOn: $prefs.autoRepairHooks)
                Toggle("창 제목에 세션 표식 넣기 (Ghostty·Warp·Alacritty 등 정밀 점프)", isOn: $prefs.titleMarkerEnabled)
                Text("표식 예: 'my-app ‹1a2b3c4d›'. 손쉬운 사용 권한이 있어야 표식으로 창을 찾을 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("권한") {
                HStack {
                    Label("손쉬운 사용 (Ghostty·Warp 등 창 단위 점프)", systemImage: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Spacer()
                    if !axTrusted {
                        Button("권한 요청") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            axTrusted = AXIsProcessTrustedWithOptions(options)
                        }
                    }
                }
                Text("iTerm2·Terminal 점프는 처음 점프할 때 '자동화' 권한을 물어봐요.").font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(message.hasPrefix("✓") ? .green : .red)
            }
            Text("설정 파일을 바꾸기 전에 같은 폴더에 *.notch-backup-<시각> 백업을 남겨요. 바뀐 훅은 새로 시작한 세션부터 적용돼요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .id(refresh)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            onChanged()
            message = "✓ 적용됨"
        } catch {
            message = "실패: \(error.localizedDescription)"
        }
        refresh += 1
    }
}

// MARK: - 정보

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "capsule.fill").font(.system(size: 44))
            Text("Notch Island").font(.title2.bold())
            Text("버전 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("AI 코딩 에이전트를 노치에서 관리하는 오픈 대안")
                .font(.callout)
            Divider().frame(width: 240)
            VStack(alignment: .leading, spacing: 4) {
                Text("소켓: ~/.notch-island/run/notch.sock")
                Text("bridge: ~/.notch-island/bin/notch-bridge")
                Text("로그: Console.app 에서 'NotchIsland' 검색")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 숨김

struct SilenceSettings: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section {
                Text("규칙에 맞는 세션은 노치에 나타나지 않고, 권한 요청도 평소처럼 터미널에서 물어봐요. 세션 카드를 우클릭해서 바로 추가할 수도 있어요.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("터미널 없이 돌아가는 백그라운드 세션 숨기기", isOn: $prefs.hideSessionsWithoutTTY)
                Text("claude -p 같은 스크립트 실행을 숨겨요. Claude Desktop처럼 터미널 없는 앱의 세션도 같이 숨겨질 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RuleList(
                title: "차단한 실행 앱 (번들 ID)",
                hint: "이 앱이 띄운 claude/codex 세션은 무시해요. 사용량 조회 도구 같은 백그라운드 프로그램용.",
                placeholder: "예: com.steipete.codexbar",
                rules: $prefs.blockedLaunchers,
                pickApp: true)
            RuleList(
                title: "숨길 폴더",
                hint: "작업 폴더 경로에 이 문자열이 들어 있으면 숨겨요.",
                placeholder: "예: /experiments",
                rules: $prefs.silencedDirectories)
            RuleList(
                title: "숨길 첫 프롬프트 (시작)",
                hint: "세션의 첫 프롬프트가 이 문자열로 시작하면 숨겨요.",
                placeholder: "예: Generate a title",
                rules: $prefs.silencedPromptPrefixes)
            RuleList(
                title: "숨길 첫 프롬프트 (포함)",
                hint: "세션의 첫 프롬프트에 이 문자열이 들어 있으면 숨겨요.",
                placeholder: "예: memory consolidation",
                rules: $prefs.silencedPromptContains)
            Section {
                Text("환경변수 NOTCH_ISLAND_SKIP=1 로 실행한 세션도 무시해요. 예: NOTCH_ISLAND_SKIP=1 claude -p \"…\"")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct RuleList: View {
    let title: String
    let hint: String
    let placeholder: String
    @Binding var rules: [String]
    var pickApp = false
    @State private var draft = ""

    var body: some View {
        Section(title) {
            Text(hint).font(.caption).foregroundStyle(.secondary)
            ForEach(rules, id: \.self) { rule in
                HStack {
                    Text(rule).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button { rules.removeAll { $0 == rule } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .onSubmit(add)
                Button("추가", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if pickApp {
                    Button("앱 선택…", action: chooseApp)
                }
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !rules.contains(value) else { return }
        rules.append(value)
        draft = ""
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier, !rules.contains(id) else { return }
        rules.append(id)
    }
}
