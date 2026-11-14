import HuddleCore
import SwiftUI

/// The card shown when a session is waiting on the person: a permission prompt, a plan or a question.
struct RequestCard: View {
    @ObservedObject var store: HuddleStore
    var request: PendingRequest
    var waiting: Int

    /// Shows the whole card when it fits and scrolls it when it does not.
    var body: some View {
        ViewThatFits(in: .vertical) {
            card
            ScrollView { card }
        }
        .background(Color.orange.opacity(0.08))
        .layoutPriority(1)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heading).font(.system(size: 12, weight: .semibold))
                if let agent = request.agentType, !agent.isEmpty {
                    Text("from \(agent)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if waiting > 1 {
                    Text("1 of \(waiting)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if request.isQuestion {
                QuestionBody(store: store, request: request)
            } else {
                PermissionBody(store: store, request: request)
            }
        }
        .padding(14)
    }

    private var heading: String {
        if request.isQuestion { return "Question" }
        if request.isPlan { return "Plan ready for approval" }
        return "Allow \(Format.toolName(request.toolName))?"
    }
}

struct PermissionBody: View {
    @ObservedObject var store: HuddleStore
    var request: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !request.note.isEmpty {
                Text(request.note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !request.summary.isEmpty {
                ScrollView { summaryText }
                    .frame(height: summaryHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            Text(request.isPlan ? "Approve this plan?" : "Do you want to proceed?")
                .font(.system(size: 11, weight: .medium))
            ChoiceRow(number: 1, title: request.isPlan ? "Yes, approve the plan" : "Yes") { store.allow(request) }
            if canAlwaysAllow {
                ChoiceRow(number: 2, title: "Yes, and don't ask again", detail: Decisions.describe(request.suggestions)) {
                    store.alwaysAllow(request)
                }
            }
            ChoiceRow(number: canAlwaysAllow ? 3 : 2, title: "No") { store.deny(request) }
            HStack(spacing: 6) {
                TextField("No, and tell Claude what to do differently", text: Binding(
                    get: { store.denyNote[request.id] ?? "" },
                    set: { store.denyNote[request.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { if hasNote { store.deny(request) } }
                Button {
                    store.deny(request)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .disabled(!hasNote)
                .help("Deny and send this note to Claude")
            }
        }
    }

    private var canAlwaysAllow: Bool { !request.suggestions.isEmpty && !request.isPlan }

    private var hasNote: Bool {
        !(store.denyNote[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One numbered choice, laid out like the choices in Claude Code's own prompts.
struct ChoiceRow: View {
    var number: Int
    var title: String
    var detail: String = ""
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .medium))
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.14 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension PermissionBody {
    /// Tall enough for the text, up to a limit; longer text scrolls.
    var summaryHeight: CGFloat {
        let perLine = request.isPlan ? 56 : 50
        let lines = request.summary.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
        return CGFloat(min(lines, request.isPlan ? 11 : 5)) * 14 + 18
    }

    var summaryText: some View {
        Text(request.summary)
            .font(.system(size: 11, design: request.isPlan ? .default : .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }
}

struct QuestionBody: View {
    @ObservedObject var store: HuddleStore
    var request: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(request.questions) { question in
                questionView(question)
            }
            HStack {
                Spacer()
                Button("Send answer") { store.sendAnswers(request) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canSend(request))
            }
            .controlSize(.small)
        }
    }

    private func questionView(_ question: Question) -> some View {
        let key = store.key(request, question)
        return VStack(alignment: .leading, spacing: 5) {
            Text(question.question).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if question.multiSelect {
                Text("Pick any that apply").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(question.options, id: \.label) { option in
                optionRow(question, option, selected: store.picks[key]?.contains(option.label) ?? false)
            }
            TextField("Other: type your own answer", text: Binding(
                get: { store.customText[key] ?? "" },
                set: { store.customText[key] = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }

    private func optionRow(_ question: Question, _ option: QuestionOption, selected: Bool) -> some View {
        Button {
            store.toggle(request, question, option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol(question.multiSelect, selected))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 12))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 11, weight: .medium))
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func symbol(_ multi: Bool, _ selected: Bool) -> String {
        if multi { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}
