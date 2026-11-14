import HuddleCore
import SwiftUI

enum Layout {
    static let pill = CGSize(width: 280, height: 46)
    static let panel = CGSize(width: 390, height: 580)
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

struct RootView: View {
    @ObservedObject var store: HuddleStore

    var body: some View {
        Group {
            if store.expanded {
                PanelView(store: store)
                    .frame(width: Layout.panel.width, height: Layout.panel.height)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Agent Huddle").font(.system(size: 13, weight: .semibold))
                ForEach([Activity.needsYou, .working, .idle], id: \.self) { activity in
                    let count = store.sessions.filter { store.activity($0) == activity }.count
                    if count > 0 { CountChip(count: count, activity: activity) }
                }
                Spacer()
                Button {
                    store.expanded = false
                } label: {
                    Image(systemName: "chevron.down").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Shrink to a pill")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            LimitsView(store: store)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            Divider()

            ZStack {
                if let session = store.session(store.selected) {
                    DetailView(store: store, session: session)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    SessionList(store: store)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.selected)
        }
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
            VStack(spacing: 8) {
                Spacer()
                BuddyView(traits: BuddyTraits(seed: "nobody home"), activity: .idle, size: 72)
                Text("No Claude Code sessions are running").font(.system(size: 12, weight: .medium))
                Text("Start one and its buddy shows up here.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.ordered) { session in
                        SessionRow(store: store, session: session)
                    }
                }
                .padding(10)
                .animation(.easeOut(duration: 0.2), value: store.ordered.map(\.id))
            }
        }
    }
}

struct SessionRow: View {
    @ObservedObject var store: HuddleStore
    var session: AgentSession
    @State private var hovering = false

    var body: some View {
        let activity = store.activity(session)
        let request = store.requests(for: session.id).first
        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.selected = session.id
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    BuddyView(traits: session.buddy, activity: activity, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(session.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(activity.short)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(activity.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(activity.color.opacity(0.15)))
                        }
                        Text(request.map(needText) ?? session.currentStep)
                            .font(.system(size: 11))
                            .foregroundStyle(request == nil ? Color.secondary : Color.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            if let percent = session.status?.contextPercent {
                                Meter(fraction: percent / 100, height: 3).frame(width: 44)
                            }
                            UsageLine(session: session)
                            Spacer(minLength: 4)
                            Text(session.info.project).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let request {
                QuickActions(store: store, request: request, session: session)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.09 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(request == nil ? Color.clear : Color.orange.opacity(0.7)))
        .onHover { hovering = $0 }
        .help("\(session.buddy.name) is looking after this session")
    }

    private func needText(_ request: PendingRequest) -> String {
        if request.isQuestion { return "Has a question for you" }
        if request.isPlan { return "Has a plan for you to approve" }
        let what = Format.oneLine(request.note.isEmpty ? request.summary : request.note, limit: 90)
        return "Wants to use \(Format.toolName(request.toolName))" + (what.isEmpty ? "" : ": \(what)")
    }
}

/// Lets the person answer a permission request straight from the list.
struct QuickActions: View {
    @ObservedObject var store: HuddleStore
    var request: PendingRequest
    var session: AgentSession

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
            } else {
                Button("Details") { store.selected = session.id }
                Button("Deny") { store.deny(request) }
                Button("Allow") { store.allow(request) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
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
                    Image(systemName: "chevron.left").frame(width: 20, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("All agents")
                BuddyView(traits: session.buddy, activity: activity, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(session.buddy.name) · \(activity.label)")
                        .font(.system(size: 10)).foregroundStyle(activity == .needsYou ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Open") { store.jump(to: session) }
                    .help("Bring this session's window to the front")
                Button("Hide") { store.dismiss(session) }
                    .help("Remove from the list until this session does something new")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                if let percent = session.status?.contextPercent {
                    Meter(fraction: percent / 100, height: 3).frame(width: 60)
                }
                UsageLine(session: session, long: true)
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
            Group {
                if step.kind == .tool, step.state == .running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
                }
            }
            .frame(width: 14, height: 14)
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
        .padding(step.kind == .prompt ? 8 : 0)
        .background(RoundedRectangle(cornerRadius: 8).fill(step.kind == .prompt ? Color.accentColor.opacity(0.12) : Color.clear))
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
