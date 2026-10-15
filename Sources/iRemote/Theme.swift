import AppKit
import SwiftUI

enum Theme {
    static let panelSize = CGSize(width: 320, height: 520)
    static let surface = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x22 / 255)
    static let label = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let secondary = Color(red: 0x98 / 255, green: 0x98 / 255, blue: 0x9D / 255)
    static let tertiary = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)
    static let fill = Color.white.opacity(0.08)
    static let fillPressed = Color.white.opacity(0.16)
    static let fill2 = Color.white.opacity(0.05)
    static let separator = Color.white.opacity(0.08)
    static let accent = Color(red: 1, green: 0x5A / 255, blue: 0x1F / 255)
    static let connected = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let mono = Font.system(size: 12, design: .monospaced)
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PressFill: ButtonStyle {
    var shape: AnyShape = AnyShape(Circle())
    var fill = Theme.fill
    var pressed = Theme.fillPressed

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(shape.fill(configuration.isPressed ? pressed : fill))
            .contentShape(shape)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}

struct CircleIconButton: View {
    let symbol: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 13
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Theme.label)
                .frame(width: size, height: size)
        }
        .buttonStyle(PressFill())
        .help(help)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
    }
}
