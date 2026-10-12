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
    @ObservedObject var prefs: Prefs
    let onJump: (Session) -> Void
    let onToggle: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: model.mode == .collapsed ? 10 : 22)
                .fill(Color.black)
            switch model.mode {
            case .collapsed:
                CollapsedView(store: store, notchWidth: model.geometry.notchWidth)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
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
                }
            case .expanded:
                ExpandedView(store: store, model: model, prefs: prefs, onJump: onJump, onSettings: onSettings)
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
            .opacity((status == .running || status == .compacting) && pulse ? 0.35 : 1)
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
                    .frame(width: Metrics.sideWidth)
                Spacer().frame(width: notchWidth)
                Group {
                    if !store.pending.isEmpty {
                        Text("\(store.pending.count)!").foregroundStyle(.orange)
                    } else {
                        Text("\(store.sessions.count)").foregroundStyle(.white.opacity(0.8))
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: Metrics.sideWidth)
            }
            .frame(maxHeight: .infinity)
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
        }
    }

    private var color: Color {
        switch peek.kind {
        case .complete: return .green
        case .error: return .red
        case .usage: return .orange
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchViewModel
    @ObservedObject var prefs: Prefs
    let onJump: (Session) -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HeaderView(store: store, prefs: prefs, onSettings: onSettings)
                .frame(height: Metrics.headerHeight)
            if let request = store.pending.first {
                RequestCard(store: store, request: request)
                    .id(request.id)
                    .frame(height: Metrics.cardHeight(request))
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
                                    .contentShape(Rectangle())
                                    .onTapGesture { if !prefs.disableClickToJump { onJump(session) } }
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
                QuestionBody(questions: questions) { store.decide(request, $0) }
            case .plan(let plan):
                PlanBody(plan: plan, hasSuggestions: !(request.suggestions ?? []).isEmpty) { store.decide(request, $0) }
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
    let hasSuggestions: Bool
    let onDecide: (Decision) -> Void

    var body: some View {
        ScrollView {
            Text(markdown)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        HStack(spacing: 8) {
            Button("계속 계획") { onDecide(.deny) }
                .buttonStyle(PillButton(tint: .red))
            Button("터미널에서") { onDecide(.terminal) }
                .buttonStyle(PillButton(tint: .gray))
            Spacer()
            if hasSuggestions {
                Button("승인 + 자동 편집") { onDecide(.always) }
                    .buttonStyle(PillButton(tint: .blue))
            }
            Button("계획 승인") { onDecide(.allow) }
                .buttonStyle(PillButton(tint: .green))
        }
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: plan, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(plan)
    }
}

/// AskUserQuestion: 여러 문항은 마법사처럼 한 문항씩
struct QuestionBody: View {
    let questions: [AgentQuestion]
    let onDecide: (Decision) -> Void

    @State private var step = 0
    @State private var selections: [Int: Set<String>] = [:]
    @State private var custom: [Int: String] = [:]
    @State private var warning = false

    var body: some View {
        let question = questions[min(step, questions.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !question.header.isEmpty { Tag(text: question.header) }
                if question.multiSelect { Tag(text: "여러 개 선택") }
                Spacer()
                if questions.count > 1 {
                    Text("\(step + 1) / \(questions.count)").font(.system(size: 10)).foregroundStyle(.secondary)
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
                            selected: selections[question.id, default: []].contains(option.label)
                        ) { toggle(option.label, in: question) }
                    }
                    TextField("직접 입력…", text: Binding(
                        get: { custom[question.id] ?? "" },
                        set: { custom[question.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }
            HStack(spacing: 8) {
                Button("터미널에서") { onDecide(.terminal) }
                    .buttonStyle(PillButton(tint: .gray))
                if warning {
                    Text("모든 질문에 답해 주세요").font(.system(size: 10)).foregroundStyle(.orange)
                }
                Spacer()
                if step > 0 {
                    Button("이전") { step -= 1 }.buttonStyle(PillButton(tint: .gray))
                }
                if step < questions.count - 1 {
                    Button("다음") { step += 1 }.buttonStyle(PillButton(tint: .blue))
                } else {
                    Button("답변 보내기") { submit() }.buttonStyle(PillButton(tint: .green))
                }
            }
        }
    }

    private func toggle(_ label: String, in question: AgentQuestion) {
        var set = selections[question.id, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selections[question.id] = set
        warning = false
    }

    private func submit() {
        var answers: [String: Any] = [:]
        for question in questions {
            let text = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 옵션 순서를 지켜서 보낸다
            var picked = question.options.map(\.label).filter { selections[question.id, default: []].contains($0) }
            if question.multiSelect {
                if !text.isEmpty { picked.append(text) }
                if picked.isEmpty { warning = true; step = question.id; return }
                answers[question.text] = picked
            } else {
                let answer = text.isEmpty ? picked.first : text
                guard let answer else { warning = true; step = question.id; return }
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
    }
}
