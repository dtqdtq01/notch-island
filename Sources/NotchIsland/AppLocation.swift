import AppKit

/// 배포 버전에서 필요한 시작 처리: 예전 설정 옮기기, 응용 프로그램 폴더로 옮기기
enum AppLocation {
    private static let legacyDomain = "local.notchisland.app"

    /// 개발용 번들 ID(local.notchisland.app)에 남은 설정을 한 번만 가져온다
    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacyDomain") else { return }
        defaults.set(true, forKey: "migratedLegacyDomain")
        guard Bundle.main.bundleIdentifier != legacyDomain,
              let old = defaults.persistentDomain(forName: legacyDomain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// 다운로드 폴더 등에서 실행했으면 응용 프로그램 폴더로 옮길지 묻는다.
    /// (로그인 시 실행과 훅 경로가 안정적이려면 고정된 위치가 필요하다)
    /// 옮겨서 다시 실행하게 되면 true — 호출한 쪽은 바로 종료해야 한다.
    static func offerMoveIfNeeded() -> Bool {
        let path = Bundle.main.bundlePath
        guard !isInApplicationsFolder,
              path.hasSuffix(".app"),
              !path.contains("/.build/"), !path.contains("/build/"),  // 개발 빌드
              !UserDefaults.standard.bool(forKey: "declinedMoveToApplications") else { return false }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "응용 프로그램 폴더로 옮길까요?"
        alert.informativeText = "Notch Island를 응용 프로그램 폴더에 두어야 로그인 시 실행과 에이전트 연동이 안정적으로 동작해요."
        alert.addButton(withTitle: "옮기기")
        alert.addButton(withTitle: "그대로 두기")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
            return false
        }

        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        let candidates = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for folder in candidates {
            let target = folder.appendingPathComponent(name)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
                try fm.copyItem(at: URL(fileURLWithPath: path), to: target)
                // 원본은 휴지통으로 (다운로드 폴더 정리). 격리된 임시 위치면 실패해도 괜찮다.
                try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                relaunch(at: target)
                return true
            } catch {
                continue
            }
        }
        let failure = NSAlert()
        failure.messageText = "옮기지 못했어요"
        failure.informativeText = "Finder에서 Notch Island를 응용 프로그램 폴더로 직접 끌어다 놓아 주세요."
        failure.runModal()
        return false
    }

    /// 지금 앱이 완전히 끝난 뒤 새 위치의 앱을 연다 (한 번에 하나만 실행되므로)
    private static func relaunch(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
        try? process.run()
    }
}
