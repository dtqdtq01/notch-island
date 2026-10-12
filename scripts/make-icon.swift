// 앱 아이콘 생성: swift scripts/make-icon.swift <출력.iconset 폴더>
// 어두운 배경 위에 노치 모양과 픽셀 게(앱 안의 에이전트 아이콘과 같은 그림)를 그린다.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let crab = [
    "X.X.....X.X",
    "XXX.....XXX",
    ".X.XXXXX.X.",
    "..XX.X.XX..",
    "..XXXXXXX..",
    ".X.XoooX.X.",
    "X.X.....X.X",
]

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 아이콘 격자: 824/1024 크기의 둥근 사각형
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // 배경 그라디언트
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1).cgColor, NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // 위쪽 가운데 노치 (검은 알약)
    let notchW = body.width * 0.46, notchH = body.height * 0.13
    let notch = CGRect(x: body.midX - notchW / 2, y: body.maxY - notchH, width: notchW, height: notchH + notchH)
    ctx.addPath(CGPath(roundedRect: notch, cornerWidth: notchH * 0.9, cornerHeight: notchH * 0.9, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    // 노치 안 초록 상태 점
    let dot = notchH * 0.32
    ctx.setFillColor(NSColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: notch.minX + notchH * 0.7, y: body.maxY - notchH / 2 - dot / 2, width: dot, height: dot))

    // 픽셀 게 (주황) + 은은한 빛
    let cell = body.width * 0.052
    let gridW = CGFloat(crab[0].count) * cell, gridH = CGFloat(crab.count) * cell
    let origin = CGPoint(x: body.midX - gridW / 2, y: body.midY - gridH / 2 - body.height * 0.04)
    let orange = NSColor(red: 1.0, green: 0.6, blue: 0.22, alpha: 1)
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: orange.withAlphaComponent(0.55).cgColor)
    for (row, line) in crab.enumerated() {
        for (col, char) in line.enumerated() where char != "." {
            ctx.setFillColor((char == "o" ? orange.withAlphaComponent(0.5) : orange).cgColor)
            let y = origin.y + gridH - CGFloat(row + 1) * cell
            ctx.fill(CGRect(x: origin.x + CGFloat(col) * cell, y: y, width: cell + 0.5, height: cell + 0.5))
        }
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("✓ \(out.path)")
