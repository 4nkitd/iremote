import RemoteCore
import SwiftUI

struct PairView: View {
    @ObservedObject var model: AppModel
    @FocusState private var codeFocused: Bool

    private var state: PairingState { model.pairing ?? PairingState() }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "tv")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 26)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.label)
                .padding(.top, 12)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(state.message == nil ? Theme.secondary : Theme.accent)
                .multilineTextAlignment(.center)
                .frame(minHeight: 32, alignment: .top)
                .padding(.top, 4)
                .padding(.horizontal, 16)

            if case .choosing = state.phase {
                chooser
            } else {
                codeEntry
            }
            Spacer(minLength: 0)
            Text("The code is 6 characters, 0–9 and A–F. The pairing key stays on this Mac and never leaves your network.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private var title: String {
        if let name = state.tvName { return "Pair with \(name)" }
        return "Pair a TV"
    }

    private var subtitle: String {
        if let message = state.message { return message }
        switch state.phase {
        case .choosing: return "Choose a Google TV on this network."
        case .connecting: return "Asking the TV for a code…"
        case .awaitingCode: return "Enter the code shown on your TV."
        case .verifying: return "Checking the code…"
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "TVs on this network").padding(.top, 12)
            VStack(spacing: 0) {
                if model.discovered.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for TVs…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                }
                ForEach(Array(model.discovered.enumerated()), id: \.element.id) { i, tv in
                    TVRow(name: tv.name, paired: model.tvs.contains { $0.name == tv.name }) { model.pair(with: tv) }
                    if i < model.discovered.count - 1 {
                        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 42)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill2))
            if !model.tvs.isEmpty {
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelPairing() }
                        .buttonStyle(PillButton(primary: false))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
    }

    private var codeEntry: some View {
        let entering: Bool = { if case .awaitingCode = state.phase { return true }; return false }()
        let chars = Array(state.code)
        return VStack(spacing: 20) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        let active = entering && i == chars.count
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(Text(i < chars.count ? String(chars[i]) : "").font(.system(size: 22, design: .monospaced)).foregroundStyle(Theme.label))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(active ? 0.7 : 0), lineWidth: 2))
                            .frame(width: 40, height: 48)
                    }
                }
                TextField("", text: Binding(get: { state.code }, set: { model.updateCode($0) }))
                    .textFieldStyle(.plain)
                    .focused($codeFocused)
                    .opacity(0.01)
                    .frame(width: 280, height: 48)
                    .onSubmit { model.submitCode() }
                    .disabled(!entering)
            }
            .padding(.top, 8)
            .onAppear { codeFocused = true }
            .onChange(of: entering) { _, now in if now { codeFocused = true } }

            HStack(spacing: 8) {
                Button("Cancel") { model.cancelPairing() }
                    .buttonStyle(PillButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(state.phase == .verifying(state.tvName ?? "") ? "Pairing…" : "Pair") { model.submitCode() }
                    .buttonStyle(PillButton(primary: true))
                    .disabled(!entering || chars.count < 6)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct TVRow: View {
    let name: String
    let paired: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "tv")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18)
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.label)
                Spacer()
                if paired {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.connected)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Theme.fill : .clear).padding(4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PillButton: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.white : Theme.label)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(primary ? Theme.accent : Theme.fill)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .opacity(enabled ? 1 : 0.4)
    }
}
