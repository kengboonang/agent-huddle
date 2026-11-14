import Foundation
import HuddleCore

/// Sample data, used to check the layout without touching real sessions.
/// Run with `HUDDLE_DEMO=list|needs|detail|permission|question|pill`.
enum Demo {
    static func fill(_ store: HuddleStore, mode: String) {
        let now = Date()
        func info(_ pid: Int32, _ id: String, _ name: String, _ cwd: String, _ status: String) -> SessionInfo {
            SessionInfo(pid: pid, sessionId: id, cwd: cwd, name: name, rawStatus: status, entrypoint: "cli",
                        startedAt: now.addingTimeInterval(-3600), updatedAt: now)
        }
        var first = AgentSession(info: info(1, "a", "Checkout page redesign", "/Users/me/shop-web", "busy"))
        first.steps = [
            Step(id: "1", kind: .prompt, state: .info, title: "Redesign the checkout page so the total is always visible", time: now.addingTimeInterval(-600)),
            Step(id: "2", kind: .tool, state: .done, title: "Read", detail: "Checkout.tsx", time: now.addingTimeInterval(-590)),
            Step(id: "3", kind: .text, state: .info, title: "The total sits inside the scrolling list. I'll move it to a fixed footer.", time: now.addingTimeInterval(-560)),
            Step(id: "4", kind: .tool, state: .done, title: "Edit", detail: "Checkout.tsx", time: now.addingTimeInterval(-500)),
            Step(id: "5", kind: .tool, state: .failed, title: "Bash", detail: "Run the checkout tests", time: now.addingTimeInterval(-420)),
            Step(id: "6", kind: .tool, state: .running, title: "Bash", detail: "Install the missing test package", time: now.addingTimeInterval(-20)),
        ]
        first.usage.contextTokens = 84_300
        first.usage.outputTokens = 12_400
        first.usage.model = "claude-opus-5-5"
        first.status = SessionStatus(updatedAt: now, model: "Opus", contextPercent: 42, contextSize: 200_000, costUSD: 1.84)

        var second = AgentSession(info: info(2, "b", "Fix flaky login test", "/Users/me/api-server", "idle"))
        second.steps = [Step(id: "1", kind: .text, state: .info, title: "The test passes 50 times in a row now. The cause was a shared port.", time: now.addingTimeInterval(-900))]
        second.usage.contextTokens = 31_000
        second.usage.outputTokens = 4_100
        second.status = SessionStatus(updatedAt: now, model: "Sonnet", contextPercent: 16, contextSize: 200_000, costUSD: 0.32)

        var third = AgentSession(info: info(3, "c", "Write release notes", "/Users/me/docs", "busy"))
        third.steps = [Step(id: "1", kind: .tool, state: .running, title: "Grep", detail: "BREAKING", time: now.addingTimeInterval(-5))]
        third.usage.contextTokens = 156_000
        third.usage.outputTokens = 22_900
        third.status = SessionStatus(updatedAt: now, model: "Opus", contextPercent: 78, contextSize: 200_000, costUSD: 3.10)

        store.sessions = [first, second, third]
        store.limits = [
            LimitWindow(key: "five_hour", label: "5-hour limit", usedPercent: 63, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
            LimitWindow(key: "seven_day", label: "Weekly limit", usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ]
        store.limitsUpdatedAt = now
        store.expanded = mode != "pill"

        switch mode {
        case "detail":
            store.selected = "a"
        case "permission", "needs":
            store.selected = mode == "needs" ? nil : "a"
            store.pending = [PendingRequest(
                id: "p1", sessionId: "a", toolName: "Bash",
                toolInput: ["command": "npm install --save-dev @testing-library/user-event", "description": "Install the missing test package"],
                suggestions: [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                               "rules": [["toolName": "Bash", "ruleContent": "npm install:*"]]]])]
        case "question":
            store.selected = "a"
            store.pending = [PendingRequest(
                id: "q1", sessionId: "a", toolName: "AskUserQuestion",
                toolInput: ["questions": [[
                    "question": "Where should the order total sit on small screens?", "header": "Total",
                    "multiSelect": false,
                    "options": [["label": "Fixed footer", "description": "Always visible at the bottom of the screen"],
                                ["label": "Below the list", "description": "Visible after scrolling past the items"]],
                ]]])]
            store.picks["q1|Where should the order total sit on small screens?"] = ["Fixed footer"]
        default:
            break
        }
    }
}
