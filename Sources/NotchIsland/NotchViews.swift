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

/// 노치 전체가 공유하는 움직임 (영상 기준: 0.25초 안팎, 거의 튕기지 않음)
enum NotchMotion {
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
    /// 내용은 노치와 함께 위쪽에서 커지며 나타나고, 닫힐 땐 먼저 사라진다
    static let contentIn = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.86, anchor: .top).combined(with: .opacity)
            .animation(.spring(response: 0.32, dampingFraction: 0.9).delay(0.03)),
        removal: .opacity.animation(.easeIn(duration: 0.08)))
}

/// 노치 안 글꼴·색
enum NotchStyle {
    static let title = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.38)
    static let orange = Color(red: 0.95, green: 0.55, blue: 0.2)
    static let green = Color(red: 0.3, green: 0.85, blue: 0.45)
    static let red = Color(red: 0.78, green: 0.2, blue: 0.22)
    static let cardFill = Color.white.opacity(0.07)
}

enum SilenceAction { case directory, prompt, dismiss }

/// 펼친 내용의 실제 높이를 컨트롤러에 알려 노치 크기를 맞춘다
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchViewModel
    @ObservedObject var prefs: Prefs
    let onJump: (Session) -> Void
    let onToggle: () -> Void
    let onSilence: (Session, SilenceAction) -> Void
    let onSettings: () -> Void
    /// 모양이 움직이는 동안에만 노치 모양으로 자른다 (평소엔 사각형 — 큰 마스크를 매 프레임 그리지 않게)
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
                    .shadow(color: .black.opacity(open ? 0.55 : 0), radius: open ? 20 : 0, y: open ? 10 : 0)
                content(mode)
                    .padding(.horizontal, top)
                    .frame(width: size.width + top * 2, height: size.height, alignment: .top)
                    .clipShape(shaping ? AnyShape(shape) : AnyShape(Rectangle()))
            }
            .frame(width: size.width + top * 2, height: size.height)
            .onChange(of: size) { _, _ in beginShaping() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(ContentHeightKey.self) { height in
            if abs(model.contentHeight - height) > 0.5 { model.contentHeight = height }
        }
    }

    private func beginShaping() {
        shaping = true
        shapingEnd?.cancel()
        let work = DispatchWorkItem { shaping = false }
        shapingEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    @ViewBuilder
    private func content(_ mode: NotchMode) -> some View {
        switch mode {
        case .collapsed:
            CollapsedView(store: store, notchWidth: model.geometry.notchWidth, detailed: prefs.detailedLayout)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
        case .peek:
            if let peek = store.peek {
                measured {
                    PeekContent(store: store, peek: peek, onJump: onJump, onShowAll: {
                        model.showAll = true
                        model.pinned = true
                        store.clearPeek()
                    })
                        .padding(.top, model.geometry.notchHeight + 8)
                }
                .transition(NotchMotion.contentIn)
            }
        case .expanded:
            measured {
                ExpandedView(store: store, model: model, prefs: prefs, onJump: onJump, onSilence: onSilence, onSettings: onSettings)
            }
            .transition(NotchMotion.contentIn)
        }
    }

    /// 자연스러운 높이로 배치하고 그 높이를 잰다
    private func measured<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
    }
}

// MARK: - 접힌 노치

struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    let notchWidth: CGFloat
    let detailed: Bool

    var body: some View {
        if let top = store.sortedSessions.first {
            let side = Metrics.sideWidth(detailed: detailed)
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    AgentIcon(source: top.source, status: top.status, cell: 1.6)
                    if detailed {
                        Text(top.activity)
                            .font(NotchFonts.pixel(13))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentTransition(.opacity)
                    }
                }
                .padding(.leading, detailed ? 14 : 0)
                .frame(width: side, alignment: detailed ? .leading : .center)

                Spacer().frame(width: notchWidth)

                HStack(spacing: 5) {
                    Text("\(store.sessions.count)")
                        .font(NotchFonts.pixel(13))
                        .foregroundStyle(store.pending.isEmpty ? .white : NotchStyle.orange)
                        .contentTransition(.numericText())
                    if detailed {
                        Text(store.sessions.count == 1 ? "session" : "sessions")
                            .font(NotchFonts.pixel(12))
                            .foregroundStyle(NotchStyle.dim)
                    }
                }
                .padding(.trailing, detailed ? 14 : 0)
                .frame(width: side, alignment: detailed ? .trailing : .center)
            }
            .frame(maxHeight: .infinity)
            .animation(NotchMotion.snappy, value: store.sessions.count)
            .animation(.easeInOut(duration: 0.2), value: top.activity)
        } else {
            Color.clear
        }
    }
}

