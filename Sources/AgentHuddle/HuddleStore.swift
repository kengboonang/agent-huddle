import AppKit
import Foundation
import HuddleCore

/// A session together with everything the widget shows about it.
struct AgentSession: Identifiable {
    var info: SessionInfo
    var steps: [Step] = []
    var usage = Usage()
    var title: String?
    var status: SessionStatus?

    var id: String { info.sessionId }

    var displayName: String {
        if let title, !title.isEmpty { return title }
        return info.name.isEmpty ? info.project : info.name
    }

    var currentStep: String {
        guard let last = steps.last else { return "No activity yet" }
        if last.kind == .tool { return last.detail.isEmpty ? last.title : "\(last.title): \(last.detail)" }
        return last.title
    }
}

enum Activity {
    case needsYou, working, idle

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .idle: return "Waiting for your next message"
        }
    }
}

final class HuddleStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var pending: [PendingRequest] = []
    @Published var limits: [LimitWindow] = []
    @Published var limitsUpdatedAt: Date?
    @Published var expanded = false
    @Published var selected: String?
    @Published var now = Date()

    // What the person has picked or typed on a card but not sent yet.
    @Published var picks: [String: Set<String>] = [:]
    @Published var customText: [String: String] = [:]
    @Published var denyNote: [String: String] = [:]

    /// Called when a session starts waiting on the person.
    var onAttention: (() -> Void)?

    let paths: HuddlePaths
    private let demo: Bool
    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "huddle.scan")
    private var readers: [String: TranscriptReader] = [:]
    private var scanning = false
    private var answered: Set<String> = []
    private var knownPending: Set<String> = []
    private var lastActivity: [String: Activity] = [:]
    private var dismissed: [String: Date] = [:]

    init(paths: HuddlePaths = HuddlePaths(), demo: String? = nil) {
        self.paths = paths
        self.demo = demo != nil
        if let demo {
            Demo.fill(self, mode: demo)
        }
    }

    func start() {
        guard !demo else { return }
        for folder in [paths.huddle, paths.pending, paths.responses, paths.status] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Reading

    func session(_ id: String?) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    func requests(for sessionId: String) -> [PendingRequest] {
        pending.filter { $0.sessionId == sessionId }
    }

    func activity(_ session: AgentSession) -> Activity {
        if !requests(for: session.id).isEmpty { return .needsYou }
        return session.info.rawStatus == "busy" ? .working : .idle
    }

    var needsYouCount: Int {
        sessions.filter { activity($0) == .needsYou }.count
    }

    // MARK: Actions

    func allow(_ request: PendingRequest) {
        respond(request, Decisions.allow(request))
    }

    func alwaysAllow(_ request: PendingRequest) {
        respond(request, Decisions.alwaysAllow(request))
    }

    func deny(_ request: PendingRequest) {
        respond(request, Decisions.deny(note: denyNote[request.id] ?? ""))
    }

    func key(_ request: PendingRequest, _ question: Question) -> String {
        request.id + "|" + question.question
    }

    func toggle(_ request: PendingRequest, _ question: Question, _ label: String) {
        let k = key(request, question)
        var set = picks[k] ?? []
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        picks[k] = set
    }

    func answer(_ request: PendingRequest, _ question: Question) -> String? {
        let k = key(request, question)
        return Decisions.answerText(picked: Array(picks[k] ?? []), options: question.options, custom: customText[k] ?? "")
    }

    func canSend(_ request: PendingRequest) -> Bool {
        let questions = request.questions
        return !questions.isEmpty && questions.allSatisfy { answer(request, $0) != nil }
    }

    func sendAnswers(_ request: PendingRequest) {
        guard canSend(request) else { return }
        var answers: [String: String] = [:]
        for question in request.questions { answers[question.question] = answer(request, question) }
        respond(request, Decisions.answer(request, answers: answers))
    }

    func jump(to session: AgentSession) {
        Jumper.activate(pid: session.info.pid)
    }

    /// Hides a session from the list until it does something new.
    func dismiss(_ session: AgentSession) {
        dismissed[session.id] = session.info.updatedAt
        if selected == session.id { selected = nil }
        sessions.removeAll { $0.id == session.id }
    }

    private func respond(_ request: PendingRequest, _ payload: [String: Any]) {
        answered.insert(request.id)
        pending.removeAll { $0.id == request.id }
        guard !demo, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let target = paths.responses.appendingPathComponent(request.id + ".json")
        let temp = paths.responses.appendingPathComponent(request.id + ".json.part")
        FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: temp, to: target)
    }

    // MARK: Refresh

    private func tick() {
        now = Date()
        try? Data().write(to: paths.heartbeat)
        loadPending()
        loadSessions()
    }

    private func loadPending() {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.pending, includingPropertiesForKeys: nil)) ?? []
        var found: [PendingRequest] = []
        for file in files where file.pathExtension == "json" {
            guard let json = readJSON(file), let request = PendingRequest(json: json) else { continue }
            if request.hookPid > 0, !processAlive(request.hookPid) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if !answered.contains(request.id) { found.append(request) }
        }
        found.sort { $0.createdAt < $1.createdAt }
        let ids = Set(found.map(\.id))
        let fresh = found.filter { !knownPending.contains($0.id) }
        knownPending = ids
        answered.formIntersection(Set(files.map { $0.deletingPathExtension().lastPathComponent }))
        if ids != Set(pending.map(\.id)) { pending = found }
        if let first = fresh.first {
            selected = first.sessionId
            expanded = true
            NSSound(named: "Glass")?.play()
            onAttention?()
        }
    }

    private func loadSessions() {
        guard !scanning else { return }
        scanning = true
        let hidden = dismissed
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.scan(hidden: hidden)
            DispatchQueue.main.async {
                self.scanning = false
                self.apply(result.sessions, result.statuses, result.live)
            }
        }
    }

    private func scan(hidden: [String: Date]) -> (sessions: [AgentSession], statuses: [SessionStatus], live: Set<String>) {
        let now = Date()
        var statusBySession: [String: SessionStatus] = [:]
        let statusFiles = (try? FileManager.default.contentsOfDirectory(at: paths.status, includingPropertiesForKeys: nil)) ?? []
        for file in statusFiles where file.pathExtension == "json" {
            if let json = readJSON(file), let status = StatusFiles.parse(json, now: now) {
                statusBySession[file.deletingPathExtension().lastPathComponent] = status
            }
        }
        let infos = Sessions.load(paths) { processAlive($0) }
        var result: [AgentSession] = []
        for info in infos {
            if let at = hidden[info.sessionId], at == info.updatedAt { continue }
            var session = AgentSession(info: info, status: statusBySession[info.sessionId])
            if readers[info.sessionId] == nil, let path = Sessions.transcriptPath(paths, sessionId: info.sessionId) {
                readers[info.sessionId] = TranscriptReader(path: path)
            }
            if let reader = readers[info.sessionId] {
                reader.refresh()
                session.steps = reader.steps
                session.usage = reader.usage
                session.title = reader.title
            }
            result.append(session)
        }
        let live = Set(infos.map(\.sessionId))
        readers = readers.filter { live.contains($0.key) }
        return (result, Array(statusBySession.values), live)
    }

    private func apply(_ result: [AgentSession], _ statuses: [SessionStatus], _ live: Set<String>) {
        sessions = result
        dismissed = dismissed.filter { live.contains($0.key) }
        if let newest = StatusFiles.newestLimits(statuses) {
            limits = newest.limits.filter { ($0.resetsAt ?? .distantFuture) > now }
            limitsUpdatedAt = newest.updatedAt
        } else {
            limits = []
        }
        if let selected, session(selected) == nil { self.selected = nil }
        var current: [String: Activity] = [:]
        for session in result {
            let state = activity(session)
            current[session.id] = state
            if lastActivity[session.id] == .working, state == .idle {
                NSSound(named: "Pop")?.play()
            }
        }
        lastActivity = current
    }

}

func processAlive(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}
