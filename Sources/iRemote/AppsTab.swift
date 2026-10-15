import RemoteCore
import SwiftUI

struct AppTileStyle {
    let background: Color
    let mark: String
    var markColor: Color = .white
    var markSize: CGFloat = 20

    static func of(_ app: KnownApp) -> AppTileStyle {
        switch app.name {
        case "YouTube": AppTileStyle(background: Color(hex: 0xFF0033), mark: "▶︎", markSize: 18)
        case "Netflix": AppTileStyle(background: .black, mark: "N", markColor: Color(hex: 0xE50914), markSize: 24)
        case "Prime Video": AppTileStyle(background: Color(hex: 0x1A98FF), mark: "prime", markSize: 13)
        case "Disney+": AppTileStyle(background: Color(hex: 0x0B2A6B), mark: "D+")
        case "Apple TV": AppTileStyle(background: .black, mark: "tv", markSize: 17)
        case "Spotify": AppTileStyle(background: Color(hex: 0x1DB954), mark: "S", markColor: .black)
        case "Max": AppTileStyle(background: Color(hex: 0x002BE7), mark: "max", markSize: 15)
        case "YouTube Kids": AppTileStyle(background: Color(hex: 0xFF4E45), mark: "Kids", markSize: 13)
        default: AppTileStyle(background: Color(white: 0.25), mark: String(app.name.prefix(1)))
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct AppsTab: View {
    @ObservedObject var model: AppModel
    private let columns = Array(repeating: GridItem(.fixed(72), spacing: 0), count: 4)

    var body: some View {
        let live = model.link == .connected
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(KnownLinks.apps) { app in
                    AppTile(app: app, running: app.package == model.currentApp) { model.launch(app) }
                }
            }
            .opacity(live ? 1 : 0.45)
            .allowsHitTesting(live)
            Spacer(minLength: 0)
            Text("Click an app to open it on the TV")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .padding(.bottom, 12)
        }
    }
}

struct AppTile: View {
    let app: KnownApp
    let running: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let style = AppTileStyle.of(app)
        Button(action: open) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(style.background)
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    .overlay(Text(style.mark).font(.system(size: style.markSize, weight: .bold)).foregroundStyle(style.markColor))
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
                    .brightness(hover ? 0.06 : 0)
                Text(app.name)
                    .font(.system(size: 11, weight: running ? .medium : .regular))
                    .foregroundStyle(running ? Theme.label : Theme.secondary)
                    .lineLimit(1)
                Circle()
                    .fill(running ? Theme.label : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open \(app.name)")
    }
}

struct KeyboardTab: View {
    @ObservedObject var model: AppModel
    private let rows: [(String, String)] = [
        ("Submit", "↩"), ("Delete", "⌫"), ("Move cursor", "← →"),
        ("Paste", "⌘V"), ("Select all", "⌘A"), ("Back", "esc"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.typingError ?? (model.textField.active ? "Typing into \(model.currentApp.map { KnownLinks.displayName(for: $0) } ?? "TV")" : "Direct keyboard. Open a text box on the TV."))
                .font(.system(size: 12))
                .foregroundStyle(model.typingError == nil ? Theme.secondary : Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
            TVTypingView(state: model.typingDisplay, insert: model.insertText, key: model.textKey, clear: model.clearText, replace: model.replaceText, back: { model.press(.back) })
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill2))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(model.link == .connected ? 0.6 : 0), lineWidth: 2))
            HStack(spacing: 8) {
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) { model.insertText(text) }
                }
                .buttonStyle(PillButton(primary: false))
                .frame(width: 64)
                Button("Clear") { model.clearText() }
                    .buttonStyle(PillButton(primary: false))
                    .frame(width: 60)
                    .disabled(!model.textField.active)
                Spacer()
                Button("Done") { model.textKey(.enter) }
                    .buttonStyle(PillButton(primary: true))
                    .frame(width: 72)
            }
            .disabled(model.link != .connected)
            if !model.textField.active {
                Text("Preview of keys sent, not TV text. English letters, numbers and punctuation only.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SectionLabel(text: "Shortcuts").padding(.top, 14)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row.0).font(.system(size: 12)).foregroundStyle(Theme.label)
                        Spacer()
                        Text(row.1).font(Theme.mono).foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 27)
                    if i < rows.count - 1 {
                        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 12)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill2))
        }
        .onDisappear { model.pauseTyping() }
    }
}
