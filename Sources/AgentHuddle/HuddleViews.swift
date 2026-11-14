import HuddleCore
import SwiftUI

enum Layout {
    static let pill = CGSize(width: 250, height: 40)
    static let panel = CGSize(width: 380, height: 540)
}

extension Activity {
    var color: Color {
        switch self {
        case .needsYou: return .orange
        case .working: return .green
        case .idle: return .blue
        }
    }
}

struct RootView: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        Group {
            if store.expanded {
                PanelView(store: store)
                    .frame(width: Layout.panel.width, height: Layout.panel.height)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
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
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(store.sessions.prefix(8)) { session in
                        Circle().fill(store.activity(session).color).frame(width: 8, height: 8)
                    }
                }
                Text(summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let limit = store.limits.first {
                    Text("\(limit.key == "five_hour" ? "5h" : "limit") \(Format.percent(limit.usedPercent))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(limit.usedPercent >= 80 ? Color.orange : Color.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(store.needsYouCount > 0 ? Color.orange : Color.primary.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open Agent Huddle")
    }

    private var summary: String {
        if store.sessions.isEmpty { return "No agents running" }
        if store.needsYouCount > 0 { return "\(store.needsYouCount) need\(store.needsYouCount == 1 ? "s" : "") you" }
        let working = store.sessions.filter { store.activity($0) == .working }.count
        return "\(store.sessions.count) agent\(store.sessions.count == 1 ? "" : "s"), \(working) working"
    }
}

// MARK: Panel

struct PanelView: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent Huddle").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    store.expanded = false
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Shrink to a pill")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            LimitsView(store: store)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()

            if let session = store.session(store.selected) {
                DetailView(store: store, session: session)
            } else {
                SessionList(store: store)
            }
        }
    }
}

struct LimitsView: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        if store.limits.isEmpty {
            Text("Usage limits show here after your next message in a terminal session.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                ForEach(store.limits) { limit in
                    VStack(spacing: 3) {
                        HStack {
                            Text(limit.label)
                            Spacer()
                            Text("\(Format.percent(limit.usedPercent)) used, \(Format.reset(limit.resetsAt, now: store.now))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11).monospacedDigit())
                        Meter(fraction: limit.usedPercent / 100)
                    }
                }
            }
        }
    }
}

struct Meter: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }

    private var color: Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return .accentColor
    }
}

// MARK: List

struct SessionList: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        if store.sessions.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text("No Claude Code sessions are running").font(.system(size: 12, weight: .medium))
                Text("Start one and it appears here.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.sessions) { session in
                        SessionRow(store: store, session: session)
                        Divider().padding(.leading, 34)
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    @ObservedObject var store: HuddleStore
    var session: AgentSession

    var body: some View {
        let activity = store.activity(session)
        Button {
            store.selected = session.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(activity.color).frame(width: 10, height: 10).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(session.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(session.info.project).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(activity == .needsYou ? needText : session.currentStep)
                        .font(.system(size: 11))
                        .foregroundStyle(activity == .needsYou ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    UsageLine(session: session)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var needText: String {
        guard let request = store.requests(for: session.id).first else { return "Needs you" }
        return request.isQuestion ? "Has a question for you" : "Wants to use \(Format.toolName(request.toolName))"
    }
}

/// "Context 84k (42%) · Output 12k · $1.84"
struct UsageLine: View {
    var session: AgentSession

    var body: some View {
        Text(text).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
    }

    private var text: String {
        var parts: [String] = []
        var context = "Context \(Format.tokens(session.usage.contextTokens))"
        if let percent = session.status?.contextPercent { context += " (\(Format.percent(percent)))" }
        parts.append(context)
        parts.append("Output \(Format.tokens(session.usage.outputTokens))")
        if let cost = session.status?.costUSD { parts.append(Format.cost(cost)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Detail

struct DetailView: View {
    @ObservedObject var store: HuddleStore
    var session: AgentSession

    var body: some View {
        let activity = store.activity(session)
        let requests = store.requests(for: session.id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    store.selected = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("All agents")
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(activity.color).frame(width: 7, height: 7)
                        Text(activity.label).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Open") { store.jump(to: session) }
                    .help("Bring this session's window to the front")
                Button("Hide") { store.dismiss(session) }
                    .help("Remove from the list until this session does something new")
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            HStack {
                UsageLine(session: session)
                Spacer()
                Text(session.status?.model ?? session.usage.model)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Divider()

            if let request = requests.first {
                RequestCard(store: store, request: request, waiting: requests.count)
                Divider()
            }
            Timeline(steps: session.steps, now: store.now)
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
                .padding(14)
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
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 11, weight: step.kind == .text ? .regular : .medium))
                    .foregroundStyle(step.kind == .text ? Color.secondary : Color.primary)
                    .lineLimit(step.kind == .tool ? 1 : 4)
                if !step.detail.isEmpty {
                    Text(step.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text(Format.ago(step.time, now: now)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private var symbol: String {
        switch (step.kind, step.state) {
        case (.prompt, _): return "person.fill"
        case (.text, _): return "text.bubble"
        case (.tool, .running): return "circle.dotted"
        case (.tool, .failed): return "xmark.circle.fill"
        case (.tool, _): return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch (step.kind, step.state) {
        case (.prompt, _): return .accentColor
        case (.tool, .running): return .orange
        case (.tool, .failed): return .red
        case (.tool, _): return .green
        default: return .secondary
        }
    }
}
