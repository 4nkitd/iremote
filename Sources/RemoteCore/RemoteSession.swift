import Foundation

public enum KeyCode: Int {
    case home = 3, back = 4, dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22, dpadCenter = 23
    case volumeUp = 24, volumeDown = 25, power = 26, enter = 66, playPause = 85, volumeMute = 164
    case deleteBackward = 67, deleteForward = 112, moveHome = 122, moveEnd = 123
}

public struct VolumeInfo: Equatable {
    public var level: Int
    public var max: Int
    public var muted: Bool

    public init(level: Int, max: Int, muted: Bool) {
        self.level = level
        self.max = max
        self.muted = muted
    }

    static func decode(_ message: ProtoMessage) -> VolumeInfo? {
        let maximum = message.uint(6), level = message.uint(7)
        guard maximum > 0, maximum <= 1000, level <= maximum else { return nil }
        return VolumeInfo(level: Int(level), max: Int(maximum), muted: message.bool(8))
    }
}

/// Remote-control protocol on port 6466. Callbacks run on the main queue.
public final class RemoteSession {
    public enum Event: Equatable {
        case connected
        case disconnected(String?)
        case untrustedTV
        case power(Bool)
        case currentApp(String)
        case volume(VolumeInfo)
        case textField(TextFieldState)
        case typingError(String)
    }

    public static let port: UInt16 = 6466

    private enum Field {
        static let configure = 1, setActive = 2, error = 3, pingRequest = 8, pingResponse = 9
        static let keyInject = 10, imeKeyInject = 20, start = 40, setVolume = 50, appLink = 90
    }

    // IME supplies both focused text-field updates and the current app.
    static let features = 1 | 2 | 4 | 32 | 64 | 512

    private let channel: TLSChannel
    private let pinnedCertificateSHA256: String
    private let onEvent: (Event) -> Void
    private var active = features
    private var started = false
    private var ended = false
    private var watchdog: DispatchWorkItem?
    private lazy var textInput = TVTextInput(
        send: { [weak self] message in
            guard let self, self.started, !self.ended else { return }
            if let m = try? ProtoMessage(message.data), let batch = m.message(21) {
                InputDiagnostics.record("send.edit", ["app": batch.int(1), "field": batch.int(2), "cursor": batch.message(3)?.message(2)?.int(2) ?? -1])
            }
            self.channel.send(message)
        },
        changed: { [weak self] in self?.onEvent(.textField($0)) },
        failed: { [weak self] in self?.onEvent(.typingError($0)) }
    )

    public init(host: String, port: UInt16 = RemoteSession.port, identity: ClientIdentity, pinnedCertificateSHA256: String, onEvent: @escaping (Event) -> Void) {
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.onEvent = onEvent
        channel = TLSChannel(host: host, port: port, identity: identity.identity, pinnedCertificateSHA256: pinnedCertificateSHA256)
    }

    public func start() {
        channel.onState = { [weak self] state in
            guard let self, !self.ended else { return }
            switch state {
            case .ready:
                guard self.channel.serverCertificateSHA256 == self.pinnedCertificateSHA256 else {
                    self.end(.untrustedTV)
                    return
                }
                self.feedWatchdog()
            case .closed(let reason):
                self.end(.disconnected(reason))
            case .untrusted:
                self.end(.untrustedTV)
            }
        }
        channel.onMessage = { [weak self] in self?.handle($0) }
        channel.start()
    }

    public func close() {
        ended = true
        watchdog?.cancel()
        textInput.reset()
        channel.close()
    }

    public func press(_ key: KeyCode) {
        send { w in w.message(Field.keyInject) { k in k.int(1, key.rawValue); k.int(2, 3) } }
    }

    public func launch(_ link: String) {
        send { w in w.message(Field.appLink) { $0.string(1, link) } }
    }

    public func insertText(_ text: String) {
        guard started, !ended else { return }
        textInput.insert(text)
    }

    public func typeHardware(_ text: String) -> Bool {
        guard started, !ended else { return false }
        guard let strokes = HardwareKeyboard.strokes(for: text) else {
            onEvent(.typingError("Direct typing supports English letters, numbers and punctuation, up to 512 characters per paste."))
            return false
        }
        InputDiagnostics.record("send.hardware", ["strokes": strokes.count])
        for stroke in strokes {
            send { w in w.message(Field.keyInject) { key in key.int(1, stroke.code); key.int(2, stroke.direction) } }
        }
        return true
    }

    public func textKey(_ key: KeyCode) {
        guard started, !ended else { return }
        textInput.key(key)
    }

    public func clearText() {
        guard started, !ended else { return }
        textInput.clear()
    }

    public func replaceText(_ range: NSRange, with text: String) {
        guard started, !ended else { return }
        textInput.replace(range, with: text)
    }

    public func cancelTyping() { textInput.cancelPending() }

    private func send(_ build: (inout ProtoWriter) -> Void) {
        guard started, !ended else { return }
        var w = ProtoWriter()
        build(&w)
        channel.send(w)
    }

    private func reply(_ build: (inout ProtoWriter) -> Void) {
        var w = ProtoWriter()
        build(&w)
        channel.send(w)
    }

    private func handle(_ m: ProtoMessage) {
        guard !ended else { return }
        feedWatchdog()
        textInput.receive(m)
        if let cfg = m.message(Field.configure) {
            active = Self.features & cfg.int(1)
            InputDiagnostics.record("configure", ["supported": cfg.int(1), "active": active])
            reply { w in
                w.message(Field.configure) { c in
                    c.int(1, self.active)
                    c.message(2) { d in
                        d.int(3, 1)
                        d.string(4, "1")
                        d.string(5, "atvremote")
                        d.string(6, "1.0.0")
                    }
                }
            }
        } else if m.has(Field.setActive) {
            reply { w in w.message(Field.setActive) { $0.int(1, self.active) } }
        } else if let ping = m.message(Field.pingRequest) {
            reply { w in w.message(Field.pingResponse) { $0.int(1, ping.int(1)) } }
        } else if let s = m.message(Field.start) {
            if !started {
                started = true
                onEvent(.connected)
            }
            onEvent(.power(s.bool(1)))
        } else if let ime = m.message(Field.imeKeyInject), let app = ime.message(1) {
            let package = app.string(12)
            if !package.isEmpty { onEvent(.currentApp(package)) }
        } else if let v = m.message(Field.setVolume), let volume = VolumeInfo.decode(v) {
            onEvent(.volume(volume))
        }
    }

    /// The TV pings every 5 s; three missed pings means the link is dead.
    private func feedWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.end(.disconnected("The TV stopped responding.")) }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 16, execute: item)
    }

    private func end(_ event: Event) {
        guard !ended else { return }
        ended = true
        watchdog?.cancel()
        channel.close()
        textInput.reset()
        onEvent(event)
    }
}
