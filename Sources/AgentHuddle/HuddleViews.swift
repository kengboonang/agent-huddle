import HuddleCore
import SwiftUI

enum Layout {
    static let pill = CGSize(width: 280, height: 46)
    static let panelWidth: CGFloat = 390
    /// The open panel is as tall as its content, up to this.
    static let maxPanelHeight: CGFloat = 640
    static let emptyListHeight: CGFloat = 170
}

extension Activity {
    var color: Color {
        switch self {
        case .needsYou: return .orange
        case .working: return .green
        case .idle: return .blue
        }
    }

    var short: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    func reportHeight<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { Color.clear.preference(key: key, value: $0.size.height) })
    }
}

struct RootView: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        Group {
            if store.expanded {
                PanelView(store: store)
                    .frame(width: Layout.panelWidth, height: store.panelHeight)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                PillView(store: store)
                    .frame(width: Layout.pill.width, height: Layout.pill.height)
            }
        }
    }
}

// MARK: Pill

struct PillView: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        Button {
            store.expanded = true
        } label: {
            HStack(spacing: 6) {
                HStack(spacing: -4) {
                    ForEach(store.ordered.prefix(5)) { session in
                        BuddyView(traits: session.buddy, activity: store.activity(session), size: 30)
                    }
                }
                Text(summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let limit = store.limits.first {
                    Text("\(limit.key == "five_hour" ? "5h" : "limit") \(Format.percent(limit.usedPercent))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(limit.usedPercent >= 80 ? Color.orange : Color.secondary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(store.needsYouCount > 0 ? Color.orange : Color.primary.opacity(0.15),
                                            lineWidth: store.needsYouCount > 0 ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open Agent Huddle")
    }

    private var summary: String {
        if store.sessions.isEmpty { return "No agents running" }
        if store.needsYouCount > 0 { return "\(store.needsYouCount) need\(store.needsYouCount == 1 ? "s" : "") you" }
        let working = store.sessions.filter { store.activity($0) == .working }.count
        return working == 0 ? "All idle" : "\(working) working"
    }
}

// MARK: Panel

struct PanelView: View {
    @ObservedObject var store: HuddleStore
    @State private var headerHeight: CGFloat = 110
    @State private var listHeight: CGFloat = Layout.emptyListHeight

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                LimitsView(store: store)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                Divider()
            }
            .reportHeight(HeaderHeightKey.self)

            if store.sessions.isEmpty {
                EmptyList().frame(height: Layout.emptyListHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.ordered) { session in
                                SessionRow(store: store, session: session).id(session.id)
                            }
                        }
                        .padding(10)
                        .reportHeight(ListHeightKey.self)
                    }
                    .onChange(of: store.selected) { _, selected in
                        if let selected { withAnimation { proxy.scrollTo(selected, anchor: .top) } }
                    }
                }
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0; resize() }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0; resize() }
        .onChange(of: store.sessions.isEmpty) { _, _ in resize() }
        .onAppear { resize() }
    }

    private func resize() {
        let list = store.sessions.isEmpty ? Layout.emptyListHeight : listHeight
        let height = min(Layout.maxPanelHeight, max(120, (headerHeight + list).rounded(.up)))
        if abs(height - store.panelHeight) > 0.5 {
            DispatchQueue.main.async { store.panelHeight = height }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(store.needsYouCount > 0 ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text("Agent Huddle").font(.system(size: 13, weight: .semibold))
            Text("\(store.sessions.count)").font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            ForEach([Activity.needsYou, .working, .idle], id: \.self) { activity in
                let count = store.sessions.filter { store.activity($0) == activity }.count
                if count > 0 { CountChip(count: count, activity: activity) }
            }
            Spacer()
            HeaderButton(symbol: store.muted ? "speaker.slash" : "speaker.wave.2",
                         help: store.muted ? "Sounds are off. Click to turn them on" : "Sounds are on. Click to turn them off") {
                store.muted.toggle()
            }
            HeaderButton(symbol: "chevron.up", help: "Shrink to a pill") { store.expanded = false }
            HeaderButton(symbol: "xmark", help: "Hide the widget. Bring it back from the menu bar icon") { store.onClose?() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct HeaderButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct CountChip: View {
    var count: Int
    var activity: Activity

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(activity.color).frame(width: 6, height: 6)
            Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(activity.color.opacity(0.15)))
        .help("\(count) \(activity.short.lowercased())")
    }
}

/// The usage limits, side by side.
struct LimitsView: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        if store.limits.isEmpty {
            Text("Usage limits show here after your next message in a terminal session.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                ForEach(store.limits) { limit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(limit.label).font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.percent(limit.usedPercent)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        Meter(fraction: limit.usedPercent / 100)
                        Text(Format.reset(limit.resetsAt, now: store.now))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }
}

struct Meter: View {
    var fraction: Double
    var height: CGFloat = 4
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }

    private var color: Color {
        if let tint { return tint }
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return .accentColor
    }
}

struct EmptyList: View {
    var body: some View {
        VStack(spacing: 6) {
            BuddyView(traits: BuddyTraits(seed: "nobody home"), activity: .idle, size: 64)
            Text("No Claude Code sessions are running").font(.system(size: 12, weight: .medium))
            Text("Start one and its buddy shows up here.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Rows

/// One session. Click it to open it in place: its request, if it has one, and its latest steps.
struct SessionRow: View {
    @ObservedObject var store: HuddleStore
    var session: AgentSession
    @State private var hovering = false

    var body: some View {
        let activity = store.activity(session)
        let requests = store.requests(for: session.id)
        let request = requests.first
        let open = store.selected == session.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Button {
                    store.toggleSelection(session.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        BuddyView(traits: session.buddy, activity: activity, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            statusLine(request)
                            progressLine
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(spacing: 0) {
                    RowButton(symbol: "arrow.up.forward.app", help: "Go to the window where this session is running") {
                        store.jump(to: session)
                    }
                    .disabled(session.info.pid <= 0)
                    RowButton(symbol: "xmark", help: "Cross this session off the list until it does something new") {
                        store.dismiss(session)
                    }
                    .disabled(request != nil)
                }
            }

            if let request, !open {
                QuickActions(store: store, request: request, session: session)
            }
            if open {
                if let request {
                    RequestCard(store: store, request: request, waiting: requests.count, session: session)
                        .disabled(!store.armed)
                }
                SessionDetail(store: store, session: session)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering || open ? 0.08 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(request == nil ? Color.clear : Color.orange.opacity(0.8), lineWidth: 1.5))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func statusLine(_ request: PendingRequest?) -> some View {
        if let request {
            Text(needText(request)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange).lineLimit(1)
            if !request.isQuestion, !request.isPlan, !request.summary.isEmpty, store.selected != session.id {
                // The exact command or path, never a description of it.
                Text(request.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(QuickActions.maxLines)
                    .multilineTextAlignment(.leading)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
        } else if let said = store.feedback[session.id] {
            Label(said, systemImage: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green).lineLimit(1)
        } else {
            Text(session.currentStep).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Progress through the session's task list when it has one; otherwise how full its context is.
    private var progressLine: some View {
        HStack(spacing: 6) {
            if let tasks = session.tasks {
                Text("\(tasks.done)/\(tasks.total)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.green)
                Text(tasks.current).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Meter(fraction: tasks.total == 0 ? 0 : Double(tasks.done) / Double(tasks.total), height: 3, tint: .green)
                    .frame(width: 70)
            } else {
                if let percent = session.status?.contextPercent {
                    Meter(fraction: percent / 100, height: 3).frame(width: 44)
                }
                UsageLine(session: session)
                Spacer(minLength: 0)
            }
        }
    }

    private func needText(_ request: PendingRequest) -> String {
        if request.isQuestion { return "asks a question" }
        if request.isPlan { return "has a plan to approve" }
        return "needs permission: \(Format.toolName(request.toolName))"
    }
}

struct RowButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Lets the person answer a permission request straight from the closed row.
struct QuickActions: View {
    @ObservedObject var store: HuddleStore
    var request: PendingRequest
    var session: AgentSession

    static let maxLines = 3
    static let maxCharacters = 130

    /// Allow and Deny are offered on the row only when the whole request is visible there.
    static func fitsOnRow(_ request: PendingRequest) -> Bool {
        let text = request.summary
        return !text.isEmpty && text.count <= maxCharacters && !text.contains(where: \.isNewline)
    }

    var body: some View {
        HStack {
            let waiting = store.requests(for: session.id).count
            if waiting > 1 {
                Text("\(waiting) waiting").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if request.isQuestion || request.isPlan {
                Button(request.isQuestion ? "Answer" : "Review plan") { store.selected = session.id }
                    .buttonStyle(.borderedProminent)
            } else if Self.fitsOnRow(request) {
                Button("More choices") { store.selected = session.id }
                Button("Deny") { store.deny(request) }
                Button("Allow") { store.allow(request) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Read and decide") { store.selected = session.id }
                    .buttonStyle(.borderedProminent)
                    .help("This request is too long to show here in full")
            }
        }
        .controlSize(.small)
        .disabled(!store.armed)
    }
}

/// "84k (42%) · out 12k · $1.84"
struct UsageLine: View {
    var session: AgentSession
    var long = false

    var body: some View {
        Text(text).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
    }

    private var text: String {
        var parts: [String] = []
        var context = "\(long ? "Context " : "")\(Format.tokens(session.usage.contextTokens))"
        if let percent = session.status?.contextPercent { context += " (\(Format.percent(percent)))" }
        parts.append(context)
        parts.append("\(long ? "Output" : "out") \(Format.tokens(session.usage.outputTokens))")
        if let cost = session.status?.costUSD { parts.append(Format.cost(cost)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Open row

/// What an open row shows under its request: token use and the latest steps.
struct SessionDetail: View {
    @ObservedObject var store: HuddleStore
    var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let percent = session.status?.contextPercent {
                    Meter(fraction: percent / 100, height: 3).frame(width: 50)
                }
                UsageLine(session: session, long: true)
                Spacer(minLength: 4)
                if let evidence = session.evidence {
                    Button("Sources") { NSWorkspace.shared.open(evidence) }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .help("Open the log of every web search and page this session read")
                }
            }
            HStack(spacing: 6) {
                Text(session.buddy.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(session.info.project).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                Text(session.status?.model ?? session.usage.model).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Timeline(steps: session.steps, now: store.now)
                .frame(height: session.steps.isEmpty ? 24 : min(CGFloat(session.steps.count) * 34 + 8, 190))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
        }
    }
}

struct Timeline: View {
    var steps: [Step]
    var now: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if steps.isEmpty {
                        Text("No steps yet").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(steps) { step in
                        StepRow(step: step, now: now).id(step.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(steps.last?.id, anchor: .bottom) }
            .onChange(of: steps.last?.id) { _, last in
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

struct StepRow: View {
    var step: Step
    var now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if step.kind == .tool, step.state == .running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
                }
            }
            .frame(width: 14, height: 14)
            .padding(.top, 1)
            Group {
                if step.kind == .tool {
                    Text(step.title).font(.system(size: 11, weight: .medium))
                        + Text(step.detail.isEmpty ? "" : "  \(step.detail)").font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    Text(step.title)
                        .font(.system(size: 11, weight: step.kind == .prompt ? .medium : .regular))
                        .foregroundStyle(step.kind == .text ? Color.secondary : Color.primary)
                }
            }
            .lineLimit(step.kind == .tool ? 1 : 3)
            Spacer(minLength: 4)
            Text(Format.ago(step.time, now: now)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private var symbol: String {
        switch (step.kind, step.state) {
        case (.prompt, _): return "person.fill"
        case (.text, _): return "text.bubble"
        case (.tool, .failed): return "xmark.circle.fill"
        case (.tool, _): return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch (step.kind, step.state) {
        case (.prompt, _): return .accentColor
        case (.tool, .failed): return .red
        case (.tool, _): return .green
        default: return .secondary
        }
    }
}
