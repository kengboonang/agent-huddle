import Foundation
import Testing
@testable import HuddleCore

private func tempFile(_ lines: [[String: Any]]) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    let text = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        .joined(separator: "\n") + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

private func append(_ path: String, _ line: [String: Any]) throws {
    let handle = FileHandle(forWritingAtPath: path)!
    try handle.seekToEnd()
    try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8))
    try handle.close()
}

private func assistant(id: String, blocks: [[String: Any]], input: Int = 10, cacheRead: Int = 0,
                       cacheWrite: Int = 0, output: Int = 5) -> [String: Any] {
    ["type": "assistant", "uuid": UUID().uuidString, "timestamp": "2026-11-14T10:00:00.000Z",
     "message": ["id": id, "model": "claude-opus-5-5", "content": blocks,
                 "usage": ["input_tokens": input, "cache_read_input_tokens": cacheRead,
                           "cache_creation_input_tokens": cacheWrite, "output_tokens": output]]]
}

@Suite struct TranscriptReaderTests {
    @Test func buildsStepsAndMarksToolResults() throws {
        let path = try tempFile([
            ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "Fix the login bug"]],
            assistant(id: "m1", blocks: [
                ["type": "text", "text": "Looking at the code."],
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/src/login.ts"]],
                ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "npm test", "description": "Run tests"]],
            ]),
            ["type": "user", "uuid": "u2", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "ok"],
                ["type": "tool_result", "tool_use_id": "t2", "content": "boom", "is_error": true],
            ]]],
        ])
        let reader = TranscriptReader(path: path)
        #expect(reader.refresh())
        #expect(reader.steps.map(\.kind) == [.prompt, .text, .tool, .tool])
        #expect(reader.steps[0].title == "Fix the login bug")
        #expect(reader.steps[2].detail == "login.ts")
        #expect(reader.steps[2].state == .done)
        #expect(reader.steps[3].detail == "Run tests")
        #expect(reader.steps[3].state == .failed)
    }

    @Test func skipsWrappersMetaAndSubagentLines() throws {
        let path = try tempFile([
            ["type": "user", "uuid": "u1", "message": ["content": "<system-reminder>ignore</system-reminder>"]],
            ["type": "user", "uuid": "u2", "isMeta": true, "message": ["content": "meta text"]],
            ["type": "user", "uuid": "u3", "isSidechain": true, "message": ["content": "subagent prompt"]],
            ["type": "api-request-blob", "message": ["content": [["type": "text", "text": "not a step"]]]],
            ["type": "ai-title", "aiTitle": "Login bug"],
        ])
        let reader = TranscriptReader(path: path)
        reader.refresh()
        #expect(reader.steps.isEmpty)
        #expect(reader.title == "Login bug")
    }

    @Test func countsEachMessageOnceAndTracksContext() throws {
        let path = try tempFile([
            // One reply written as two lines with the same message id and the same usage.
            assistant(id: "m1", blocks: [["type": "text", "text": "a"]], input: 2, cacheRead: 1000, cacheWrite: 500, output: 100),
            assistant(id: "m1", blocks: [["type": "text", "text": "b"]], input: 2, cacheRead: 1000, cacheWrite: 500, output: 100),
            assistant(id: "m2", blocks: [["type": "text", "text": "c"]], input: 3, cacheRead: 2000, cacheWrite: 0, output: 40),
        ])
        let reader = TranscriptReader(path: path)
        reader.refresh()
        #expect(reader.usage.outputTokens == 140)
        #expect(reader.usage.contextTokens == 2003)
        #expect(reader.usage.model == "claude-opus-5-5")
    }

    @Test func readsOnlyNewLinesOnTheNextRefresh() throws {
        let path = try tempFile([["type": "user", "uuid": "u1", "message": ["content": "first"]]])
        let reader = TranscriptReader(path: path)
        reader.refresh()
        #expect(reader.refresh() == false)
        try append(path, ["type": "user", "uuid": "u2", "message": ["content": "second"]])
        #expect(reader.refresh())
        #expect(reader.steps.map(\.title) == ["first", "second"])
    }

    @Test func readsOnlyTheEndOfABigTranscript() throws {
        let lines: [[String: Any]] = (0..<200).map { ["type": "user", "uuid": "u\($0)", "message": ["content": "prompt number \($0)"]] }
        let path = try tempFile(lines)
        let reader = TranscriptReader(path: path)
        reader.maxInitialBytes = 1000
        reader.refresh()
        #expect(reader.steps.count < 200)
        #expect(reader.steps.last?.title == "prompt number 199")
        #expect(reader.steps.allSatisfy { $0.title.hasPrefix("prompt number ") })
    }

    @Test func missingFileIsNotAnError() {
        #expect(TranscriptReader(path: "/nonexistent/file.jsonl").refresh() == false)
    }
}

