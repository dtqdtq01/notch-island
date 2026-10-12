import SwiftUI

/// 노치 모양: 위쪽은 메뉴바로 이어지는 오목한 "귀", 아래쪽은 둥근 모서리.
/// rect 너비 = 몸통 + 귀 두 개.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4, rect.height / 2)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// 노치 전체가 공유하는 움직임
enum NotchMotion {
    /// 펼침/접힘: 살짝 튕기는 스프링
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// 목록·카드 변화
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// 내용은 모양이 어느 정도 열린 뒤 나타나고, 닫힐 땐 먼저 사라진다
    static let contentIn = AnyTransition.asymmetric(
        insertion: .blurFade.animation(.easeOut(duration: 0.24).delay(0.07)),
        removal: .blurFade.animation(.easeIn(duration: 0.1)))
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.96 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

enum SilenceAction { case directory, prompt, dismiss }

struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchViewModel
    @ObservedObject var prefs: Prefs
    let onJump: (Session) -> Void
    let onToggle: () -> Void
    let onSilence: (Session, SilenceAction) -> Void
    let onSettings: () -> Void
    /// 모양이 움직이는 동안에만 노치 모양으로 자른다.
    /// 평소에는 사각형으로만 잘라서, 상태 점 애니메이션이 큰 마스크를 매 프레임 다시 그리지 않게 한다.
    @State private var shaping = false
    @State private var shapingEnd: DispatchWorkItem?

    var body: some View {
        let mode = model.mode
        let size = model.size
        let top = Metrics.topRadius(mode)
        let shape = NotchShape(topRadius: top, bottomRadius: Metrics.bottomRadius(mode))
        let open = mode != .collapsed

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(open ? 0.5 : 0), radius: open ? 18 : 0, y: open ? 8 : 0)
                // 내용은 최종 크기로 한 번에 배치하고, 늘어나는 모양이 잘라서 드러낸다 (글자가 찌그러지지 않게)
                content(mode)
                    .padding(.horizontal, top)
                    .frame(width: size.width + top * 2, height: size.height, alignment: .top)
                    .animation(nil, value: size)
                    // 바깥 프레임은 스프링으로 커지고, 그 모양대로 잘라서 내용이 밖으로 새지 않게
                    .frame(width: size.width + top * 2, height: size.height, alignment: .top)
                    .clipShape(shaping ? AnyShape(shape) : AnyShape(Rectangle()))
            }
            .frame(width: size.width + top * 2, height: size.height)
            .onChange(of: size) { _, _ in beginShaping() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func beginShaping() {
        shaping = true
        shapingEnd?.cancel()
        let work = DispatchWorkItem { shaping = false }
        shapingEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    @ViewBuilder
    private func content(_ mode: NotchMode) -> some View {
        switch mode {
        case .collapsed:
            CollapsedView(store: store, notchWidth: model.geometry.notchWidth, detailed: prefs.detailedLayout)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
        case .peek:
            if let peek = store.peek {
                PeekView(peek: peek)
                    .padding(.top, model.geometry.notchHeight + 4)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let sid = peek.sessionID, let session = store.sessions[sid] { onJump(session) }
                        store.clearPeek()
                    }
                    .transition(NotchMotion.contentIn)
            }
        case .expanded:
            ExpandedView(store: store, model: model, prefs: prefs, onJump: onJump, onSilence: onSilence, onSettings: onSettings)
                .transition(NotchMotion.contentIn)
        }
    }
}

struct StatusDot: View {
    let status: SessionStatus
    @State private var breathe = false

    private var active: Bool { status == .running || status == .compacting }
    private var urgent: Bool { status == .waitingApproval || status == .waitingInput }

    var body: some View {
        ZStack {
            // 작업 중·대기 중이면 바깥 링이 퍼졌다 사라진다
            if active || urgent {
                Circle()
                    .stroke(status.color, lineWidth: 1.5)
                    .scaleEffect(breathe ? 2.2 : 1)
                    .opacity(breathe ? 0 : 0.8)
            }
            Circle()
                .fill(status.color)
                .shadow(color: status.color.opacity(active || urgent ? 0.8 : 0), radius: 3)
                .frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
        // 링이 퍼질 공간을 두고, 점만 따로 GPU에서 그린다
        // (안 그러면 매 프레임 옆의 글자까지 CPU에서 다시 그려 CPU를 많이 쓴다)
        .frame(width: 20, height: 20)
        .drawingGroup()
        .frame(width: 8, height: 8)
        .animation(.easeInOut(duration: 0.3), value: status)
        .onAppear { startBreathing() }
        .onChange(of: status) { _, _ in startBreathing() }
    }

    private func startBreathing() {
        breathe = false
        guard active || urgent else { return }
        withAnimation(.easeOut(duration: urgent ? 0.9 : 1.4).repeatForever(autoreverses: false)) { breathe = true }
    }
}

struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    let notchWidth: CGFloat
    let detailed: Bool

