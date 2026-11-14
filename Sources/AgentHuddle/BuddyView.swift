import HuddleCore
import SwiftUI

/// A small animated character that stands for one session.
/// It bobs while the session works, hops with a "!" when the session needs you, and sleeps when it is idle.
struct BuddyView: View {
    var traits: BuddyTraits
    var activity: Activity
    var size: CGFloat = 36

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.buddyClock) private var fixedClock

    static let palette: [Color] = [
        Color(red: 0.98, green: 0.47, blue: 0.42), Color(red: 0.98, green: 0.70, blue: 0.26),
        Color(red: 0.40, green: 0.80, blue: 0.56), Color(red: 0.36, green: 0.68, blue: 0.98),
        Color(red: 0.65, green: 0.53, blue: 0.98), Color(red: 0.97, green: 0.52, blue: 0.76),
        Color(red: 0.28, green: 0.78, blue: 0.78), Color(red: 0.69, green: 0.82, blue: 0.33),
    ]

    var body: some View {
        Group {
            if let fixedClock {
                Canvas { context, canvas in
                    draw(&context, canvas.width, fixedClock + traits.phase)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
                    let time = reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate + traits.phase
                    Canvas { context, canvas in
                        draw(&context, canvas.width, time)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(traits.name), \(activity.label)")
    }

    private func draw(_ context: inout GraphicsContext, _ s: CGFloat, _ time: Double) {
        let color = Self.palette[traits.color % Self.palette.count]
        let ink = Color(red: 0.13, green: 0.13, blue: 0.18)

        // Movement.
        var lift: CGFloat = 0
        var squash: CGFloat = 1
        switch activity {
        case .working: lift = abs(sin(time * 4.2)) * 0.07 * s
        case .needsYou: lift = abs(sin(time * 7)) * 0.13 * s
        case .idle: squash = 1 + sin(time * 1.4) * 0.025
        }

        // Shadow on the ground, smaller while the buddy is in the air.
        let shadowWidth = s * (0.5 - lift / s)
        context.fill(Path(ellipseIn: CGRect(x: (s - shadowWidth) / 2, y: s * 0.9, width: shadowWidth, height: s * 0.07)),
                     with: .color(.black.opacity(0.22)))

        var body = context
        body.translateBy(x: s / 2, y: s * 0.9 - lift)
        body.scaleBy(x: 2 - squash, y: squash)
        body.translateBy(x: -s / 2, y: -s * 0.9)

        // Feet.
        for x in [0.33, 0.57] {
            body.fill(Path(ellipseIn: CGRect(x: s * x, y: s * 0.84, width: s * 0.13, height: s * 0.08)), with: .color(ink.opacity(0.75)))
        }

        // Body.
        let shade = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [color, color.opacity(0.78)]), startPoint: CGPoint(x: 0, y: s * 0.2), endPoint: CGPoint(x: 0, y: s * 0.9))
        body.fill(bodyPath(s), with: shade)
        if traits.shape == .bot {
            var antenna = Path()
            antenna.move(to: CGPoint(x: s * 0.5, y: s * 0.26))
            antenna.addLine(to: CGPoint(x: s * 0.5, y: s * 0.13))
            body.stroke(antenna, with: .color(ink.opacity(0.75)), lineWidth: max(1, s * 0.04))
            let glow: Color = activity == .needsYou ? .orange : (activity == .working ? .green : color)
            body.fill(Path(ellipseIn: CGRect(x: s * 0.44, y: s * 0.05, width: s * 0.12, height: s * 0.12)), with: .color(glow))
        }

        // Cheeks.
        for x in [0.24, 0.66] {
            body.fill(Path(ellipseIn: CGRect(x: s * x, y: s * 0.6, width: s * 0.1, height: s * 0.06)), with: .color(.white.opacity(0.28)))
        }

        // Eyes.
        let eyeY = s * 0.5
        let blink = activity != .idle && (time.truncatingRemainder(dividingBy: 3.7) < 0.14)
        for x in [0.37, 0.63] {
            let centre = CGPoint(x: s * x, y: eyeY)
            if activity == .idle || blink {
                var lid = Path()
                lid.move(to: CGPoint(x: centre.x - s * 0.06, y: centre.y))
                lid.addQuadCurve(to: CGPoint(x: centre.x + s * 0.06, y: centre.y),
                                 control: CGPoint(x: centre.x, y: centre.y + (activity == .idle ? s * 0.06 : 0)))
                body.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: max(1, s * 0.045), lineCap: .round))
            } else {
                let radius = s * (activity == .needsYou ? 0.085 : 0.07)
                body.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                          with: .color(.white))
                let look = activity == .working ? sin(time * 2.1) * s * 0.025 : 0
                let pupil = radius * 0.55
                body.fill(Path(ellipseIn: CGRect(x: centre.x - pupil + look, y: centre.y - pupil + s * 0.008, width: pupil * 2, height: pupil * 2)),
                          with: .color(ink))
            }
        }

        // Mouth.
        let mouthY = s * 0.65
        switch activity {
        case .needsYou:
            body.fill(Path(ellipseIn: CGRect(x: s * 0.46, y: mouthY - s * 0.02, width: s * 0.08, height: s * 0.09)), with: .color(ink))
        case .working:
            var smile = Path()
            smile.move(to: CGPoint(x: s * 0.44, y: mouthY))
            smile.addQuadCurve(to: CGPoint(x: s * 0.56, y: mouthY), control: CGPoint(x: s * 0.5, y: mouthY + s * 0.07))
            body.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: max(1, s * 0.04), lineCap: .round))
        case .idle:
            var line = Path()
            line.move(to: CGPoint(x: s * 0.46, y: mouthY + s * 0.02))
            line.addLine(to: CGPoint(x: s * 0.54, y: mouthY + s * 0.02))
            body.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: max(1, s * 0.04), lineCap: .round))
        }

        // Extras that do not move with the body.
        switch activity {
        case .needsYou:
            let bubble = CGRect(x: s * 0.7, y: s * 0.02, width: s * 0.28, height: s * 0.28)
            context.fill(Path(ellipseIn: bubble), with: .color(.orange))
            context.draw(Text("!").font(.system(size: s * 0.22, weight: .heavy, design: .rounded)).foregroundColor(.white),
                         at: CGPoint(x: bubble.midX, y: bubble.midY))
        case .idle:
            let drift = time.truncatingRemainder(dividingBy: 2.4) / 2.4
            for (index, scale) in [0.18, 0.13].enumerated() {
                let progress = (drift + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                context.opacity = 1 - progress
                context.draw(Text("z").font(.system(size: s * scale, weight: .bold, design: .rounded)).foregroundColor(.secondary),
                             at: CGPoint(x: s * (0.78 + 0.1 * progress), y: s * (0.3 - 0.24 * progress)))
            }
            context.opacity = 1
        case .working:
            break
        }
    }

    private func bodyPath(_ s: CGFloat) -> Path {
        switch traits.shape {
        case .blob:
            return Path(ellipseIn: CGRect(x: s * 0.14, y: s * 0.24, width: s * 0.72, height: s * 0.64))
        case .bot:
            return Path(roundedRect: CGRect(x: s * 0.17, y: s * 0.26, width: s * 0.66, height: s * 0.6), cornerRadius: s * 0.17)
        case .ghost:
            var path = Path()
            let left = s * 0.17, right = s * 0.83, bottom = s * 0.88
            path.move(to: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: left, y: s * 0.52))
            path.addArc(center: CGPoint(x: s * 0.5, y: s * 0.52), radius: s * 0.33, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: right, y: bottom))
            let step = (right - left) / 4
            for index in 0..<4 {
                let x = right - step * CGFloat(index + 1)
                path.addQuadCurve(to: CGPoint(x: x, y: bottom), control: CGPoint(x: x + step / 2, y: bottom - s * 0.1))
            }
            path.closeSubpath()
            return path
        case .cat:
            var path = Path(roundedRect: CGRect(x: s * 0.16, y: s * 0.3, width: s * 0.68, height: s * 0.57), cornerRadius: s * 0.22)
            for (base, tip) in [(0.2, 0.2), (0.8, 0.8)] {
                let inner = base < 0.5 ? base + 0.22 : base - 0.22
                path.move(to: CGPoint(x: s * base, y: s * 0.44))
                path.addLine(to: CGPoint(x: s * tip, y: s * 0.14))
                path.addLine(to: CGPoint(x: s * inner, y: s * 0.32))
                path.closeSubpath()
            }
            return path
        }
    }
}