@Suite struct FormatTests {
    @Test func tokens() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(1234) == "1.2k")
        #expect(Format.tokens(84_300) == "84k")
        #expect(Format.tokens(1_300_000) == "1.3M")
    }

    @Test func resetText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Format.reset(now.addingTimeInterval(2 * 3600 + 14 * 60), now: now) == "resets in 2h 14m")
        #expect(Format.reset(now.addingTimeInterval(9 * 60), now: now) == "resets in 9m")
        #expect(Format.reset(now.addingTimeInterval(-5), now: now) == "reset due")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 1_800_000_000 is Friday 15 January 2027 08:00 UTC; three days later is Monday.
        #expect(Format.reset(now.addingTimeInterval(3 * 86_400), now: now, calendar: utc) == "resets Mon 08:00")
    }

    @Test func toolNames() {
        #expect(Format.toolName("Bash") == "Bash")
        #expect(Format.toolName("mcp__github__get_issue") == "github: get issue")
    }
}

@Suite struct LimitsTests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func parsesWindowsAndDropsExpiredOnes() {
        let limits = Limits.parse([
            "five_hour": ["used_percentage": 23.5, "resets_at": 2_000],
            "seven_day": ["used_percentage": 41.2, "resets_at": 500],
        ], now: now)
        #expect(limits.map(\.key) == ["five_hour"])
        #expect(limits[0].usedPercent == 23.5)
        #expect(limits[0].resetsAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test func missingLimitsGiveAnEmptyList() {
        #expect(Limits.parse(nil, now: now).isEmpty)
        #expect(Limits.parse(["five_hour": ["resets_at": 2_000]], now: now).isEmpty)
    }

    @Test func statusFileAndNewestLimits() {
        let old = StatusFiles.parse(["_updated_at": 100, "rate_limits": ["five_hour": ["used_percentage": 10, "resets_at": 2_000]]], now: now)!
        let new = StatusFiles.parse([
            "_updated_at": 900, "model": ["display_name": "Opus"],
            "context_window": ["used_percentage": 42, "context_window_size": 200_000],
            "cost": ["total_cost_usd": 1.5],
            "rate_limits": ["five_hour": ["used_percentage": 30, "resets_at": 2_000]],
        ], now: now)!
        let none = StatusFiles.parse(["_updated_at": 950], now: now)!
        #expect(new.model == "Opus")
        #expect(new.contextPercent == 42)
        #expect(new.contextSize == 200_000)
        #expect(new.costUSD == 1.5)
        #expect(StatusFiles.newestLimits([old, none, new])?.limits.first?.usedPercent == 30)
        #expect(StatusFiles.newestLimits([none]) == nil)
        #expect(StatusFiles.parse([:], now: now) == nil)
    }
}

