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
    var tasks: TaskProgress?
    /// The evidence log for this session, when web tools have been used.
    var evidence: URL?

    var id: String { info.sessionId }
    var buddy: BuddyTraits { BuddyTraits(seed: info.sessionId) }

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

enum Activity: Int {
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

    /// False for a moment after the request on screen changes, so a click meant for one request
    /// cannot land on another that has just taken its place.
    @Published var armed = true
    /// A short confirmation shown on a row after the person answers, such as "Allowed".
    @Published var feedback: [String: String] = [:]
    /// Height of the open panel, which follows its content up to a limit.
    @Published var panelHeight: CGFloat = 300
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    /// Called when the person closes the widget from its header.
    var onClose: (() -> Void)?

    /// Called when a session starts waiting on the person.
    var onAttention: (() -> Void)?

    let paths: HuddlePaths
    private let demo: Bool
    private var timer: Timer?
    private var heartbeatTimer: DispatchSourceTimer?
    /// True when this instance is the real widget, which owns the heartbeat file.
    private(set) var ownsHeartbeat = false
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

    /// `heartbeat: false` reads the live data without telling hooks that a widget is there to answer.
    func start(heartbeat: Bool = true) {
        guard !demo else { return }
        for folder in [paths.huddle, paths.pending, paths.responses, paths.status] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        if heartbeat {
            // The heartbeat has its own background timer, so an open menu or a busy main thread
            // cannot make hooks think the widget has quit.
            ownsHeartbeat = true
            let beat = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            let file = paths.heartbeat
            beat.schedule(deadline: .now(), repeating: 1)
            beat.setEventHandler { try? Data().write(to: file) }
            beat.resume()
            heartbeatTimer = beat
        }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        if ownsHeartbeat { try? FileManager.default.removeItem(at: paths.heartbeat) }
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

    /// Sessions that need you come first, then the ones working, then the idle ones.
    var ordered: [AgentSession] {
        sessions.enumerated().sorted { a, b in
            let (x, y) = (activity(a.element).rawValue, activity(b.element).rawValue)
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    var needsYouCount: Int {
        sessions.filter { activity($0) == .needsYou }.count
    }

    // MARK: Actions

    func allow(_ request: PendingRequest) {
        respond(request, Decisions.allow(request), say: request.isPlan ? "Plan approved" : "Allowed")
    }

    func alwaysAllow(_ request: PendingRequest) {
        respond(request, Decisions.alwaysAllow(request), say: "Always allowed")
    }

    func deny(_ request: PendingRequest) {
        respond(request, Decisions.deny(note: denyNote[request.id] ?? ""), say: "Denied")
    }

    func toggleSelection(_ id: String) {
        selected = selected == id ? nil : id
    }

    private func play(_ name: String) {
        if !muted { NSSound(named: name)?.play() }
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
        let said = request.questions.count == 1 ? "Using \u{201C}\(answers.values.first ?? "")\u{201D}" : "Answered"
        respond(request, Decisions.answer(request, answers: answers), say: said)
    }

    func jump(to session: AgentSession) {
        Jumper.activate(pid: session.info.pid, cwd: session.info.cwd)
    }

    /// Hides a session from the list until it does something new.
    func dismiss(_ session: AgentSession) {
        // A session that is waiting on the person must stay visible.
        guard requests(for: session.id).isEmpty else { return }
        dismissed[session.id] = session.info.updatedAt
        if selected == session.id { selected = nil }
        sessions.removeAll { $0.id == session.id }
    }

    private func respond(_ request: PendingRequest, _ payload: [String: Any], say: String) {
        guard armed else { return }
        defer {
            if answered.contains(request.id) {
                let session = request.sessionId
                feedback[session] = say
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.feedback[session] == say { self?.feedback[session] = nil }
                }
            }
        }
        if !demo {
            // The card goes away only once the answer is really on disk.
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            let target = paths.responses.appendingPathComponent(request.id + ".json")
            let temp = paths.responses.appendingPathComponent(request.id + ".json.part")
            try? FileManager.default.createDirectory(at: paths.responses, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { NSSound.beep(); return }
            try? FileManager.default.removeItem(at: target)
            do { try FileManager.default.moveItem(at: temp, to: target) } catch { NSSound.beep(); return }
        }
        answered.insert(request.id)
        pending.removeAll { $0.id == request.id }
        pause()
    }

    /// Switches the answer buttons off for a moment.
    private func pause() {
        armed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.armed = true }
    }

    /// A request whose session is hidden or not in the list still needs a row, so it can be answered.
    private func withPlaceholders(_ list: [AgentSession]) -> [AgentSession] {
        var list = list
        for request in pending where !list.contains(where: { $0.id == request.sessionId }) {
            let info = SessionInfo(pid: 0, sessionId: request.sessionId, cwd: request.cwd, name: "",
                                   rawStatus: "busy", entrypoint: "", startedAt: request.createdAt, updatedAt: request.createdAt)
            list.append(AgentSession(info: info))
        }
        return list
    }

    // MARK: Refresh

    private func tick() {
        now = Date()
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
        let onDisk = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        answered.formIntersection(onDisk)
        sweepResponses(keeping: onDisk)
        if ids != Set(pending.map(\.id)) {
            // What is on screen is about to change, so hold the buttons for a moment.
            if !pending.isEmpty || !fresh.isEmpty { pause() }
            pending = found
            for request in found { dismissed[request.sessionId] = nil }
            sessions = withPlaceholders(sessions)
        }
        if let first = fresh.first {
            // Do not pull the person away from a request they are reading or answering.
            let busyAnswering = selected.map { !requests(for: $0).filter { $0.id != first.id }.isEmpty } ?? false
            if !busyAnswering { selected = first.sessionId }
            expanded = true
            play("Glass")
            onAttention?()
        }
    }

    /// Removes answers that no hook is waiting for any more.
    private func sweepResponses(keeping ids: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.responses, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !ids.contains(file.deletingPathExtension().lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > 5 { try? FileManager.default.removeItem(at: file) }
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
            let evidence = Evidence.file(cwd: info.cwd, sessionId: info.sessionId)
            if FileManager.default.fileExists(atPath: evidence.path) { session.evidence = evidence }
            if readers[info.sessionId] == nil, let path = Sessions.transcriptPath(paths, sessionId: info.sessionId) {
                readers[info.sessionId] = TranscriptReader(path: path)
            }
            if let reader = readers[info.sessionId] {
                reader.refresh()
                session.steps = reader.steps
                session.usage = reader.usage
                session.tasks = reader.tasks
                session.title = reader.title
            }
            result.append(session)
        }
        let live = Set(infos.map(\.sessionId))
        readers = readers.filter { live.contains($0.key) }
        return (result, Array(statusBySession.values), live)
    }

    private func apply(_ result: [AgentSession], _ statuses: [SessionStatus], _ live: Set<String>) {
        sessions = withPlaceholders(result.filter { dismissed[$0.id] == nil })
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
                play("Pop")
            }
        }
        lastActivity = current
    }

}

func processAlive(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}
