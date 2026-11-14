import Foundation

public enum Format {
    /// 950 → "950", 1234 → "1.2k", 84_300 → "84k", 1_300_000 → "1.3M".
    public static func tokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "resets in 2h 14m", "resets in 9m", "resets Tue 09:00" (more than a day away), "reset due".
    public static func reset(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "reset due" }
        if seconds < 3600 { return "resets in \(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "resets in \(seconds / 3600)h \((seconds % 3600) / 60)m" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE HH:mm"
        return "resets \(formatter.string(from: date))"
    }

    /// "now", "5m", "2h", "3d".
    public static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    public static func cost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// `mcp__github__get_issue` → "github: get issue"; other names are returned as they are.
    public static func toolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        return "\(parts[0]): \(parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " "))"
    }

    public static func oneLine(_ text: String, limit: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

public enum Limits {
    static let labels: [(key: String, label: String)] = [
        ("five_hour", "5-hour limit"), ("seven_day", "Weekly limit"), ("spend_limit", "Spend limit"),
    ]

    /// Reads the `rate_limits` object the status line receives. Windows that already reset are dropped.
    public static func parse(_ rateLimits: [String: Any]?, now: Date) -> [LimitWindow] {
        guard let rateLimits else { return [] }
        return labels.compactMap { key, label in
            guard let window = rateLimits[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let resets, resets <= now { return nil }
            return LimitWindow(key: key, label: label, usedPercent: used, resetsAt: resets)
        }
    }
}

public enum StatusFiles {
    /// Reads one file written by the status line script.
    public static func parse(_ json: [String: Any], now: Date) -> SessionStatus? {
        guard let updated = (json["_updated_at"] as? NSNumber)?.doubleValue else { return nil }
        let context = json["context_window"] as? [String: Any]
        return SessionStatus(
            updatedAt: Date(timeIntervalSince1970: updated),
            model: (json["model"] as? [String: Any])?["display_name"] as? String,
            contextPercent: (context?["used_percentage"] as? NSNumber)?.doubleValue,
            contextSize: (context?["context_window_size"] as? NSNumber)?.intValue,
            costUSD: ((json["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue,
            limits: Limits.parse(json["rate_limits"] as? [String: Any], now: now))
    }

    /// Rate limits belong to the account, so the newest report from any session is the one to show.
    public static func newestLimits(_ statuses: [SessionStatus]) -> (limits: [LimitWindow], updatedAt: Date)? {
        statuses.filter { !$0.limits.isEmpty }.max { $0.updatedAt < $1.updatedAt }.map { ($0.limits, $0.updatedAt) }
    }
}

public enum Sessions {
    /// Reads every session file and keeps the ones whose process is still running.
    public static func load(_ paths: HuddlePaths, isAlive: (Int32) -> Bool) -> [SessionInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> SessionInfo? in
            guard let json = readJSON(url), let info = parse(json), isAlive(info.pid) else { return nil }
            return info
        }.sorted { $0.startedAt < $1.startedAt }
    }

    public static func parse(_ json: [String: Any]) -> SessionInfo? {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value, let sessionId = json["sessionId"] as? String else { return nil }
        func date(_ key: String) -> Date {
            Date(timeIntervalSince1970: ((json[key] as? NSNumber)?.doubleValue ?? 0) / 1000)
        }
        return SessionInfo(pid: pid, sessionId: sessionId, cwd: json["cwd"] as? String ?? "",
                           name: json["name"] as? String ?? "", rawStatus: json["status"] as? String ?? "",
                           entrypoint: json["entrypoint"] as? String ?? "",
                           startedAt: date("startedAt"), updatedAt: date("updatedAt"))
    }

    /// Finds `<projects>/<any folder>/<sessionId>.jsonl`.
    public static func transcriptPath(_ paths: HuddlePaths, sessionId: String) -> String? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: paths.projects, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let file = folder.appendingPathComponent(sessionId + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file.path }
        }
        return nil
    }
}

/// Builds the answer files that the permission hook turns into a decision for Claude Code.
public enum Decisions {
    public static func allow(_ request: PendingRequest) -> [String: Any] {
        var payload: [String: Any] = ["behavior": "allow"]
        // ExitPlanMode only runs when the hook sends its input back.
        if request.isPlan { payload["updatedInput"] = request.toolInput }
        return payload
    }

    public static func alwaysAllow(_ request: PendingRequest) -> [String: Any] {
        var payload = allow(request)
        if !request.suggestions.isEmpty { payload["updatedPermissions"] = request.suggestions }
        return payload
    }

    public static func deny(note: String) -> [String: Any] {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["behavior": "deny", "message": trimmed.isEmpty ? "The user denied this in Agent Huddle." : trimmed]
    }

    /// AskUserQuestion is answered by sending the questions back with an `answers` map.
    public static func answer(_ request: PendingRequest, answers: [String: String]) -> [String: Any] {
        var input = request.toolInput
        input["answers"] = answers
        return ["behavior": "allow", "updatedInput": input]
    }

    /// One answer string: picked labels joined with commas, plus any text the person typed.
    public static func answerText(picked: [String], options: [QuestionOption], custom: String) -> String? {
        var parts = options.map(\.label).filter { picked.contains($0) }
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A short description of what "Always allow" will change, for the button's help text.
    public static func describe(_ suggestions: [[String: Any]]) -> String {
        suggestions.compactMap { s -> String? in
            switch s["type"] as? String {
            case "addRules", "replaceRules":
                let rules = (s["rules"] as? [[String: Any]] ?? []).map { rule -> String in
                    let tool = rule["toolName"] as? String ?? "?"
                    if let content = rule["ruleContent"] as? String { return "\(tool)(\(content))" }
                    return tool
                }
                return rules.isEmpty ? nil : "\(s["behavior"] as? String ?? "allow") " + rules.joined(separator: ", ")
            case "setMode":
                return "switch to \(s["mode"] as? String ?? "?") mode"
            case "addDirectories":
                return "add folders " + (s["directories"] as? [String] ?? []).joined(separator: ", ")
            default:
                return nil
            }
        }.joined(separator: "; ")
    }
}