@Suite struct SessionsTests {
    @Test func loadsLiveSessionsAndFindsTranscripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = HuddlePaths(claude: root)
        try FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true)
        let project = paths.projects.appendingPathComponent("-Users-me-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func write(_ name: String, _ json: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: json).write(to: paths.sessions.appendingPathComponent(name))
        }
        try write("11.json", ["pid": 11, "sessionId": "alive", "cwd": "/Users/me/app", "name": "App work",
                              "status": "busy", "startedAt": 2_000, "updatedAt": 3_000])
        try write("12.json", ["pid": 12, "sessionId": "dead", "cwd": "/x"])
        try write("11.abc.key", ["pid": 99, "sessionId": "not-a-session"])
        try Data().write(to: project.appendingPathComponent("alive.jsonl"))

        let sessions = Sessions.load(paths) { $0 == 11 }
        #expect(sessions.map(\.sessionId) == ["alive"])
        #expect(sessions[0].project == "app")
        #expect(sessions[0].rawStatus == "busy")
        #expect(sessions[0].startedAt == Date(timeIntervalSince1970: 2))
        let found = Sessions.transcriptPath(paths, sessionId: "alive").map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(found == project.appendingPathComponent("alive.jsonl").resolvingSymlinksInPath().path)
        #expect(Sessions.transcriptPath(paths, sessionId: "dead") == nil)
    }
}

@Suite struct DecisionsTests {
    let bash = PendingRequest(id: "1", sessionId: "s", toolName: "Bash", toolInput: ["command": "npm test"],
                              suggestions: [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                             "rules": [["toolName": "Bash", "ruleContent": "npm test"]]]])

    @Test func allowSendsNoInputForOrdinaryTools() {
        let payload = Decisions.allow(bash)
        #expect(payload["behavior"] as? String == "allow")
        #expect(payload["updatedInput"] == nil)
        #expect(payload["updatedPermissions"] == nil)
    }

    @Test func alwaysAllowPassesTheSuggestedRules() {
        let rules = Decisions.alwaysAllow(bash)["updatedPermissions"] as? [[String: Any]]
        #expect(rules?.count == 1)
        #expect(Decisions.describe(bash.suggestions) == "allow Bash(npm test)")
    }

    @Test func planApprovalEchoesThePlan() {
        let plan = PendingRequest(id: "2", sessionId: "s", toolName: "ExitPlanMode", toolInput: ["plan": "1. Do it"])
        #expect((Decisions.allow(plan)["updatedInput"] as? [String: Any])?["plan"] as? String == "1. Do it")
    }

    @Test func denyUsesTheNoteOrADefault() {
        #expect(Decisions.deny(note: "  use pnpm  ")["message"] as? String == "use pnpm")
        #expect(Decisions.deny(note: " ")["message"] as? String == "The user denied this in Agent Huddle.")
    }

    @Test func answersKeepQuestionsAndAddAnswers() {
        let request = PendingRequest(json: [
            "id": "3", "sessionId": "s", "toolName": "AskUserQuestion",
            "toolInput": ["questions": [["question": "Which framework?", "header": "Framework", "multiSelect": false,
                                         "options": [["label": "React", "description": "A"], ["label": "Vue", "description": "B"]]]]],
        ])!
        #expect(request.isQuestion)
        #expect(request.questions.first?.options.map(\.label) == ["React", "Vue"])
        let payload = Decisions.answer(request, answers: ["Which framework?": "React"])
        let input = payload["updatedInput"] as? [String: Any]
        #expect((input?["answers"] as? [String: String]) == ["Which framework?": "React"])
        #expect((input?["questions"] as? [[String: Any]])?.count == 1)
    }

    @Test func answerTextJoinsPicksInOptionOrder() {
        let options = [QuestionOption(label: "A", description: ""), QuestionOption(label: "B", description: "")]
        #expect(Decisions.answerText(picked: ["B", "A"], options: options, custom: "") == "A, B")
        #expect(Decisions.answerText(picked: [], options: options, custom: " my own ") == "my own")
        #expect(Decisions.answerText(picked: [], options: options, custom: "") == nil)
    }
}
