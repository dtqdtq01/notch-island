import SwiftUI

/// 윗변은 각지고 아랫변만 둥근 노치 모양
struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchViewModel

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: model.expanded ? 22 : 10)
                .fill(Color.black)
            if model.expanded {
                ExpandedView(store: store, topInset: model.geometry.notchHeight)
            } else {
                CollapsedView(store: store, notchWidth: model.geometry.notchWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

struct StatusDot: View {
    let status: SessionStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .opacity(status == .running && pulse ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
            }
    }
}

struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    let notchWidth: CGFloat

    var body: some View {
        if let status = store.mostUrgent {
            HStack(spacing: 0) {
                StatusDot(status: status)
                    .frame(width: NotchViewModel.sideWidth)
                Spacer().frame(width: notchWidth)
                Group {
                    if !store.pending.isEmpty {
                        Text("\(store.pending.count)!").foregroundStyle(.orange)
                    } else {
                        Text("\(store.sessions.count)").foregroundStyle(.white.opacity(0.8))
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: NotchViewModel.sideWidth)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            if let request = store.pending.first {
                ApprovalCard(request: request, extraCount: store.pending.count - 1) { decision in
                    store.decide(request, decision)
                }
                .frame(height: NotchViewModel.approvalHeight - 8)
            }
            if store.sessions.isEmpty {
                Text("실행 중인 에이전트 세션 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.sortedSessions) { SessionRow(session: $0) }
                    }
                }
            }
        }
        .padding(.top, topInset + 4)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(session.status.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(session.status.color)
                }
                Text(session.detail.isEmpty ? session.source : session.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.updatedAt, style: .relative)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: NotchViewModel.rowHeight - 2)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}

struct ApprovalCard: View {
    let request: PermissionRequest
    let extraCount: Int
    let onDecide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                Text("\(request.projectName) · \(request.toolName)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if extraCount > 0 {
                    Text("+\(extraCount) 대기")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(request.preview.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .foregroundStyle(color(for: line))
                            .fixedSize()
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))

            HStack(spacing: 8) {
                Button("거부") { onDecide(.deny) }
                    .buttonStyle(PillButton(tint: .red))
                Spacer()
                if let suggestions = request.suggestions, !suggestions.isEmpty {
                    Button("항상 허용") { onDecide(.always) }
                        .buttonStyle(PillButton(tint: .blue))
                }
                Button("한 번 허용") { onDecide(.allow) }
                    .buttonStyle(PillButton(tint: .green))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+ ") { return Color(red: 0.45, green: 0.85, blue: 0.5) }
        if line.hasPrefix("- ") { return Color(red: 1.0, green: 0.5, blue: 0.5) }
        if line.hasPrefix("# ") { return .secondary }
        return .white.opacity(0.9)
    }
}

struct PillButton: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.5 : 0.28)))
            .foregroundStyle(.white)
    }
}