    var body: some View {
        if let top = store.sortedSessions.first {
            let side = Metrics.sideWidth(detailed: detailed)
            HStack(spacing: 0) {
                // 왼쪽: 상태 점 (+ 자세히: 가장 급한 세션 이름)
                HStack(spacing: 6) {
                    StatusDot(status: top.status)
                    if detailed {
                        Text(top.projectName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentTransition(.opacity)
                    }
                }
                .padding(.leading, detailed ? 12 : 0)
                .frame(width: side, alignment: detailed ? .leading : .center)
                Spacer().frame(width: notchWidth)
                // 오른쪽: 개수 (+ 자세히: 상태 글자)
                HStack(spacing: 4) {
                    if detailed {
                        Text(store.pending.isEmpty ? top.status.label : "승인 \(store.pending.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(store.pending.isEmpty ? top.status.color : .orange)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        if store.sessions.count > 1 {
                            Text("+\(store.sessions.count - 1)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    } else {
                        Group {
                            if !store.pending.isEmpty {
                                Text("\(store.pending.count)!").foregroundStyle(.orange)
                            } else {
                                Text("\(store.sessions.count)").foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    }
                }
                .padding(.trailing, detailed ? 12 : 0)
                .frame(width: side, alignment: detailed ? .trailing : .center)
            }
            .frame(maxHeight: .infinity)
            .animation(NotchMotion.snappy, value: store.sessions.count)
            .animation(NotchMotion.snappy, value: store.pending.count)
            .animation(.easeInOut(duration: 0.2), value: top.id)
            .animation(.easeInOut(duration: 0.2), value: top.status)
        } else {
            Color.clear
        }
    }
}

struct PeekView: View {
    let peek: Peek

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(peek.title).font(.system(size: 13, weight: .semibold))
                if !peek.body.isEmpty {
                    Text(peek.body)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch peek.kind {
        case .complete: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .usage: return "gauge.with.dots.needle.67percent"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch peek.kind {
        case .complete: return .green
        case .error: return .red
        case .usage: return .orange
        case .info: return .blue
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchViewModel
    @ObservedObject var prefs: Prefs
    let onJump: (Session) -> Void
    let onSilence: (Session, SilenceAction) -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HeaderView(store: store, prefs: prefs, onSettings: onSettings)
                .frame(height: Metrics.headerHeight)
            if let request = store.pending.first {
                RequestCard(store: store, request: request)
                    .id(request.id)
                    .frame(height: Metrics.cardHeight(request))
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.94).combined(with: .opacity)))
            }
            if store.sessions.isEmpty {
                Text("실행 중인 에이전트 세션 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(store.sortedSessions.enumerated()), id: \.element.id) { index, session in
                                SessionRow(
                                    session: session, index: index, prefs: prefs,
                                    highlighted: model.switcherIndex == index)
                                    .id(session.id)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                    .contentShape(Rectangle())
                                    .onTapGesture { if !prefs.disableClickToJump { onJump(session) } }
                                    .contextMenu {
                                        Button("터미널로 이동") { onJump(session) }
                                        Divider()
                                        if !session.cwd.isEmpty {
                                            Button("이 폴더의 세션 숨기기") { onSilence(session, .directory) }
                                        }
                                        if let prompt = session.firstPrompt, !prompt.isEmpty {
                                            Button("\"\(String(prompt.prefix(20)))…\"로 시작하면 숨기기") { onSilence(session, .prompt) }
                                        }
                                        Button("카드 닫기") { onSilence(session, .dismiss) }
                                    }
                            }
                        }
                    }
                    .onChange(of: model.switcherIndex) { _, index in
                        let sessions = store.sortedSessions
                        if let index, index < sessions.count { proxy.scrollTo(sessions[index].id) }
                    }
                }
            }
        }
        .padding(.top, model.geometry.notchHeight + 2)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .animation(NotchMotion.snappy, value: store.pending.first?.id)
        .animation(NotchMotion.snappy, value: store.sortedSessions.map(\.id))
        .animation(NotchMotion.snappy, value: model.switcherIndex)
    }
}

