import AppKit
import Combine
import HuddleCore
import SwiftUI

/// A floating panel that can take typing without pulling its app to the front.
final class HuddlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store: HuddleStore
    private var panel: HuddlePanel!
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var resizing = false
    private let cornerKey = "panelTopRight"

    override init() {
        let env = ProcessInfo.processInfo.environment
        store = HuddleStore(demo: env["HUDDLE_DEMO"] ?? (env["HUDDLE_RECORD"] == nil ? nil : "pill"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["HUDDLE_RECORD"] {
            Recorder.record(to: path)
            NSApp.terminate(nil)
            return
        }
        if let path = env["HUDDLE_SNAPSHOT"] {
            snapshot(to: path)
            NSApp.terminate(nil)
            return
        }

        panel = HuddlePanel(contentRect: NSRect(origin: .zero, size: Layout.pill),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RootView(store: store))
        panel.delegate = self
        fit(expanded: store.expanded)
        panel.orderFrontRegardless()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: "Agent Huddle")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show or hide widget", action: #selector(toggleVisible), keyEquivalent: "")
        menu.addItem(withTitle: "Move widget back to the top-right corner", action: #selector(resetCorner), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Agent Huddle", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item

        store.$expanded.removeDuplicates().sink { [weak self] expanded in
            DispatchQueue.main.async { self?.fit(expanded: expanded) }
        }.store(in: &cancellables)
        store.$panelHeight.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { if let self { self.fit(expanded: self.store.expanded) } }
        }.store(in: &cancellables)
        store.onClose = { [weak self] in self?.panel.orderOut(nil) }
        store.$pending.map(\.count).removeDuplicates().sink { [weak self] count in
            self?.statusItem?.button?.title = count > 0 ? " \(count)" : ""
        }.store(in: &cancellables)
        store.onAttention = { [weak self] in self?.panel.orderFrontRegardless() }
        store.start()
    }

    // MARK: Position

    /// The top-right corner stays where it is while the panel grows and shrinks.
    private func corner() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: cornerKey) {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) { return point }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return NSPoint(x: 400, y: 100) }
        return NSPoint(x: screen.visibleFrame.maxX - 16, y: screen.visibleFrame.maxY - 16)
    }

    private func fit(expanded: Bool) {
        let size = expanded ? CGSize(width: Layout.panelWidth, height: store.panelHeight) : Layout.pill
        let anchor = corner()
        var frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor) }) {
            let visible = screen.visibleFrame
            frame.origin.y = max(frame.origin.y, visible.minY)
            frame.origin.x = max(frame.origin.x, visible.minX)
        }
        resizing = true
        panel.setFrame(frame, display: true)
        resizing = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !resizing else { return }
        let frame = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.maxX, y: frame.maxY)), forKey: cornerKey)
    }

    // MARK: Menu

    @objc private func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func resetCorner() {
        UserDefaults.standard.removeObject(forKey: cornerKey)
        fit(expanded: store.expanded)
        panel.orderFrontRegardless()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Without the heartbeat, hooks stop waiting and Claude Code asks in the session again.
        // Only the real widget removes it; a snapshot or demo run leaves it alone.
        store.stop()
    }

    // MARK: Snapshot

    /// Draws the widget into a PNG file, so the layout can be checked without screen recording.
    private func snapshot(to path: String) {
        if ProcessInfo.processInfo.environment["HUDDLE_DEMO"] == nil {
            // Real data: read the live sessions for a moment before drawing.
            store.start(heartbeat: false)
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            store.expanded = true
            if let select = ProcessInfo.processInfo.environment["HUDDLE_SELECT"] { store.selected = select }
        }
        let host = NSHostingView(rootView: RootView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.maxPanelHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // The panel sizes itself to its content, so let it settle before measuring.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let size = store.expanded ? CGSize(width: Layout.panelWidth, height: store.panelHeight) : Layout.pill
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

let env = ProcessInfo.processInfo.environment
if env["HUDDLE_SNAPSHOT"] == nil, env["HUDDLE_DEMO"] == nil, env["HUDDLE_RECORD"] == nil,
   let bundle = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundle).count > 1 {
    // Already running.
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