// MARK: - 펼친 노치

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchViewModel
    @ObservedObject var prefs: Prefs
    let onJump: (Session) -> Void
    let onSilence: (Session, SilenceAction) -> Void
    let onSettings: () -> Void

    private static let collapsedLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageHeader(store: store, prefs: prefs, onSettings: onSettings)
                .padding(.horizontal, 6)

            if let request = store.pending.first, let session = store.sessions[request.sessionID], !model.showAll {
                FocusCard(store: store, session: session, request: request, onJump: onJump)
                    .id(request.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                            removal: .opacity))
                showAllButton
            } else if store.sessions.isEmpty {
                Text("No agent sessions yet")
                    .font(NotchStyle.body)
                    .foregroundStyle(NotchStyle.dim)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                sessionList
                if !model.showAll && store.sessions.count > Self.collapsedLimit { showAllButton }
            }
        }
        .padding(.top, model.geometry.notchHeight + 6)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .animation(NotchMotion.snappy, value: store.pending.first?.id)
        .animation(NotchMotion.snappy, value: store.sortedSessions.map(\.id))
        .animation(NotchMotion.snappy, value: model.switcherIndex)
        .animation(NotchMotion.snappy, value: model.showAll)
    }

    @ViewBuilder
    private var sessionList: some View {
        let all = store.sortedSessions
        let visible = model.showAll ? all : Array(all.prefix(Self.collapsedLimit))
        let rows = VStack(spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, session in
                SessionRowView(
                    session: session, highlighted: model.switcherIndex == index, prefs: prefs,
                    onJump: { onJump(session) }, onSilence: { onSilence(session, $0) })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        if model.showAll && all.count > 7 {
            ScrollView { rows }.frame(height: 440)
        } else {
            rows
        }
    }

    private var showAllButton: some View {
        Button {
            model.showAll.toggle()
        } label: {
            Text(model.showAll ? "Show less" : "Show all \(store.sessions.count) sessions")
                .font(NotchStyle.body)
                .foregroundStyle(NotchStyle.dim)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

struct UsageHeader: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var prefs: Prefs
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if prefs.showUsage, let limits = store.rateLimits {
                HStack(spacing: 6) {
                    Text("Claude").foregroundStyle(NotchStyle.dim)
                    if let five = limits.fiveHour { usage("5h", five) }
                    if limits.fiveHour != nil && limits.sevenDay != nil {
                        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 12)
                    }
                    if let week = limits.sevenDay { usage("7d", week) }
                }
                .font(.system(size: 13, weight: .semibold))
            } else {
                Text("Notch Island").font(.system(size: 13, weight: .semibold)).foregroundStyle(NotchStyle.dim)
            }
            Spacer()
            if store.pending.count > 1, store.pending.contains(where: \.isPermission) {
                Button("Allow all \(store.pending.filter(\.isPermission).count)") { store.decideAllPermissions(.allow) }
                    .buttonStyle(ChipButton())
            }
            Button { prefs.soundsEnabled.toggle() } label: {
                Image(systemName: prefs.soundsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 13))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.75))
            .help(prefs.soundsEnabled ? "효과음 끄기" : "효과음 켜기")
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func usage(_ label: String, _ window: RateWindow) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.white.opacity(0.75))
            Text("\(Int(window.usedPercent))%").foregroundStyle(color(window.usedPercent))
            if let reset = window.resetsAt {
                Text(Self.remaining(until: reset))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(NotchStyle.faint)
            }
        }
        .help(window.resetsAt.map { "초기화: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }

    private func color(_ percent: Double) -> Color {
        if percent >= max(prefs.usageThreshold, 90) { return Color(red: 1, green: 0.35, blue: 0.35) }
        if percent >= 60 { return NotchStyle.orange }
        return NotchStyle.green
    }

    /// "2h39m", "1d", "45m"
    static func remaining(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - 세션 카드

/// 카드 윗부분: 아이콘 · 제목 · "You: …" · 태그
struct SessionHeader: View {
    let session: Session
    var showResponse = false
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentIcon(source: session.source, status: session.status, cell: 2.2)
                .frame(width: 44, height: 34, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(NotchStyle.title)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    SessionTags(session: session)
                    if let trailing { trailing }
                }
                if let prompt = session.lastPrompt?.oneLine, !prompt.isEmpty {
                    (Text("You: ").foregroundStyle(NotchStyle.dim) + Text(prompt).foregroundStyle(.white.opacity(0.7)))
                        .font(NotchStyle.body)
                        .lineLimit(1)
                } else if !session.detail.isEmpty {
                    Text(session.detail).font(NotchStyle.body).foregroundStyle(NotchStyle.dim).lineLimit(1)
                }
                if showResponse, let line = responseLine {
                    Text(line)
                        .font(NotchStyle.body)
                        .foregroundStyle(NotchStyle.faint)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
        }
    }

    private var responseLine: String? {
        switch session.status {
        case .running, .compacting: return session.detail.isEmpty ? nil : session.detail
        case .waitingApproval, .waitingInput, .error: return session.detail.isEmpty ? nil : session.detail
        default: return session.lastResponse?.oneLine ?? (session.detail.isEmpty ? nil : session.detail)
        }
    }
}

struct SessionTags: View {
    let session: Session

    var body: some View {
        HStack(spacing: 5) {
            Chip(text: session.sourceLabel)
            if let app = session.terminal.appName { Chip(text: app) }
            Chip(text: Self.age(session.updatedAt))
        }
        .fixedSize()
    }

    /// "<1m", "6m", "2h", "3d"
    static func age(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint.opacity(tint == .white ? 0.6 : 0.95))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(tint == .white ? 0.1 : 0.16)))
            .lineLimit(1)
    }
}

