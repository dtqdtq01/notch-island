import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Prefs.shared
    private lazy var store = SessionStore(prefs: prefs)
    private lazy var sounds = SoundPlayer(prefs: prefs)
    private let usage = UsageStore()
    private var server: SocketServer?
    private var notch: NotchPanelController?
    private var settings: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Integrations.installBridge()

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

        store.onSound = { [weak self] in self?.sounds.play($0) }
        settings = SettingsWindowController(
            prefs: prefs, usage: usage, sounds: sounds,
            onShortcutsChanged: { [weak self] in self?.registerHotkeys() })
        notch = NotchPanelController(store: store, prefs: prefs) { [weak self] in self?.settings?.show() }
        registerHotkeys()
        setupStatusItem()

        // 처음 실행이면 연동 탭부터 보여준다
        if !Integrations.Agent.allCases.contains(where: Integrations.isInstalled) {
            settings?.show(tab: .integrations)
        }
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
        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func jumpFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session = store.sessions[id] else { return }
        notch?.jump(session)
    }

    @objc private func openSettings() {
        settings?.show()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
