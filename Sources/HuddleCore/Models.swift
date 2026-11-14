import Foundation

/// Where Claude Code and Agent Huddle keep their files.
public struct HuddlePaths {
    public let claude: URL

    public init(claude: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claude = claude
    }

    public var sessions: URL { claude.appendingPathComponent("sessions") }
    public var projects: URL { claude.appendingPathComponent("projects") }
    public var huddle: URL { claude.appendingPathComponent("huddle") }
    public var pending: URL { huddle.appendingPathComponent("pending") }
    public var responses: URL { huddle.appendingPathComponent("responses") }
    public var status: URL { huddle.appendingPathComponent("status") }
    public var heartbeat: URL { huddle.appendingPathComponent("app.heartbeat") }
}

/// One live Claude Code session, read from `~/.claude/sessions/<pid>.json`.
public struct SessionInfo: Identifiable, Equatable {
    public var id: String { sessionId }
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var name: String
    public var rawStatus: String
    public var entrypoint: String
    public var startedAt: Date
    public var updatedAt: Date

    public init(pid: Int32, sessionId: String, cwd: String, name: String, rawStatus: String,
                entrypoint: String, startedAt: Date, updatedAt: Date) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.rawStatus = rawStatus
        self.entrypoint = entrypoint
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var project: String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }
}

public enum StepKind: Equatable { case prompt, text, tool }
public enum StepState: Equatable { case running, done, failed, info }

/// One line in a session's step-by-step timeline.
public struct Step: Identifiable, Equatable {
    public var id: String
    public var kind: StepKind
    public var state: StepState
    public var title: String
    public var detail: String
    public var time: Date?

    public init(id: String, kind: StepKind, state: StepState, title: String, detail: String = "", time: Date? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.title = title
        self.detail = detail
        self.time = time
    }
}

/// Token counts for one session, taken from its transcript.
public struct Usage: Equatable {
    /// Tokens in the context window on the latest request (input + cache read + cache write).
    public var contextTokens = 0
    /// Output tokens added up over the whole session.
    public var outputTokens = 0
    public var model = ""

    public init() {}
}

/// One rate-limit window (5-hour, weekly or spend limit).
public struct LimitWindow: Identifiable, Equatable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(key: String, label: String, usedPercent: Double, resetsAt: Date?) {
        self.key = key
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// What the status line script saved for one session.
public struct SessionStatus: Equatable {
    public var updatedAt: Date
    public var model: String?
    public var contextPercent: Double?
    public var contextSize: Int?
    public var costUSD: Double?
    public var limits: [LimitWindow]

    public init(updatedAt: Date, model: String? = nil, contextPercent: Double? = nil, contextSize: Int? = nil,
                costUSD: Double? = nil, limits: [LimitWindow] = []) {
        self.updatedAt = updatedAt
        self.model = model
        self.contextPercent = contextPercent
        self.contextSize = contextSize
        self.costUSD = costUSD
        self.limits = limits
    }
}

public struct QuestionOption: Equatable {
    public var label: String
    public var description: String
}

public struct Question: Identifiable, Equatable {
    public var id: String { question }
    public var question: String
    public var header: String
    public var options: [QuestionOption]
    public var multiSelect: Bool
}

/// A permission prompt or question that a session is waiting on.
public struct PendingRequest: Identifiable {
    public var id: String
    public var sessionId: String
    public var cwd: String
    public var toolName: String
    public var toolInput: [String: Any]
    public var suggestions: [[String: Any]]
    public var agentType: String?
    public var createdAt: Date
    public var hookPid: Int32

    public init(id: String, sessionId: String, cwd: String = "", toolName: String, toolInput: [String: Any] = [:],
                suggestions: [[String: Any]] = [], agentType: String? = nil, createdAt: Date = Date(), hookPid: Int32 = 0) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.suggestions = suggestions
        self.agentType = agentType
        self.createdAt = createdAt
        self.hookPid = hookPid
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let sessionId = json["sessionId"] as? String,
              let toolName = json["toolName"] as? String else { return nil }
        self.init(id: id, sessionId: sessionId, cwd: json["cwd"] as? String ?? "", toolName: toolName,
                  toolInput: json["toolInput"] as? [String: Any] ?? [:],
                  suggestions: json["suggestions"] as? [[String: Any]] ?? [],
                  agentType: json["agentType"] as? String,
                  createdAt: Date(timeIntervalSince1970: (json["createdAt"] as? NSNumber)?.doubleValue ?? 0),
                  hookPid: (json["hookPid"] as? NSNumber)?.int32Value ?? 0)
    }

    public var isQuestion: Bool { toolName == "AskUserQuestion" }
    public var isPlan: Bool { toolName == "ExitPlanMode" }

    public var questions: [Question] {
        guard let raw = toolInput["questions"] as? [[String: Any]] else { return [] }
        return raw.compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> QuestionOption? in
                guard let label = o["label"] as? String else { return nil }
                return QuestionOption(label: label, description: o["description"] as? String ?? "")
            }
            return Question(question: text, header: q["header"] as? String ?? "", options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// The part of the request a person needs to read before deciding.
    public var summary: String {
        switch toolName {
        case "Bash", "PowerShell", "Monitor":
            return toolInput["command"] as? String ?? ""
        case "Edit", "Write", "Read", "NotebookEdit":
            return toolInput["file_path"] as? String ?? toolInput["notebook_path"] as? String ?? ""
        case "WebFetch":
            return toolInput["url"] as? String ?? ""
        case "WebSearch":
            return toolInput["query"] as? String ?? ""
        case "ExitPlanMode":
            return toolInput["plan"] as? String ?? ""
        default:
            guard !toolInput.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    public var note: String { toolInput["description"] as? String ?? "" }
}

public func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