/// 목록의 한 줄: 최근·진행 중이면 카드, 오래된 건 한 줄 요약
struct SessionRowView: View {
    let session: Session
    let highlighted: Bool
    @ObservedObject var prefs: Prefs
    let onJump: () -> Void
    let onSilence: (SilenceAction) -> Void
    @State private var hovering = false

    private var isRecent: Bool {
        switch session.status {
        case .running, .waitingApproval, .waitingInput, .compacting, .error: return true
        case .done, .idle: return Date().timeIntervalSince(session.updatedAt) < 15 * 60
        }
    }

    var body: some View {
        Group {
            if isRecent {
                SessionHeader(session: session, showResponse: true, trailing: hovering ? AnyView(dismissButton) : nil)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
            } else {
                HStack(spacing: 10) {
                    Circle().fill(Color.white.opacity(0.3)).frame(width: 6, height: 6)
                        .frame(width: 44)
                    Text(session.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    SessionTags(session: session)
                    if hovering { dismissButton }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(highlighted ? 0.13 : hovering ? 0.08 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(highlighted ? Color.white.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture { if !prefs.disableClickToJump { onJump() } }
        .contextMenu {
            Button("터미널로 이동", action: onJump)
            Divider()
            if !session.cwd.isEmpty { Button("이 폴더의 세션 숨기기") { onSilence(.directory) } }
            if let prompt = session.firstPrompt, !prompt.isEmpty {
                Button("\"\(String(prompt.prefix(20)))…\"로 시작하면 숨기기") { onSilence(.prompt) }
            }
            Button("카드 닫기") { onSilence(.dismiss) }
        }
    }

    private var dismissButton: some View {
        Button { onSilence(.dismiss) } label: {
            Image(systemName: "archivebox").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotchStyle.dim)
        .help("카드 닫기")
    }
}

// MARK: - 요청 카드 (승인·질문·계획)

struct FocusCard: View {
    @ObservedObject var store: SessionStore
    let session: Session
    let request: PendingRequest
    let onJump: (Session) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SessionHeader(session: session)
                .contentShape(Rectangle())
                .onTapGesture { onJump(session) }
            switch request.kind {
            case .permission:
                PermissionBody(request: request) { store.decide(request, $0) }
            case .question(let questions):
                QuestionBody(questions: questions, draft: store.draft(for: request)) { store.decide(request, $0) }
            case .plan(let plan):
                PlanBody(plan: plan, draft: store.draft(for: request)) { store.decide(request, $0) }
            }
        }
        .padding(.horizontal, 6)
    }
}

/// "⚠ Write" + 코드 상자 + 4버튼
struct PermissionBody: View {
    let request: PendingRequest
    let onDecide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(request.toolName).font(NotchFonts.pixel(14))
            }
            .foregroundStyle(NotchStyle.orange)

            CodeBox(request: request)

            HStack(spacing: 10) {
                Button("Deny") { onDecide(.deny) }
                    .buttonStyle(WideButton(fill: Color.white.opacity(0.13), text: .white))
                Button("Allow Once") { onDecide(.allow) }
                    .buttonStyle(WideButton(fill: Color.white.opacity(0.9), text: .black))
                Button("Allow All") { onDecide(.always) }
                    .buttonStyle(WideButton(fill: NotchStyle.orange, text: .black))
                    .help("이 종류의 요청을 이 세션에서 계속 허용 (Claude가 제안한 규칙)")
                Button("Bypass") { onDecide(.bypass) }
                    .buttonStyle(WideButton(fill: NotchStyle.red, text: .white))
                    .help("이 세션의 권한 확인을 모두 건너뜀")
            }
            Button { onDecide(.terminal) } label: {
                Text("Answer in terminal").font(.system(size: 11)).foregroundStyle(NotchStyle.faint)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// 파일 이름 + 태그 + 줄 번호가 붙은 코드
struct CodeBox: View {
    let request: PendingRequest
    private static let maxLines = 8

    private var parts: (name: String, tag: String?, tagColor: Color, lines: [String]) {
        let input = request.input
        switch request.toolName {
        case "Write":
            let path = input["file_path"] as? String ?? ""
            return ((path as NSString).lastPathComponent, "new file", NotchStyle.green,
                    (input["content"] as? String ?? "").components(separatedBy: "\n"))
        case "Edit", "MultiEdit":
            let path = input["file_path"] as? String ?? ""
            let body = request.preview.components(separatedBy: "\n").dropFirst()
            return ((path as NSString).lastPathComponent, "edit", Color(red: 0.4, green: 0.65, blue: 1), Array(body))
        case "Bash":
            return ("command", input["description"] as? String, NotchStyle.dim,
                    (input["command"] as? String ?? "").components(separatedBy: "\n"))
        default:
            return (request.toolName, nil, NotchStyle.dim, request.preview.components(separatedBy: "\n"))
        }
    }

    var body: some View {
        let info = parts
        let shown = Array(info.lines.prefix(Self.maxLines))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(info.name).font(NotchStyle.mono).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                if let tag = info.tag { Chip(text: tag, tint: info.tagColor) }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").foregroundStyle(NotchStyle.faint).frame(width: 18, alignment: .trailing)
                        Text(line.isEmpty ? " " : line).foregroundStyle(color(for: line)).lineLimit(1)
                    }
                }
                if info.lines.count > shown.count {
                    Text("… +\(info.lines.count - shown.count) lines").foregroundStyle(NotchStyle.faint).padding(.leading, 28)
                }
            }
            .font(NotchStyle.mono)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(NotchStyle.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+ ") { return Color(red: 0.5, green: 0.88, blue: 0.55) }
        if line.hasPrefix("- ") { return Color(red: 1, green: 0.5, blue: 0.5) }
        return .white.opacity(0.9)
    }
}

struct PlanBody: View {
    let plan: String
    @ObservedObject var draft: RequestDraft
    let onDecide: (Decision) -> Void

    /// 계획 승인 뒤 권한 모드 (Claude Code의 setMode 값)
    private static let modes: [(id: String, title: String, help: String)] = [
        ("default", "Manual", "모든 작업을 확인 · 가장 안전"),
        ("acceptEdits", "Auto-edit", "파일 편집은 자동 허용"),
        ("bypassPermissions", "Bypass", "권한 확인을 모두 건너뜀"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard.fill")
                Text("Plan").font(NotchFonts.pixel(14))
            }
            .foregroundStyle(Color(red: 0.4, green: 0.65, blue: 1))

            Text(markdown)
                .font(NotchStyle.body)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(NotchStyle.cardFill))

            HStack(spacing: 6) {
                ForEach(Self.modes, id: \.id) { mode in
                    Button { draft.planMode = mode.id } label: {
                        Text(mode.title)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(draft.planMode == mode.id ? 0.18 : 0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                draft.planMode == mode.id ? (mode.id == "bypassPermissions" ? NotchStyle.red : Color.white.opacity(0.3)) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(mode.help)
                }
            }
            .animation(NotchMotion.snappy, value: draft.planMode)

            TextField("Tell Claude what to change…", text: $draft.feedback)
                .textFieldStyle(.plain)
                .font(NotchStyle.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(NotchStyle.cardFill))

            HStack(spacing: 10) {
                Button("Keep Planning") { onDecide(.denyWithMessage(feedbackMessage)) }
                    .buttonStyle(WideButton(fill: Color.white.opacity(0.13), text: .white))
                Button("Approve") { onDecide(.approvePlan(mode: draft.planMode == "default" ? nil : draft.planMode)) }
                    .buttonStyle(WideButton(fill: Color.white.opacity(0.9), text: .black))
            }
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

/// AskUserQuestion: 여러 문항은 한 문항씩. 쓰던 내용은 draft에 남는다.
struct QuestionBody: View {
    let questions: [AgentQuestion]
    @ObservedObject var draft: RequestDraft
    let onDecide: (Decision) -> Void
    @State private var warning = false

    var body: some View {
        let step = min(draft.step, questions.count - 1)
        let question = questions[step]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                Text(question.header.isEmpty ? "Question" : question.header).font(NotchFonts.pixel(14))
                if question.multiSelect { Chip(text: "multi-select") }
                Spacer()
                if questions.count > 1 {
                    Text("\(step + 1) / \(questions.count)").font(NotchFonts.pixel(12)).foregroundStyle(NotchStyle.dim)
                }
            }
            .foregroundStyle(NotchStyle.orange)

            Text(question.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                    OptionRow(option: option, multi: question.multiSelect,
                              selected: draft.selections[question.id, default: []].contains(option.label)) {
                        toggle(option.label, in: question)
                    }
                }
                TextField("Type or paste an answer…", text: Binding(
                    get: { draft.custom[question.id] ?? "" },
                    set: { draft.custom[question.id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(NotchStyle.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(NotchStyle.cardFill))
            }
            .id(question.id)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            HStack(spacing: 10) {
                Button("Terminal") { onDecide(.terminal) }
                    .buttonStyle(WideButton(fill: Color.white.opacity(0.13), text: .white))
                if step > 0 {
                    Button("Back") { draft.step -= 1 }
                        .buttonStyle(WideButton(fill: Color.white.opacity(0.13), text: .white))
                }
                if step < questions.count - 1 {
                    Button("Next") { draft.step += 1 }
                        .buttonStyle(WideButton(fill: Color.white.opacity(0.9), text: .black))
                } else {
                    Button("Submit") { submit() }
                        .buttonStyle(WideButton(fill: Color.white.opacity(0.9), text: .black))
                }
            }
            if warning {
                Text("Please answer all questions").font(.system(size: 11)).foregroundStyle(NotchStyle.orange)
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
                guard let answer = text.isEmpty ? picked.first : text else { warning = true; draft.step = question.id; return }
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? NotchStyle.orange : NotchStyle.dim)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 12)).foregroundStyle(NotchStyle.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.13 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 알림 카드

struct PeekContent: View {
    @ObservedObject var store: SessionStore
    let peek: Peek
    let onJump: (Session) -> Void
    let onShowAll: () -> Void

    var body: some View {
        Group {
            if peek.kind == .complete, let sid = peek.sessionID, let session = store.sessions[sid] {
                // 영상의 완료 카드: 세션 머리 + "You: … Done" + 응답
                VStack(alignment: .leading, spacing: 12) {
                    SessionHeader(session: session)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            (Text("You: ").foregroundStyle(NotchStyle.dim)
                                + Text(session.lastPrompt?.oneLine ?? "").foregroundStyle(.white.opacity(0.8)))
                                .font(NotchStyle.body)
                                .lineLimit(1)
                            Spacer()
                            Text("Done").font(NotchStyle.body).foregroundStyle(NotchStyle.dim)
                        }
                        Text(session.lastResponse ?? peek.body)
                            .font(NotchStyle.mono)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(NotchStyle.cardFill))
                    if store.sessions.count > 1 {
                        Button(action: onShowAll) {
                            Text("Show all \(store.sessions.count) sessions")
                                .font(NotchStyle.body)
                                .foregroundStyle(NotchStyle.dim)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    onJump(session)
                    store.clearPeek()
                }
            } else {
                PeekView(peek: peek)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let sid = peek.sessionID, let session = store.sessions[sid] { onJump(session) }
                        store.clearPeek()
                    }
            }
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
                        .font(.system(size: 12))
                        .foregroundStyle(NotchStyle.dim)
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
        case .complete: return NotchStyle.green
        case .error: return .red
        case .usage: return NotchStyle.orange
        case .info: return .blue
        }
    }
}

// MARK: - 버튼

/// 같은 폭으로 나눠 갖는 큰 버튼 (Deny / Allow Once / Allow All / Bypass)
struct WideButton: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct ChipButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(NotchStyle.orange.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

extension String {
    /// 여러 줄을 한 줄로
    var oneLine: String {
        replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
