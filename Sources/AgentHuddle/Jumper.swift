import AppKit
import Darwin

/// Brings the app (and, for Terminal, the tab) that runs a session to the front.
enum Jumper {
    static func activate(pid: Int32) {
        guard let app = hostApp(pid: pid) else { return }
        app.activate(options: [.activateAllWindows])
        if app.bundleIdentifier == "com.apple.Terminal", let tty = ttyName(pid) {
            selectTerminalTab(tty: tty)
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
        // The tty comes from the system and only ever looks like /dev/ttys003.
        guard tty.range(of: "^/dev/[A-Za-z0-9]+$", options: .regularExpression) != nil else { return }
        let script = """
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
        """
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}
