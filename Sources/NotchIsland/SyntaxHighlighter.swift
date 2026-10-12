import Foundation
import JavaScriptCore
import SwiftUI

/// 번들에 넣은 highlight.js(BSD-3)를 JavaScriptCore에서 돌려 코드에 색을 입힌다.
final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    struct Run: Equatable {
        let text: String
        let scope: String?
    }

    private let queue = DispatchQueue(label: "notch.highlight", qos: .userInitiated)
    private var context: JSContext?
    private var loaded = false
    private var cache: [String: [[Run]]] = [:]
    /// 테스트에서 소스 폴더의 스크립트를 쓰기 위한 경로
    static var scriptOverride: URL?

    /// 줄별 색 조각. 언어를 모르면 nil (그냥 흰 글자로 보여준다)
    func highlight(_ code: String, language: String?) async -> [[Run]]? {
        guard let language else { return nil }
        let key = language + "\u{0}" + code
        return await withCheckedContinuation { continuation in
            queue.async {
                if let cached = self.cache[key] { continuation.resume(returning: cached); return }
                guard let html = self.run(code, language: language) else { continuation.resume(returning: nil); return }
                let lines = Self.lines(fromHTML: html)
                if self.cache.count > 200 { self.cache.removeAll() }
                self.cache[key] = lines
                continuation.resume(returning: lines)
            }
        }
    }

    private func run(_ code: String, language: String) -> String? {
        if !loaded {
            loaded = true
            let url = Self.scriptOverride ?? Bundle.main.resourceURL?.appendingPathComponent("Highlight/highlight.min.js")
            guard let url, let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return nil }
            context.evaluateScript(script)
            context.evaluateScript("""
            function notchHighlight(code, lang) {
              if (!hljs.getLanguage(lang)) return null;
              return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
            }
            """)
            self.context = context
        }
        guard let fn = context?.objectForKeyedSubscript("notchHighlight"),
              let result = fn.call(withArguments: [code, language]), result.isString else { return nil }
        return result.toString()
    }

    /// `<span class="hljs-keyword">let</span>` 형태를 줄별 (글자, 종류) 조각으로 바꾼다
    static func lines(fromHTML html: String) -> [[Run]] {
        var lines: [[Run]] = [[]]
        var stack: [String] = []
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            let scope = stack.last
            let pieces = decode(text).components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { lines.append([]) }
                if !piece.isEmpty { lines[lines.count - 1].append(Run(text: piece, scope: scope)) }
            }
            text = ""
        }
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            text += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let tag = rest[rest.index(after: open)..<close]
            flush()
            if tag.hasPrefix("/") {
                if !stack.isEmpty { stack.removeLast() }
            } else if let range = tag.range(of: #"class="([^"]*)""#, options: .regularExpression) {
                let classes = tag[range].dropFirst(7).dropLast()
                // "hljs-title function_" → "title"
                let first = classes.split(separator: " ").first.map(String.init) ?? ""
                stack.append(first.replacingOccurrences(of: "hljs-", with: ""))
            } else {
                stack.append(stack.last ?? "")
            }
            rest = rest[rest.index(after: close)...]
        }
        text += rest
        flush()
        return lines
    }

    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 파일 확장자 → highlight.js 언어 이름
    static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" { return "dockerfile" }
        if name == "makefile" { return "makefile" }
        switch (name as NSString).pathExtension {
        case "swift": return "swift"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "mts": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "mm", "m": return "cpp"
        case "cs": return "csharp"
        case "php": return "php"
        case "sh", "bash", "zsh": return "bash"
        case "json", "jsonl": return "json"
        case "yml", "yaml": return "yaml"
        case "md", "markdown": return "markdown"
        case "html", "htm", "xml", "plist", "svg", "vue": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "sql": return "sql"
        case "toml", "ini", "cfg": return "ini"
        case "lua": return "lua"
        case "pl": return "perl"
        case "r": return "r"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }

    /// GitHub 어두운 테마와 비슷한 색
    static func color(for scope: String?) -> Color {
        switch scope {
        case "keyword", "selector-tag", "doctag", "template-tag": return Color(hex: "#FF7B72")
        case "string", "regexp", "template-variable", "char": return Color(hex: "#A5D6FF")
        case "comment", "quote", "meta": return Color(hex: "#8B949E")
        case "number", "literal", "attr", "attribute", "symbol", "variable.constant", "selector-attr", "selector-class", "selector-id":
            return Color(hex: "#79C0FF")
        case "title", "section", "function", "name", "selector-pseudo": return Color(hex: "#D2A8FF")
        case "built_in", "type", "class", "params", "variable", "property", "tag": return Color(hex: "#FFA657")
        case "addition": return Color(hex: "#7EE787")
        case "deletion": return Color(hex: "#FFA198")
        case "bullet", "link": return Color(hex: "#79C0FF")
        default: return Color.white.opacity(0.9)
        }
    }
}

extension Color {
    /// "#RRGGBB"
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
