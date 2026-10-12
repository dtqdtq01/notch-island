import AppKit
import Carbon.HIToolbox

/// Carbon 전역 단축키. 손쉬운 사용 권한 없이 동작한다.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    private static let signature = OSType(0x4E54_4348)  // 'NTCH'

    func register(_ bindings: [(Shortcut, () -> Void)]) {
        unregisterAll()
        installHandlerIfNeeded()
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                binding.0.keyCode, binding.0.modifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                handlers[id] = binding.1
            } else {
                NSLog("NotchIsland: 단축키 등록 실패 \(binding.0.display) status=\(status)")
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// NSEvent 수식키 → Carbon 수식키
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    static func keyLabel(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
