import AppKit
import RemoteCore
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: FloatingPanel
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Theme.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame = NSRect(origin: .zero, size: Theme.panelSize)
        panel.contentView = host

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "av.remote", accessibilityDescription: "iRemote")
                ?? NSImage(systemSymbolName: "tv", accessibilityDescription: "iRemote")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    var isOpen: Bool { panel.isVisible }

    @objc func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard anchor.midY >= screen.maxY else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.open() }
            return
        }
        var x = anchor.midX - Theme.panelSize.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - Theme.panelSize.width - 8)
        let y = anchor.minY - 6 - Theme.panelSize.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        if model.link != .connected { model.reconnectNow() }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            let used = MainActor.assumeIsolated { self?.handleKey(code: code, chars: chars, plain: plain) ?? false }
            return used ? nil : event
        }
    }

    func close() {
        model.pauseTyping()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    /// Remote shortcuts while the panel is key. Returns true when the key was used.
    private func handleKey(code: UInt16, chars: String?, plain: Bool) -> Bool {
        guard panel.isKeyWindow, model.pairing == nil, model.tab != .keyboard, plain else { return false }
        let key: KeyCode?
        switch code {
        case 123: key = .dpadLeft
        case 124: key = .dpadRight
        case 125: key = .dpadDown
        case 126: key = .dpadUp
        case 36, 76: key = .dpadCenter
        case 53, 51: key = .back
        default:
            switch chars {
            case " ": key = .playPause
            case "h": key = .home
            case "m": key = .volumeMute
            case "-", "_": key = .volumeDown
            case "=", "+": key = .volumeUp
            default: key = nil
            }
        }
        guard let key else { return false }
        model.press(key)
        return true
    }
}
