import AppKit
import RemoteCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            VisualEffect()
            Theme.surface.opacity(0.82)
            Group {
                if let error = model.fatalError {
                    ErrorView(message: error)
                } else if model.pairing != nil {
                    PairView(model: model)
                } else {
                    VStack(spacing: 0) {
                        HeaderView(model: model)
                        SegmentedTabs(selection: $model.tab)
                            .padding(.top, 20)
                        Group {
                            switch model.tab {
                            case .remote: RemoteTab(model: model).padding(.top, 20)
                            case .apps: AppsTab(model: model).padding(.top, 20)
                            case .keyboard: KeyboardTab(model: model).padding(.top, 16)
                            }
                        }
                        Spacer(minLength: 0)
                        FooterView(typing: model.tab == .keyboard)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }
            }
        }
        .frame(width: Theme.panelSize.width, height: Theme.panelSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    ForEach(model.tvs) { tv in
                        Button {
                            model.select(tv)
                        } label: {
                            if tv.name == model.selectedName { Label(tv.name, systemImage: "checkmark") } else { Text(tv.name) }
                        }
                    }
                    Divider()
                    Button("Pair a New TV…") { model.beginPairing() }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.selected?.name ?? "No TV")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Menu {
                    if model.link == .untrusted {
                        Button("Pair Again…") { model.beginPairing() }
                    } else if model.link != .connected, model.selected != nil {
                        Button("Reconnect") { model.reconnectNow() }
                    }
                    if let name = model.selectedName {
                        Button("Forget \(name)") { model.forgetSelected() }
                    }
                    Divider()
                    Button("Quit iRemote") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.fill))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")

                CircleIconButton(symbol: "power", help: model.isOn ? "Turn TV off" : "Turn TV on") { model.press(.power) }
                    .opacity(model.link == .connected ? 1 : 0.4)
            }
        }
    }

    private var dotColor: Color {
        switch model.link {
        case .connected: model.isOn ? Theme.connected : Theme.secondary
        case .connecting: Theme.accent
        case .offline, .untrusted: Theme.tertiary
        }
    }

    private var status: String {
        switch model.link {
        case .connected:
            guard model.isOn else { return "Connected · TV is off" }
            return "Connected" + (model.currentApp.map { " · " + KnownLinks.displayName(for: $0) } ?? "")
        case .connecting: return "Connecting…"
        case .untrusted: return "TV identity changed · pair again"
        case .offline(let reason): return reason == nil ? "Offline" : "Offline · retrying"
        }
    }
}

struct SegmentedTabs: View {
    @Binding var selection: AppModel.Tab
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppModel.Tab.allCases, id: \.self) { tab in
                let on = tab == selection
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.label : Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) { selection = tab }
                    }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill2))
    }
}

struct FooterView: View {
    var typing = false
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack {
                Text(typing ? "Type with your Mac keyboard. Return submits." : "Arrow keys, return and esc work while this is open")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                Spacer()
            }
            .frame(height: 43)
        }
    }
}

struct ErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Theme.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Quit iRemote") { NSApp.terminate(nil) }
        }
        .padding(24)
    }
}
