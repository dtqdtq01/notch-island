import AppKit
import CoreText
import SwiftUI

/// 번들에 넣은 Departure Mono(OFL) 픽셀 글꼴
enum NotchFonts {
    static let pixelName = "DepartureMono-Regular"
    private static var registered = false

    static func register(extraDirectory: URL? = nil) {
        guard !registered else { return }
        registered = true
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("Fonts/DepartureMono-Regular.otf")]
        if let extraDirectory { candidates.append(extraDirectory.appendingPathComponent("DepartureMono-Regular.otf")) }
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            return
        }
    }

    /// 글꼴이 없으면 시스템 고정폭으로 대신한다
    static func pixel(_ size: CGFloat) -> Font {
        NSFont(name: pixelName, size: size) != nil ? .custom(pixelName, size: size) : .system(size: size, design: .monospaced)
    }
}

/// 문자열 격자("X"=칠함)로 그리는 픽셀 그림
struct PixelSprite: View {
    let rows: [String]
    let color: Color
    var cell: CGFloat = 2

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, char) in row.enumerated() where char != "." {
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
                    // "o"는 반투명 픽셀 (명암)
                    context.fill(Path(rect), with: .color(char == "o" ? color.opacity(0.45) : color))
                }
            }
        }
        .frame(width: CGFloat(width) * cell, height: CGFloat(rows.count) * cell)
    }
}

enum PixelGlyphs {
    /// 집게발을 든 게 — Claude 계열 에이전트
    static let crab = [
        "X.X.....X.X",
        "XXX.....XXX",
        ".X.XXXXX.X.",
        "..XX.X.XX..",
        "..XXXXXXX..",
        ".X.XoooX.X.",
        "X.X.....X.X",
    ]
    /// 터미널 창 — Codex 등 그 밖의 에이전트
    static let terminal = [
        "XXXXXXXXXXX",
        "X.........X",
        "X.X.......X",
        "X..X......X",
        "X.X..XXX..X",
        "X.........X",
        "XXXXXXXXXXX",
    ]
    static let question = [
        ".XXX.",
        "X...X",
        "...X.",
        "..X..",
        "..X..",
        ".....",
        "..X..",
    ]
    static let bar = [
        "XX", "XX", "XX", "XX", "XX", "XX", "XX",
    ]
    static let wave = [
        ".....",
        ".....",
        ".X...",
        "X.X.X",
        "...X.",
        ".....",
        ".....",
    ]
    static let bang = [
        "XX", "XX", "XX", "XX", "XX", "..", "XX",
    ]
}

/// 에이전트 아이콘 + 상태 글리프. 작업 중이면 3×3 픽셀 스피너가 돈다.
struct AgentIcon: View {
    let source: String
    let status: SessionStatus
    /// 끝난 세션을 아직 안 봤으면 밝게, 봤으면 흐리게
    var unread = true
    var cell: CGFloat = 2

    private var color: Color {
        switch status {
        case .running: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .waitingApproval, .waitingInput: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .compacting: return Color(red: 0.7, green: 0.45, blue: 1.0)
        case .error: return Color(red: 1.0, green: 0.35, blue: 0.35)
        case .done, .idle: return Color(red: 0.3, green: 0.85, blue: 0.45)
        }
    }

    private var glows: Bool { status == .running || status == .waitingApproval || status == .waitingInput }

    private var faded: Bool { (status == .done || status == .error) && !unread }

    var body: some View {
        HStack(spacing: cell * 2.5) {
            PixelSprite(rows: source == "claude" ? PixelGlyphs.crab : PixelGlyphs.terminal, color: color, cell: cell)
            glyph
        }
        .opacity(faded ? 0.45 : 1)
        .shadow(color: glows ? color.opacity(0.7) : .clear, radius: 4)
        // 스피너가 돌아도 옆의 글자는 다시 그리지 않도록 아이콘만 따로 GPU에서 그린다
        .padding(4)
        .drawingGroup()
        .padding(-4)
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .running:
            PixelSpinner(color: color, cell: cell)
        case .waitingApproval, .waitingInput:
            PixelSprite(rows: PixelGlyphs.question, color: color, cell: cell)
        case .compacting:
            PixelSprite(rows: PixelGlyphs.wave, color: color, cell: cell)
        case .error:
            PixelSprite(rows: PixelGlyphs.bang, color: color, cell: cell)
        case .done:
            PixelSprite(rows: PixelGlyphs.bar, color: color, cell: cell)
        case .idle:
            PixelSprite(rows: PixelGlyphs.bar, color: color.opacity(0.35), cell: cell)
        }
    }
}

/// 3×3 격자에서 불빛이 시계 방향으로 도는 스피너 (초당 약 8프레임 — CPU를 거의 안 쓴다)
struct PixelSpinner: View {
    let color: Color
    var cell: CGFloat = 2
    private static let order = [0, 1, 2, 5, 8, 7, 6, 3]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate / 0.12) % Self.order.count
            Canvas { context, _ in
                let size = cell * 1.5
                let gap = cell * 0.5
                for index in 0..<9 {
                    let x = CGFloat(index % 3) * (size + gap)
                    let y = CGFloat(index / 3) * (size + gap) + cell * 2
                    // 머리와 꼬리 두 칸은 밝게, 나머지는 어둡게
                    let distance = (Self.order.firstIndex(of: index).map { (step - $0 + 8) % 8 }) ?? 99
                    let alpha: Double = index == 4 ? 0.25 : distance == 0 ? 1 : distance == 1 ? 0.6 : 0.2
                    context.fill(Path(CGRect(x: x, y: y, width: size, height: size)), with: .color(color.opacity(alpha)))
                }
            }
            .frame(width: cell * 5.5, height: cell * 7)
        }
    }
}
