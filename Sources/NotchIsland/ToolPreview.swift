import Foundation

/// 승인 카드에 보여줄 텍스트. "+ " / "- " 로 시작하는 줄은 diff 색으로 칠해진다.
enum ToolPreview {
    static let maxLines = 200

    static func render(tool: String, input: [String: Any]) -> String {
        var lines: [String] = []
        switch tool {
        case "Bash":
            lines.append("$ " + (input["command"] as? String ?? ""))
            if let description = input["description"] as? String { lines.append("# " + description) }
        case "Edit":
            lines.append(input["file_path"] as? String ?? "")
            lines += diff(old: input["old_string"] as? String, new: input["new_string"] as? String)
        case "MultiEdit":
            lines.append(input["file_path"] as? String ?? "")
            for edit in input["edits"] as? [[String: Any]] ?? [] {
                lines.append("@@")
                lines += diff(old: edit["old_string"] as? String, new: edit["new_string"] as? String)
            }
        case "Write":
            lines.append((input["file_path"] as? String ?? "") + "  (새 파일/덮어쓰기)")
            lines += (input["content"] as? String ?? "").components(separatedBy: "\n").map { "+ " + $0 }
        case "WebFetch":
            lines.append(input["url"] as? String ?? "")
            if let prompt = input["prompt"] as? String { lines.append(prompt) }
        default:
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                lines += json.components(separatedBy: "\n")
            }
        }
        if lines.count > maxLines {
            let extra = lines.count - maxLines
            lines = Array(lines.prefix(maxLines)) + ["… +\(extra)줄"]
        }
        return lines.joined(separator: "\n")
    }

    private static func diff(old: String?, new: String?) -> [String] {
        let removed = (old ?? "").components(separatedBy: "\n").map { "- " + $0 }
        let added = (new ?? "").components(separatedBy: "\n").map { "+ " + $0 }
        return removed + added
    }
}
