import AppKit
import RemoteCore
import SwiftUI

struct RemoteTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let live = model.link == .connected
        VStack(spacing: 20) {
            ClickPad { model.press($0) }
            HStack {
                RoundKey(symbol: "chevron.left", help: "Back  (esc)") { model.press(.back) }
                Spacer()
                RoundKey(symbol: "house", help: "Home  (H)") { model.press(.home) }
                Spacer()
                RoundKey(symbol: "playpause.fill", help: "Play / Pause  (space)") { model.press(.playPause) }
                Spacer()
                RoundKey(symbol: "speaker.slash.fill", help: "Mute  (M)") { model.press(.volumeMute) }
            }
            VolumeBar(volume: model.volume, setFraction: model.setVolume(fraction:), step: model.stepVolume)
        }
        .opacity(live ? 1 : 0.45)
        .allowsHitTesting(live)
        .animation(.easeOut(duration: 0.2), value: live)
    }
}

struct RoundKey: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.label)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(PressFill())
        .help(help)
    }
}

struct ClickPad: View {
    enum Zone: Equatable { case center, up, down, left, right }
    let press: (KeyCode) -> Void
    @State private var pressed: Zone?
    private let size: CGFloat = 216
    private let center: CGFloat = 88

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 6)
            if let pressed, pressed != .center {
                Wedge(zone: pressed)
                    .fill(Color.white.opacity(0.09))
                    .transition(.opacity)
            }
            ForEach([Zone.up, .down, .left, .right], id: \.self) { zone in
                Circle()
                    .fill(Color(white: pressed == zone ? 0.9 : 0.56))
                    .frame(width: 5, height: 5)
                    .offset(offset(zone, distance: size / 2 - 12))
            }
            Circle()
                .fill(LinearGradient(colors: [Color(white: pressed == .center ? 0.34 : 0.29), Color(white: pressed == .center ? 0.28 : 0.23)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                .frame(width: center, height: center)
                .scaleEffect(pressed == .center ? 0.97 : 1)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pressed == nil { withAnimation(.easeOut(duration: 0.08)) { pressed = zone(at: value.startLocation) } }
                }
                .onEnded { _ in
                    if let zone = pressed { press(key(zone)) }
                    withAnimation(.easeOut(duration: 0.18)) { pressed = nil }
                }
        )
        .help("Click an edge to move, the centre to select. Arrow keys and return work too.")
    }

    private func zone(at p: CGPoint) -> Zone? {
        let dx = p.x - size / 2, dy = p.y - size / 2
        let r = (dx * dx + dy * dy).squareRoot()
        if r <= center / 2 { return .center }
        if r > size / 2 { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
    }

    private func key(_ zone: Zone) -> KeyCode {
        switch zone {
        case .center: .dpadCenter
        case .up: .dpadUp
        case .down: .dpadDown
        case .left: .dpadLeft
        case .right: .dpadRight
        }
    }

    private func offset(_ zone: Zone, distance d: CGFloat) -> CGSize {
        switch zone {
        case .up: CGSize(width: 0, height: -d)
        case .down: CGSize(width: 0, height: d)
        case .left: CGSize(width: -d, height: 0)
        case .right: CGSize(width: d, height: 0)
        case .center: .zero
        }
    }
}

struct Wedge: Shape {
    let zone: ClickPad.Zone

    func path(in rect: CGRect) -> Path {
        let mid: Double = switch zone {
        case .right: 0
        case .down: 90
        case .left: 180
        default: 270
        }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(mid - 45), endAngle: .degrees(mid + 45), clockwise: false)
        p.addArc(center: c, radius: 44, startAngle: .degrees(mid + 45), endAngle: .degrees(mid - 45), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct VolumeBar: View {
    let volume: VolumeInfo?
    let setFraction: (Double) -> Void
    let step: (Bool) -> Void
    private let segments = 16

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: volume?.muted == true ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i < lit ? Theme.label.opacity(volume?.muted == true ? 0.35 : 1) : Color.white.opacity(0.12))
                        .frame(height: 14)
                }
            }
            .overlay(VolumeTracker(setFraction: setFraction, step: step))
            Text(volume.map { "\($0.level)" } ?? "–")
                .font(Theme.mono)
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(Theme.fill))
        .help("Click or drag to set the volume, scroll to nudge it")
    }

    private var lit: Int {
        guard let v = volume, v.max > 0 else { return 0 }
        let fraction = min(1, max(0, Double(v.level) / Double(v.max)))
        return Int((fraction * Double(segments)).rounded(.up))
    }
}

/// Mouse and scroll-wheel input for the volume segments, which SwiftUI gestures can't do alone.
struct VolumeTracker: NSViewRepresentable {
    let setFraction: (Double) -> Void
    let step: (Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.setFraction = setFraction
        v.step = step
        return v
    }

    func updateNSView(_ v: TrackerView, context: Context) {
        v.setFraction = setFraction
        v.step = step
    }

    final class TrackerView: NSView {
        var setFraction: ((Double) -> Void)?
        var step: ((Bool) -> Void)?
        private var scrollAccumulator: CGFloat = 0
        private var lastSent = Date.distantPast

        override func mouseDown(with event: NSEvent) { track(event, force: true) }
        override func mouseDragged(with event: NSEvent) { track(event, force: false) }

        private func track(_ event: NSEvent, force: Bool) {
            // Each step is a key press on the TV, so drags are throttled.
            guard force || Date().timeIntervalSince(lastSent) > 0.12 else { return }
            lastSent = Date()
            let x = convert(event.locationInWindow, from: nil).x
            setFraction?(max(0, min(1, Double(x / bounds.width))))
        }

        override func mouseUp(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            setFraction?(max(0, min(1, Double(x / bounds.width))))
        }

        override func scrollWheel(with event: NSEvent) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            scrollAccumulator += delta
            while abs(scrollAccumulator) >= 12 {
                step?(scrollAccumulator > 0)
                scrollAccumulator -= scrollAccumulator > 0 ? 12 : -12
            }
        }
    }
}
