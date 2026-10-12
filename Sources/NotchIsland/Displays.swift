import AppKit
import CoreGraphics

/// 노치를 띄울 화면 고르기.
/// 설정값: "auto" | "primary" | "mouse" | "uuid:<디스플레이 UUID>"
enum DisplayChoice {
    static let auto = "auto"
    static let primary = "primary"
    static let mouse = "mouse"
    static func specific(_ uuid: String) -> String { "uuid:" + uuid }

    /// 화면 하나의 정보 (테스트에서도 만들 수 있게 NSScreen과 분리)
    struct ScreenInfo: Equatable {
        let uuid: String
        let name: String
        let hasNotch: Bool
        let isBuiltIn: Bool
    }

    /// 고른 화면의 번호. screens[0]은 메뉴 막대가 있는 주 화면이다.
    /// 고른 모니터가 빠졌으면 자동 규칙(노치 화면 → 주 화면)으로 돌아간다.
    static func resolve(_ choice: String, screens: [ScreenInfo], mouseIndex: Int?) -> Int {
        guard !screens.isEmpty else { return 0 }
        let automatic = screens.firstIndex(where: \.hasNotch) ?? 0
        switch choice {
        case primary:
            return 0
        case mouse:
            if let mouseIndex, screens.indices.contains(mouseIndex) { return mouseIndex }
            return automatic
        default:
            if choice.hasPrefix("uuid:"), let index = screens.firstIndex(where: { "uuid:" + $0.uuid == choice }) {
                return index
            }
            return automatic
        }
    }

    // MARK: - 실제 화면

    static func info(for screen: NSScreen) -> ScreenInfo {
        let id = screen.displayID
        return ScreenInfo(
            uuid: id.flatMap(uuidString) ?? screen.localizedName,
            name: screen.localizedName,
            hasNotch: screen.safeAreaInsets.top > 0,
            isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false)
    }

    static var currentScreens: [ScreenInfo] { NSScreen.screens.map(info) }

    static func screen(for choice: String) -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main ?? NSScreen.screens[0] }
        let mouseIndex = screens.firstIndex { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        return screens[resolve(choice, screens: screens.map(info), mouseIndex: mouseIndex)]
    }

    /// 재부팅·재연결해도 같은 모니터를 가리키는 ID
    private static func uuidString(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// 설정 화면에 보일 이름
    static func label(_ screen: ScreenInfo, isPrimary: Bool) -> String {
        var tags: [String] = []
        if screen.isBuiltIn { tags.append("내장") }
        if screen.hasNotch { tags.append("노치") }
        if isPrimary { tags.append("주 화면") }
        return tags.isEmpty ? screen.name : "\(screen.name) (\(tags.joined(separator: ", ")))"
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
