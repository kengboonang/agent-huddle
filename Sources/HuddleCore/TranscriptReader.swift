import Foundation

/// Follows one session transcript (`.jsonl`) and turns it into timeline steps and token counts.
/// Each call to `refresh()` reads only what was added since the last call.
public final class TranscriptReader {
    public let path: String
    public private(set) var steps: [Step] = []
    public private(set) var title: String?
    public private(set) var usage = Usage()
    /// Progress through the session's task list, when it keeps one.
    public var tasks: TaskProgress? {
        guard !taskList.isEmpty else { return nil }
        let done = taskList.filter { $0.status == "completed" }.count
        let active = taskList.first { $0.status == "in_progress" }
        let current = active.map { $0.active.isEmpty ? $0.title : $0.active }
            ?? taskList.first { $0.status != "completed" }?.title ?? "All done"
        return TaskProgress(done: done, total: taskList.count, current: current)
    }

    /// On first read of a big transcript, only this many bytes from the end are read.
    public var maxInitialBytes: UInt64 = 3_000_000
    public var maxSteps = 200

    private var offset: UInt64 = 0
    private var started = false
    private var outputByMessage: [String: Int] = [:]
    private var taskList: [(id: String, title: String, active: String, status: String)] = []
    private var nextTaskId = 1
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    public init(path: String) {
        self.path = path
    }

