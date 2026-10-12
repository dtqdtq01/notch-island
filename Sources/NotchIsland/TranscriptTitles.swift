import Foundation

/// Claude Code transcript(.jsonl)에서 제목 줄만 이어 읽는다.
/// 파일이 수 MB여도 마지막으로 읽은 위치부터만 읽어서 가볍다.
final class TranscriptTitleReader {
    static let shared = TranscriptTitleReader()

    struct Titles: Equatable {
        var ai: String?
        var custom: String?
    }

    private let queue = DispatchQueue(label: "notch.titles", qos: .utility)
    private var cache: [String: (offset: UInt64, titles: Titles)] = [:]
    private static let aiMarker = Data(#""type":"ai-title""#.utf8)
    private static let customMarker = Data(#""type":"custom-title""#.utf8)

    func read(path: String, completion: @escaping (Titles) -> Void) {
        queue.async {
            let titles = self.scan(path)
            DispatchQueue.main.async { completion(titles) }
        }
    }

    /// 테스트용 동기 버전
    func scan(_ path: String) -> Titles {
        var entry = cache[path] ?? (0, Titles())
        guard let handle = FileHandle(forReadingAtPath: path) else { return entry.titles }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset { entry = (0, Titles()) }  // 파일이 새로 써졌으면 처음부터
        try? handle.seek(toOffset: entry.offset)
        let data = handle.readDataToEndOfFile()
        // 마지막 줄이 쓰는 중일 수 있으니 완성된 줄까지만 처리
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return entry.titles }
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: 0x0A) {
            let isAI = line.range(of: Self.aiMarker) != nil
            let isCustom = !isAI && line.range(of: Self.customMarker) != nil
            guard isAI || isCustom,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if isAI, let title = object["aiTitle"] as? String, !title.isEmpty { entry.titles.ai = title }
            if isCustom, let title = object["customTitle"] as? String, !title.isEmpty { entry.titles.custom = title }
        }
        entry.offset += UInt64(complete.count)
        cache[path] = entry
        return entry.titles
    }
}

/// 프로젝트마다 고정된 색. 사용자가 바꾼 색이 있으면 그걸 쓴다.
enum ProjectPalette {
    static let colors: [(name: String, hex: String)] = [
        ("빨강", "#FF6B6B"), ("주황", "#FF9F43"), ("노랑", "#FECA57"), ("초록", "#1DD1A1"),
        ("청록", "#48DBFB"), ("파랑", "#54A0FF"), ("보라", "#A55EEA"), ("분홍", "#FF6FB5"),
    ]

    /// 이름 해시로 기본 색을 고른다 (실행할 때마다 같은 색)
    static func defaultHex(for project: String) -> String {
        var hash: UInt64 = 5381
        for byte in project.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))].hex
    }

    static func hex(for project: String, overrides: [String: String]) -> String {
        overrides[project] ?? defaultHex(for: project)
    }
}
