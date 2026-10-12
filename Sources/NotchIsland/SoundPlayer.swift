import AppKit
import NotchShared

/// 이벤트별 효과음. ~/.notch-island/sounds/<카테고리>.(wav|aiff|mp3|m4a|caf) 가 있으면 그걸 우선 사용.
final class SoundPlayer {
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
    private static let customExtensions = ["wav", "aiff", "mp3", "m4a", "caf"]

    private let prefs: Prefs
    private var lastPlayed: [SoundCategory: Date] = [:]

    init(prefs: Prefs) { self.prefs = prefs }

    func play(_ category: SoundCategory) {
        guard prefs.soundsEnabled, prefs.isSoundOn(category), !prefs.inQuietHours() else { return }
        // 같은 소리가 연달아 터지는 것 방지
        let now = Date()
        if let last = lastPlayed[category], now.timeIntervalSince(last) < 0.6 { return }
        lastPlayed[category] = now
        preview(category)
    }

    /// 설정 화면 미리듣기 (조용한 시간·토글 무시)
    func preview(_ category: SoundCategory, name: String? = nil) {
        let sound = (name == nil ? customSound(category) : nil)
            ?? (NSSound(named: NSSound.Name(name ?? prefs.sound(for: category)))?.copy() as? NSSound)
        sound?.volume = Float(prefs.volume)
        sound?.play()
    }

    private func customSound(_ category: SoundCategory) -> NSSound? {
        for ext in Self.customExtensions {
            let url = NotchPaths.soundsDir.appendingPathComponent("\(category.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return NSSound(contentsOf: url, byReference: true)
            }
        }
        return nil
    }
}