    /// Returns true when new lines were read.
    @discardableResult
    public func refresh() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { reset() }
        var skipPartialLine = false
        if !started {
            started = true
            if size > maxInitialBytes {
                offset = size - maxInitialBytes
                skipPartialLine = true
                countUsage(in: handle, upTo: offset)
            }
        }
        guard size > offset else { return false }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return false }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        var lines = complete.split(separator: 0x0A)
        if skipPartialLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines { parse(Data(line)) }
        if steps.count > maxSteps { steps.removeFirst(steps.count - maxSteps) }
        return true
    }

    /// Adds up the tokens in the part of a big transcript whose steps are not shown,
    /// so the output total covers the whole session.
    private func countUsage(in handle: FileHandle, upTo end: UInt64) {
        try? handle.seek(toOffset: 0)
        var carry = Data()
        var position: UInt64 = 0
        let marker = Data("\"output_tokens\"".utf8)
        while position < end {
            let chunk = handle.readData(ofLength: Int(min(1_048_576, end - position)))
            if chunk.isEmpty { break }
            position += UInt64(chunk.count)
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            for line in carry[carry.startIndex..<lastNewline].split(separator: 0x0A) where line.range(of: marker) != nil {
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
                      let message = entry["message"] as? [String: Any] else { continue }
                readUsage(message)
            }
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        // The line that crosses the boundary is skipped by the main read, so finish it here.
        while carry.firstIndex(of: 0x0A) == nil {
            let more = handle.readData(ofLength: 65_536)
            if more.isEmpty { break }
            carry.append(more)
        }
        let last = carry.prefix(upTo: carry.firstIndex(of: 0x0A) ?? carry.endIndex)
        if last.range(of: marker) != nil,
           let entry = (try? JSONSerialization.jsonObject(with: Data(last))) as? [String: Any],
           entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
           let message = entry["message"] as? [String: Any] {
            readUsage(message)
        }
    }

    private func reset() {
        offset = 0
        started = false
        steps = []
        title = nil
        usage = Usage()
        outputByMessage = [:]
        taskList = []
        nextTaskId = 1
    }

    /// Follows the two ways Claude Code keeps a task list: TodoWrite (the whole list each time)
    /// and TaskCreate / TaskUpdate (one task at a time, numbered from 1).
    private func readTasks(_ name: String, _ input: [String: Any]) {
        switch name {
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return }
            taskList = todos.enumerated().map { index, todo in
                (id: "\(index + 1)", title: todo["content"] as? String ?? "", active: todo["activeForm"] as? String ?? "",
                 status: todo["status"] as? String ?? "pending")
            }
        case "TaskCreate":
            taskList.append((id: "\(nextTaskId)", title: input["subject"] as? String ?? "",
                             active: input["activeForm"] as? String ?? "", status: "pending"))
            nextTaskId += 1
        case "TaskUpdate":
            let id = (input["taskId"] as? String) ?? (input["taskId"] as? NSNumber)?.stringValue ?? ""
            guard let at = taskList.firstIndex(where: { $0.id == id }) else { return }
            if let status = input["status"] as? String {
                if status == "deleted" { taskList.remove(at: at); return }
                taskList[at].status = status
            }
            if let subject = input["subject"] as? String { taskList[at].title = subject }
            if let active = input["activeForm"] as? String { taskList[at].active = active }
        default:
            break
        }
    }

    private func parse(_ line: Data) {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = entry["type"] as? String else { return }
        if type == "ai-title" {
            title = entry["aiTitle"] as? String
            return
        }
        guard type == "user" || type == "assistant" else { return }
        // Subagent turns are not part of the main conversation.
        if entry["isSidechain"] as? Bool == true { return }
        let message = entry["message"] as? [String: Any] ?? [:]
        let time = date(entry["timestamp"] as? String)
        let uuid = entry["uuid"] as? String ?? UUID().uuidString
        if type == "assistant" {
            readUsage(message)
            for (index, block) in blocks(message).enumerated() {
                switch block["type"] as? String {
                case "text":
                    let text = Format.oneLine(block["text"] as? String ?? "", limit: 400)
                    if !text.isEmpty {
                        steps.append(Step(id: "\(uuid)-\(index)", kind: .text, state: .info, title: text, time: time))
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    readTasks(name, input)
                    steps.append(Step(id: block["id"] as? String ?? "\(uuid)-\(index)", kind: .tool, state: .running,
                                      title: Format.toolName(name), detail: Self.label(name, input), time: time))
                default:
                    break
                }
            }
        } else {
            if entry["isMeta"] as? Bool == true { return }
            if let text = message["content"] as? String {
                addPrompt(text, id: uuid, time: time)
                return
            }
            for (index, block) in blocks(message).enumerated() {
                switch block["type"] as? String {
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String,
                          let at = steps.lastIndex(where: { $0.id == id }) else { continue }
                    steps[at].state = (block["is_error"] as? Bool == true) ? .failed : .done
                case "text":
                    addPrompt(block["text"] as? String ?? "", id: "\(uuid)-\(index)", time: time)
                default:
                    break
                }
            }
        }
    }

    private func addPrompt(_ text: String, id: String, time: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Lines that start with a tag are wrappers Claude Code adds, not something the person typed.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return }
        steps.append(Step(id: id, kind: .prompt, state: .info, title: Format.oneLine(trimmed, limit: 400), time: time))
    }

    private func readUsage(_ message: [String: Any]) {
        guard let raw = message["usage"] as? [String: Any] else { return }
        func number(_ key: String) -> Int { (raw[key] as? NSNumber)?.intValue ?? 0 }
        usage.contextTokens = number("input_tokens") + number("cache_creation_input_tokens") + number("cache_read_input_tokens")
        if let model = message["model"] as? String, !model.hasPrefix("<") { usage.model = model }
        // One reply is written as several lines that repeat the same usage, so count each message id once.
        let id = message["id"] as? String ?? UUID().uuidString
        let output = number("output_tokens")
        usage.outputTokens += output - (outputByMessage[id] ?? 0)
        outputByMessage[id] = output
    }

    private func blocks(_ message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]] ?? []
    }

    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    /// A short description of a tool call, such as the command or the file name.
    public static func label(_ name: String, _ input: [String: Any]) -> String {
        func string(_ key: String) -> String? { input[key] as? String }
        switch name {
        case "Bash", "PowerShell", "Monitor":
            return Format.oneLine(string("description") ?? string("command") ?? "")
        case "Read", "Edit", "Write", "NotebookEdit":
            return ((string("file_path") ?? string("notebook_path") ?? "") as NSString).lastPathComponent
        case "Grep", "Glob":
            return Format.oneLine(string("pattern") ?? "")
        case "WebFetch":
            return URL(string: string("url") ?? "")?.host ?? ""
        case "WebSearch":
            return Format.oneLine(string("query") ?? "")
        case "Agent", "Task":
            return Format.oneLine(string("description") ?? "")
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return Format.oneLine(first ?? "")
        default:
            return Format.oneLine(string("description") ?? string("query") ?? string("skill") ?? "")
        }
    }
}
