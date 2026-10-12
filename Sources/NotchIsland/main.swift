import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var server: SocketServer?
    private var notch: NotchPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        notch = NotchPanelController(store: store)
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Notch Island", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
