import AppKit
import HuddleCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Draws the demo animation for the README: a scripted run over sample data, saved as a GIF.
/// Run with `HUDDLE_RECORD=docs/demo.gif .build/debug/AgentHuddle`. No real session is read.

private struct BuddyClockKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// When set, buddies draw this moment of their animation and do not follow the real clock.
    var buddyClock: Double? {
        get { self[BuddyClockKey.self] }
        set { self[BuddyClockKey.self] = newValue }
    }
}

final class DemoDirector: ObservableObject {
    @Published var clock: Double = 0
    @Published var caption = ""
    @Published var cursor = CGPoint(x: 330, y: 560)
    @Published var ripple: Double? = nil
}

/// The widget in the corner of a plain backdrop, with a caption and a pointer.
struct DemoStage: View {
    static let size = CGSize(width: 450, height: 700)
    static let margin: CGFloat = 24

    @ObservedObject var store: HuddleStore
    @ObservedObject var director: DemoDirector

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.17), Color(red: 0.19, green: 0.16, blue: 0.26)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(director.caption)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(width: Self.size.width - 48, alignment: .leading)
                .padding(.leading, 24)
                .padding(.top, 26)
            RootView(store: store)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                .padding(Self.margin)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .bottomTrailing)
            if let ripple = director.ripple {
                Circle()
                    .strokeBorder(Color.white.opacity(1 - ripple), lineWidth: 2)
                    .frame(width: 14 + 30 * ripple, height: 14 + 30 * ripple)
                    .position(director.cursor)
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1.5)
                .position(x: director.cursor.x + 6, y: director.cursor.y + 9)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.buddyClock, director.clock)
        .environment(\.colorScheme, .dark)
    }
}

enum Recorder {
    static let fps = 10.0
    /// Top-left corner of the open panel and of the pill, in stage points.
    static let panel = CGPoint(x: DemoStage.size.width - DemoStage.margin - Layout.panel.width,
                               y: DemoStage.size.height - DemoStage.margin - Layout.panel.height)
    static let pill = CGPoint(x: DemoStage.size.width - DemoStage.margin - Layout.pill.width / 2,
                              y: DemoStage.size.height - DemoStage.margin - Layout.pill.height / 2)

    static func inPanel(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: panel.x + x, y: panel.y + y)
    }

    /// One step of the script: where the pointer ends up, what happens when it gets there, and how long to stay.
    struct Beat {
        var caption: String?
        var moveTo: CGPoint?
        var travel: Double = 0.7
        var click = false
        var action: ((HuddleStore) -> Void)?
        var hold: Double
    }

    static func script() -> [Beat] {
        let question = "Where should the order total sit on small screens?"
        return [
            Beat(caption: "Every Claude Code session, in one corner", hold: 1.8),
            Beat(moveTo: pill, click: true, action: { $0.expanded = true }, hold: 0.3),
            Beat(caption: "What each agent is doing, and how much of your limits is left", hold: 2.6),
            Beat(caption: "An agent needs you: it jumps to the top", action: { store in
                store.pending = [Demo.permissionRequest()]
            }, hold: 2.0),
            Beat(caption: "Read the exact command, then allow it from here",
                 moveTo: inPanel(345, 241), travel: 0.9, click: true, action: { store in
                     if let request = store.pending.first { store.allow(request) }
                 }, hold: 1.6),
            Beat(caption: "Open a session to follow every step", moveTo: inPanel(215, 150), click: true,
                 action: { $0.selected = "a" }, hold: 2.4),
            Beat(caption: "Claude has a question: answer it without switching windows", action: { store in
                store.pending = [Demo.questionRequest()]
            }, hold: 1.8),
            Beat(moveTo: inPanel(150, 273), click: true, action: { store in
                store.picks["q1|\(question)"] = ["Fixed footer"]
            }, hold: 0.7),
            Beat(moveTo: inPanel(332, 384), click: true, action: { store in
                if let request = store.pending.first { store.sendAnswers(request) }
            }, hold: 1.8),
            Beat(caption: "Then get back to work", moveTo: inPanel(364, 23), click: true, action: { store in
                store.selected = nil
                store.expanded = false
            }, hold: 2.2),
        ]
    }

    static func record(to path: String) {
        let store = HuddleStore(demo: "pill")
        let director = DemoDirector()
        let host = NSHostingView(rootView: DemoStage(store: store, director: director))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: DemoStage.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host

        var frames: [CGImage] = []
        func capture() {
            director.clock += 1 / fps
            store.now = Date()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let image = bitmap.cgImage, let small = scaled(image, toWidth: 675) { frames.append(small) }
        }
        func run(_ seconds: Double, each: ((Double) -> Void)? = nil) {
            let count = max(1, Int((seconds * fps).rounded()))
            for index in 1...count {
                each?(Double(index) / Double(count))
                capture()
            }
        }

        for beat in script() {
            if let caption = beat.caption { director.caption = caption }
            if let target = beat.moveTo {
                let start = director.cursor
                run(beat.travel) { progress in
                    let eased = progress * progress * (3 - 2 * progress)
                    director.cursor = CGPoint(x: start.x + (target.x - start.x) * eased,
                                              y: start.y + (target.y - start.y) * eased)
                }
            }
            if beat.click {
                run(0.3) { director.ripple = $0 }
                director.ripple = nil
            }
            if let action = beat.action {
                // Let the answer buttons finish their short pause before the script presses one.
                RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                action(store)
            }
            run(beat.hold)
        }
        write(frames, to: path)
        // HUDDLE_RECORD_FRAMES=<folder> also saves every 12th frame as a PNG, for checking the result.
        if let folder = ProcessInfo.processInfo.environment["HUDDLE_RECORD_FRAMES"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for (index, image) in frames.enumerated() where index % 12 == 6 {
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try? png?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "frame-%03d.png", index)))
            }
        }
    }

    private static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = image.height * width / image.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func write(_ frames: [CGImage], to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { return }
        let file = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, file as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]]
        for image in frames { CGImageDestinationAddImage(destination, image, frame as CFDictionary) }
        CGImageDestinationFinalize(destination)
        print("Wrote \(frames.count) frames to \(path)")
    }
}