struct HeaderView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var prefs: Prefs
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if prefs.showUsage, let limits = store.rateLimits {
                if let five = limits.fiveHour { UsageGauge(title: "5h", window: five, threshold: prefs.usageThreshold) }
                if let week = limits.sevenDay { UsageGauge(title: "7d", window: week, threshold: prefs.usageThreshold) }
            } else {
                Text("Notch Island").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.pending.count > 1, store.pending.contains(where: \.isPermission) {
                Button("모두 허용") { store.decideAllPermissions(.allow) }
                    .buttonStyle(PillButton(tint: .green, compact: true))
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

struct UsageGauge: View {
    let title: String
    let window: RateWindow
    let threshold: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width: 54 * min(max(window.usedPercent, 0), 100) / 100)
            }
            .frame(width: 54, height: 5)
            Text("\(Int(window.usedPercent))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
            if let reset = window.resetsAt {
                Text(SessionStore.relative(reset)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .help(window.resetsAt.map { "초기화: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }

    private var color: Color {
        if window.usedPercent >= threshold { return .orange }
        return window.usedPercent >= 95 ? .red : .green
    }
}

struct SessionRow: View {
    let session: Session
    let index: Int
    @ObservedObject var prefs: Prefs
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(session.status.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(session.status.color)
                    if prefs.showSubagents && session.subagents > 0 {
                        Tag(text: "+\(session.subagents) 서브")
                    }
                    if prefs.showModel, let model = session.model { Tag(text: model) }
                    if let context = session.contextPercent { Tag(text: "ctx \(Int(context))%") }
                }
                Text(session.detail.isEmpty ? session.sourceLabel : session.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: session.detail)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.sourceLabel).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                Text(session.updatedAt, style: .relative)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight - 2)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(highlighted ? 0.16 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlighted ? Color.accentColor : .clear, lineWidth: 1)))
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - 요청 카드

struct RequestCard: View {
    @ObservedObject var store: SessionStore
    let request: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.orange)
                Text("\(request.projectName) · \(title)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Tag(text: request.source == "codex" ? "Codex" : "Claude")
                Spacer()
                if store.pending.count > 1 {
                    Text("+\(store.pending.count - 1) 대기").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            switch request.kind {
            case .permission:
                PermissionBody(request: request) { store.decide(request, $0) }
            case .question(let questions):
                QuestionBody(questions: questions, draft: store.draft(for: request)) { store.decide(request, $0) }
            case .plan(let plan):
                PlanBody(plan: plan, draft: store.draft(for: request)) { store.decide(request, $0) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    private var icon: String {
        switch request.kind {
        case .permission: return "lock.shield.fill"
        case .question: return "questionmark.bubble.fill"
        case .plan: return "list.bullet.clipboard.fill"
        }
    }

    private var title: String {
        switch request.kind {
        case .permission: return request.toolName
        case .question: return "질문"
        case .plan: return "계획 승인"
        }
    }
}

struct CodePreview: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
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
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+ ") { return Color(red: 0.45, green: 0.85, blue: 0.5) }
        if line.hasPrefix("- ") { return Color(red: 1.0, green: 0.5, blue: 0.5) }
        if line.hasPrefix("# ") || line.hasPrefix("@@") { return .secondary }
        return .white.opacity(0.9)
    }
}

struct PermissionBody: View {
    let request: PendingRequest
    let onDecide: (Decision) -> Void

    var body: some View {
        CodePreview(text: request.preview)
        HStack(spacing: 8) {
            Button("거부") { onDecide(.deny) }
                .buttonStyle(PillButton(tint: .red))
            Button("터미널에서") { onDecide(.terminal) }
                .buttonStyle(PillButton(tint: .gray))
            Spacer()
            if let suggestions = request.suggestions, !suggestions.isEmpty {
                Button("항상 허용") { onDecide(.always) }
                    .buttonStyle(PillButton(tint: .blue))
            }
            Button("한 번 허용") { onDecide(.allow) }
                .buttonStyle(PillButton(tint: .green))
        }
    }
}

struct PlanBody: View {
    let plan: String
    @ObservedObject var draft: RequestDraft
    let onDecide: (Decision) -> Void

    /// 계획 승인 뒤 권한 모드 (Claude Code의 setMode 값)
    private static let modes: [(id: String, title: String, help: String)] = [
        ("default", "하나씩 승인", "모든 작업을 확인 · 가장 안전"),
        ("acceptEdits", "편집 자동", "파일 편집은 자동 허용"),
        ("bypassPermissions", "모두 허용", "권한 확인을 모두 건너뜀"),
    ]

    var body: some View {
        ScrollView {
            Text(markdown)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        HStack(spacing: 4) {
            ForEach(Self.modes, id: \.id) { mode in
                Button { draft.planMode = mode.id } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(draft.planMode == mode.id ? 0.2 : 0.05)))
                        .overlay(Capsule().stroke(mode.id == "bypassPermissions" && draft.planMode == mode.id ? Color.orange : .clear))
                }
                .buttonStyle(.plain)
                .help(mode.help)
            }
        }
        .animation(NotchMotion.snappy, value: draft.planMode)
        HStack(spacing: 8) {
            TextField("수정할 점을 적으면 '계속 계획'으로 전달돼요…", text: $draft.feedback)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Button("계속 계획") { onDecide(.denyWithMessage(feedbackMessage)) }
                .buttonStyle(PillButton(tint: .red))
            Button("승인") { onDecide(.approvePlan(mode: draft.planMode == "default" ? nil : draft.planMode)) }
                .buttonStyle(PillButton(tint: .green))
        }
    }

    private var feedbackMessage: String {
        let text = draft.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "계획을 아직 승인하지 않았어요. 계획을 더 다듬어 주세요." : "계획 수정 요청: \(text)"
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: plan, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(plan)
    }
}

/// AskUserQuestion: 여러 문항은 마법사처럼 한 문항씩. 쓰던 내용은 draft에 남는다.
struct QuestionBody: View {
    let questions: [AgentQuestion]
    @ObservedObject var draft: RequestDraft
    let onDecide: (Decision) -> Void

    @State private var warning = false

    var body: some View {
        let step = min(draft.step, questions.count - 1)
        let question = questions[step]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !question.header.isEmpty { Tag(text: question.header) }
                if question.multiSelect { Tag(text: "여러 개 선택") }
                Spacer()
                if questions.count > 1 {
                    Text("\(step + 1) / \(questions.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Text(question.text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(question.options, id: \.self) { option in
                        OptionRow(
                            option: option, multi: question.multiSelect,
                            selected: draft.selections[question.id, default: []].contains(option.label)
                        ) { toggle(option.label, in: question) }
                    }
                    TextField("직접 입력…", text: Binding(
                        get: { draft.custom[question.id] ?? "" },
                        set: { draft.custom[question.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }
            .id(question.id)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            HStack(spacing: 8) {
                Button("터미널에서") { onDecide(.terminal) }
                    .buttonStyle(PillButton(tint: .gray))
                if warning {
                    Text("모든 질문에 답해 주세요").font(.system(size: 10)).foregroundStyle(.orange)
                }
                Spacer()
                if step > 0 {
                    Button("이전") { draft.step -= 1 }.buttonStyle(PillButton(tint: .gray))
                }
                if step < questions.count - 1 {
                    Button("다음") { draft.step += 1 }.buttonStyle(PillButton(tint: .blue))
                } else {
                    Button("답변 보내기") { submit() }.buttonStyle(PillButton(tint: .green))
                }
            }
        }
        .animation(NotchMotion.snappy, value: draft.step)
    }

    private func toggle(_ label: String, in question: AgentQuestion) {
        var set = draft.selections[question.id, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        draft.selections[question.id] = set
        warning = false
    }

    private func submit() {
        var answers: [String: Any] = [:]
        for question in questions {
            let text = (draft.custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 옵션 순서를 지켜서 보낸다
            var picked = question.options.map(\.label).filter { draft.selections[question.id, default: []].contains($0) }
            if question.multiSelect {
                if !text.isEmpty { picked.append(text) }
                if picked.isEmpty { warning = true; draft.step = question.id; return }
                answers[question.text] = picked
            } else {
                let answer = text.isEmpty ? picked.first : text
                guard let answer else { warning = true; draft.step = question.id; return }
                answers[question.text] = answer
            }
        }
        onDecide(.answer(answers))
    }
}

struct OptionRow: View {
    let option: QuestionOption
    let multi: Bool
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12, weight: .medium))
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(selected ? 0.12 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillButton: ButtonStyle {
    let tint: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10 : 12, weight: .semibold))
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 3 : 6)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.5 : 0.28)))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
