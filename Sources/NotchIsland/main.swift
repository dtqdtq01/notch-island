import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Prefs.shared
    private lazy var store = SessionStore(prefs: prefs)
    private lazy var sounds = SoundPlayer(prefs: prefs)
    private let usage = UsageStore()
    private lazy var quiet = QuietMonitor(prefs: prefs)
    private var hookWatcher: HookWatcher?
    private var idleWatcher: IdleWatcher?
    private var focusWatcher: FocusWatcher?
    private var claudeUsage: ClaudeUsageFetcher?
    private var server: SocketServer?
    private var notch: NotchPanelController?
    private var settings: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppLocation.offerMoveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        Integrations.installBridge()
        NotchFonts.register()
        Prefs.syncTitleMarkerFlag(prefs.titleMarkerEnabled)
        adoptExistingIntegrations()

        let server = SocketServer(store: store)
        do {
            try server.start()
        } catch SocketServer.StartError.alreadyRunning {
            NSLog("NotchIsland: already running")
            NSApp.terminate(nil)
            return
        } catch {
            NSLog("NotchIsland: socket start failed: \(error)")
            NSApp.terminate(nil)
            return
        }
        self.server = server

        store.isQuiet = { [weak self] in self?.quiet.isQuiet ?? false }
        store.onSound = { [weak self] category in
            guard let self, !self.quiet.isQuiet else { return }
            self.sounds.play(category)
        }
        hookWatcher = HookWatcher(prefs: prefs, store: store)
        idleWatcher = IdleWatcher(prefs: prefs, store: store) { [weak self] category in
            guard let self, !self.quiet.isQuiet else { return }
            self.sounds.play(category)
        }
        focusWatcher = FocusWatcher(store: store)
        TerminalJumper.desktopLinker = store
        let claudeUsage = ClaudeUsageFetcher(prefs: prefs, store: store)
        self.claudeUsage = claudeUsage
        settings = SettingsWindowController(
            prefs: prefs, usage: usage, sounds: sounds, quiet: quiet, claudeUsage: claudeUsage,
            onShortcutsChanged: { [weak self] in self?.registerHotkeys() },
            onIntegrationsChanged: { [weak self] in self?.hookWatcher?.reset() })
        notch = NotchPanelController(store: store, prefs: prefs, quiet: quiet) { [weak self] in self?.settings?.show() }
        registerHotkeys()
        setupStatusItem()

        // 처음 실행이면 연동 탭부터 보여준다
        if !Integrations.Agent.allCases.contains(where: Integrations.isInstalled) {
            settings?.show(tab: .integrations)
        }
    }

    /// 이전 버전에서 이미 설치한 연동도 자동 복구 대상으로 등록 (한 번만)
    private func adoptExistingIntegrations() {
        guard !UserDefaults.standard.bool(forKey: "adoptedIntegrations") else { return }
        UserDefaults.standard.set(true, forKey: "adoptedIntegrations")
        for agent in Integrations.Agent.allCases where Integrations.isInstalled(agent) {
            prefs.setManaged(agent.rawValue, true)
        }
        if Integrations.isStatusLineInstalled { prefs.setManaged("statusline", true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func registerHotkeys() {
        guard prefs.shortcutsEnabled else {
            HotKeyCenter.shared.unregisterAll()
            return
        }
        var bindings: [(Shortcut, () -> Void)] = []
        for action in HotkeyAction.allCases {
            guard let shortcut = prefs.shortcut(for: action) else { continue }
            bindings.append((shortcut, { [weak self] in self?.perform(action) }))
        }
        HotKeyCenter.shared.register(bindings)
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .switcher:
            notch?.switcherHotkey()
        case .approve:
            if let request = store.pending.first(where: \.isPermission) { store.decide(request, .allow) }
        case .deny:
            if let request = store.pending.first(where: \.isPermission) { store.decide(request, .deny) }
        case .jumpLatest:
            if let session = store.jumpTarget { notch?.jump(session) }
        }
    }

    // MARK: - 메뉴바

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = store.sortedSessions
        menu.addItem(withTitle: sessions.isEmpty ? "세션 없음" : "세션 \(sessions.count)개", action: nil, keyEquivalent: "")
        for session in sessions.prefix(9) {
            let item = NSMenuItem(title: "\(session.projectName) — \(session.status.label)", action: #selector(jumpFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(displayMenuItem())
        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 메뉴 막대에서 바로 화면 바꾸기
    private func displayMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "노치 화면", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        var options: [(String, String)] = [
            ("자동", DisplayChoice.auto), ("주 화면", DisplayChoice.primary), ("마우스가 있는 화면", DisplayChoice.mouse),
        ]
        let screens = DisplayChoice.currentScreens
        if screens.count > 1 {
            for (index, screen) in screens.enumerated() {
                options.append((DisplayChoice.label(screen, isPrimary: index == 0), DisplayChoice.specific(screen.uuid)))
            }
        }
        for (index, (title, value)) in options.enumerated() {
            if index == 3 { submenu.addItem(.separator()) }
            let option = NSMenuItem(title: title, action: #selector(chooseDisplay(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = value
            option.state = prefs.displayChoice == value ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    @objc private func chooseDisplay(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String { prefs.displayChoice = value }
    }

    @objc private func jumpFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session = store.sessions[id] else { return }
        notch?.jump(session)
    }

    @objc private func openSettings() {
        settings?.show()
    }
}

AppLocation.migrateLegacyDefaults()

// 명령줄: NotchIsland --install claude|codex|statusline  /  --uninstall …
// (화면 없이 연동만 설치하고 끝낸다. 실행 중인 앱은 그대로 둔다)
if let flagIndex = CommandLine.arguments.firstIndex(where: { $0 == "--install" || $0 == "--uninstall" }),
   flagIndex + 1 < CommandLine.arguments.count {
    let installing = CommandLine.arguments[flagIndex] == "--install"
    let target = CommandLine.arguments[flagIndex + 1]
    do {
        if target == "statusline" {
            try installing ? Integrations.installStatusLine() : Integrations.uninstallStatusLine()
        } else if let agent = Integrations.Agent(rawValue: target) {
            try installing ? Integrations.install(agent) : Integrations.uninstall(agent)
        } else {
            FileHandle.standardError.write(Data("알 수 없는 대상: \(target) (claude, codex, statusline)\n".utf8))
            exit(2)
        }
        Prefs.shared.setManaged(target, installing)
        print(installing ? "✓ \(target) 연동 설치" : "✓ \(target) 연동 제거")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("실패: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
