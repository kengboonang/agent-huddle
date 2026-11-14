import AppKit
import Darwin

/// Brings the app (and, for Terminal, the tab) that runs a session to the front.
enum Jumper {
    /// Editors built on VS Code. Opening a folder that is already open brings that window to the front.
    static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]

    static func activate(pid: Int32, cwd: String) {
        guard let app = hostApp(pid: pid) else { return }
        var isFolder: ObjCBool = false
        if let id = app.bundleIdentifier, editors.contains(id), let bundle = app.bundleURL,
           FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue {
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: bundle,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        app.activate(options: [.activateAllWindows])
        guard let tty = ttyName(pid), tty.range(of: "^/dev/[A-Za-z0-9]+$", options: .regularExpression) != nil else { return }
        switch app.bundleIdentifier {
        case "com.apple.Terminal": selectTerminalTab(tty: tty)
        case "com.googlecode.iterm2": selectITermSession(tty: tty)
        default: break
        }
    }

    private static func selectITermSession(tty: String) {
        run("""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """)
    }

    private static func run(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    static func hostAppName(pid: Int32) -> String {
        hostApp(pid: pid)?.localizedName ?? "session"
    }

    /// Walks up the process tree until it reaches a regular app.
    static func hostApp(pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<25 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let info = processInfo(current) else { return nil }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 || parent == current { return nil }
            current = parent
        }
        return nil
    }

    private static func processInfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func ttyName(_ pid: Int32) -> String? {
        guard let info = processInfo(pid) else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func selectTerminalTab(tty: String) {
        run("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                    end if
                end repeat
            end repeat
        end tell
        """)
    }
}
