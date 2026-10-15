import CryptoKit
import Foundation
import Network
import RemoteCore
import Security

/// A stand-in Google TV: the pairing and remote protocols over TLS, for tests and manual runs.
/// Callbacks run on the main queue.
public final class FakeTV {
    public struct Log: Equatable {
        public var keys: [Int] = []
        public var links: [String] = []
    }

    public var onCode: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public private(set) var log = Log()
    public private(set) var pairedClients: Set<String> = []
    public private(set) var volume = VolumeInfo(level: 18, max: 100, muted: false)
    public private(set) var isOn = true
    public private(set) var app = "com.google.android.youtube.tv"
    public private(set) var fieldText = ""
    public private(set) var fieldCursor = 0
    private var fieldCounter = 1
    private var fieldActive = false

    private let identity: ClientIdentity
    private let name: String
    private let advertise: Bool
    private var pairingListener: NWListener?
    private var remoteListener: NWListener?
    private var remotes: [Peer] = []
    private var peers: [Peer] = []

    public private(set) var pairingPort: UInt16 = 0
    public private(set) var remotePort: UInt16 = 0

    public init(identity: ClientIdentity, name: String = "Fake TV", advertise: Bool = false) {
        self.identity = identity
        self.name = name
        self.advertise = advertise
    }

    /// Ports of 0 pick free ones. Calls `ready` once both listeners are up.
    public func start(pairingPort: UInt16 = 0, remotePort: UInt16 = 0, ready: @escaping () -> Void) throws {
        var pending = 2
        let done = { pending -= 1; if pending == 0 { ready() } }
        pairingListener = try listener(port: pairingPort, service: nil) { [weak self] peer in self?.servePairing(peer) } onReady: { [weak self] port in
            self?.pairingPort = port; done()
        }
        remoteListener = try listener(port: remotePort, service: advertise ? NWListener.Service(name: name, type: Discovery.serviceType) : nil) { [weak self] peer in
            self?.serveRemote(peer)
        } onReady: { [weak self] port in
            self?.remotePort = port; done()
        }
    }

    public func stop() {
        pairingListener?.cancel()
        remoteListener?.cancel()
        let closing = peers
        closing.forEach { $0.close() }
        peers.removeAll()
        remotes.removeAll()
    }

    public func focusText(_ text: String = "") {
        fieldActive = true
        fieldText = text
        fieldCursor = text.utf16.count
        fieldCounter += 1
        remotes.forEach { sendApp($0) }
    }

    public func trust(clientCertificateSHA256 hash: String) {
        pairedClients.insert(hash)
    }

    public func setVolume(_ level: Int) {
        volume.level = max(0, min(volume.max, level))
        remotes.forEach { sendVolume($0) }
    }

    // MARK: Pairing

    private func servePairing(_ peer: Peer) {
        var expected: Data?
        peer.onMessage = { [weak self, weak peer] m in
            guard let self, let peer else { return }
            func reply(_ build: (inout ProtoWriter) -> Void, status: Int = 200) {
                var w = ProtoWriter()
                w.int(1, 2)
                w.int(2, status)
                build(&w)
                peer.send(w)
            }
            if m.has(10) {
                reply { $0.message(11) { $0.string(1, self.name) } }
            } else if m.has(20) {
                reply { w in w.message(20) { o in o.message(1) { e in e.int(1, 3); e.int(2, 6) }; o.int(3, 1) } }
            } else if m.has(30) {
                guard let client = peer.clientNumbers else { peer.close(); return }
                let (code, secret) = Self.makeCode(client: client, server: self.identity.publicNumbers)
                expected = secret
                reply { $0.message(31) { _ in } }
                self.emit("pairing code \(code)")
                self.onCode?(code)
            } else if let s = m.message(40) {
                if let expected, s.data(1) == expected, let hash = peer.clientCertificateSHA256 {
                    self.pairedClients.insert(hash)
                    reply { $0.message(41) { $0.bytes(1, expected) } }
                    self.emit("paired")
                } else {
                    reply({ _ in }, status: 402)
                    self.emit("bad secret")
                }
            }
        }
    }

    static func makeCode(client: RSAPublicNumbers, server: RSAPublicNumbers) -> (String, Data) {
        let tail = Data((0..<2).map { _ in UInt8.random(in: 0...255) })
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: tail)
        let digest = Data(hash.finalize())
        let code = ([digest[0]] + tail).map { String(format: "%02X", $0) }.joined()
        return (code, digest)
    }

    // MARK: Remote

    private func serveRemote(_ peer: Peer) {
        guard let hash = peer.clientCertificateSHA256, pairedClients.contains(hash) else {
            emit("rejected an unpaired client")
            peer.close()
            return
        }
        remotes.append(peer)
        peer.startPings()
        peer.onMessage = { [weak self, weak peer] m in
            guard let self, let peer else { return }
            if m.has(1) {
                var w = ProtoWriter()
                w.message(2) { _ in }
                peer.send(w)
            } else if m.has(2) {
                self.sendStart(peer)
                self.sendApp(peer)
                self.sendVolume(peer)
            } else if let k = m.message(10) {
                self.key(k.int(1))
            } else if let batch = m.message(21) {
                guard self.fieldActive, batch.int(1) == 7, batch.int(2) == self.fieldCounter,
                      let edit = batch.message(3)?.message(2) else { return }
                let text = edit.string(3)
                guard edit.int(1) == self.fieldCursor + text.utf16.count else { return }
                let string = self.fieldText as NSString
                self.fieldText = string.replacingCharacters(in: NSRange(location: self.fieldCursor, length: 0), with: text)
                self.fieldCursor += text.utf16.count
                self.fieldCounter += 1
                self.sendTextEcho(peer)
            } else if let l = m.message(90) {
                let link = l.string(1)
                self.log.links.append(link)
                self.emit("open \(link)")
                self.app = KnownLinks.package(for: link) ?? link
                self.remotes.forEach { self.sendApp($0) }
            }
        }
        var w = ProtoWriter()
        w.message(1) { c in
            c.int(1, 615)
            c.message(2) { d in d.string(1, "Fake TV"); d.string(2, "iRemote") }
        }
        peer.send(w)
    }

    private func key(_ code: Int) {
        log.keys.append(code)
        emit("key \(KeyCode(rawValue: code).map { "\($0)" } ?? "\(code)")")
        switch KeyCode(rawValue: code) {
        case .volumeUp: setVolume(volume.level + 1)
        case .volumeDown: setVolume(volume.level - 1)
        case .volumeMute:
            volume.muted.toggle()
            remotes.forEach { sendVolume($0) }
        case .power:
            isOn.toggle()
            remotes.forEach { sendStart($0) }
        case .home:
            app = "com.google.android.apps.tv.launcherx"
            remotes.forEach { sendApp($0) }
        case .moveEnd:
            fieldCursor = fieldText.utf16.count
            echoCursor()
        case .moveHome:
            fieldCursor = 0
            echoCursor()
        case .dpadLeft where fieldActive:
            if fieldCursor > 0 { fieldCursor = (fieldText as NSString).rangeOfComposedCharacterSequence(at: fieldCursor - 1).location }
            echoCursor()
        case .dpadRight where fieldActive:
            if fieldCursor < fieldText.utf16.count { fieldCursor = NSMaxRange((fieldText as NSString).rangeOfComposedCharacterSequence(at: fieldCursor)) }
            echoCursor()
        case .deleteBackward:
            if fieldActive, fieldCursor > 0 {
                let value = fieldText as NSString
                let range = value.rangeOfComposedCharacterSequence(at: fieldCursor - 1)
                fieldText = value.replacingCharacters(in: range, with: "")
                fieldCursor = range.location
                fieldCounter += 1
                remotes.forEach { sendTextEcho($0) }
            }
        default: break
        }
    }

    private func sendStart(_ peer: Peer) {
        var w = ProtoWriter()
        w.message(40) { $0.int(1, self.isOn ? 1 : 0) }
        peer.send(w)
    }

    private func echoCursor() {
        guard fieldActive else { return }
        fieldCounter += 1
        remotes.forEach { sendTextEcho($0) }
    }

    private func sendApp(_ peer: Peer) {
        var w = ProtoWriter()
        w.message(20) { i in
            i.message(1) { a in a.int(1, 7); a.string(12, self.app) }
            if fieldActive { i.message(2) { field in encodeField(&field) } }
        }
        peer.send(w)
    }

    private func encodeField(_ field: inout ProtoWriter) {
        field.int(1, fieldCounter)
        field.string(2, fieldText)
        field.int(3, fieldCursor)
        field.int(4, fieldCursor)
        field.string(6, "Search")
    }

    private func sendTextEcho(_ peer: Peer) {
        var w = ProtoWriter()
        w.message(22) { $0.message(2) { encodeField(&$0) } }
        peer.send(w)
    }

    private func sendVolume(_ peer: Peer) {
        var w = ProtoWriter()
        w.message(50) { v in v.int(6, self.volume.max); v.int(7, self.volume.level); v.int(8, self.volume.muted ? 1 : 0) }
        peer.send(w)
    }

    private func emit(_ line: String) {
        onLog?(line)
    }

    // MARK: Listener plumbing

    private func listener(port: UInt16, service: NWListener.Service?, accept: @escaping (Peer) -> Void, onReady: @escaping (UInt16) -> Void) throws -> NWListener {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_peer_authentication_required(sec, true)
        sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, .main)
        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.service = service
        listener.newConnectionHandler = { [weak self] connection in
            let peer = Peer(connection: connection)
            self?.peers.append(peer)
            peer.onReady = { [weak peer] in if let peer { accept(peer) } }
            peer.onClose = { [weak self, weak peer] in
                self?.peers.removeAll { $0 === peer }
                self?.remotes.removeAll { $0 === peer }
            }
            peer.start()
        }
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state { onReady(listener?.port?.rawValue ?? 0) }
        }
        listener.start(queue: .main)
        return listener
    }
}

final class Peer {
    var onReady: (() -> Void)?
    var onMessage: ((ProtoMessage) -> Void)?
    var onClose: (() -> Void)?
    private(set) var clientCertificate: SecCertificate?
    private let connection: NWConnection
    private var framer = Framer()
    private var closed = false
    private var pingTimer: DispatchSourceTimer?

    init(connection: NWConnection) {
        self.connection = connection
    }

    var clientNumbers: RSAPublicNumbers? { clientCertificate.flatMap { RSAPublicNumbers(certificate: $0) } }
    var clientCertificateSHA256: String? { clientCertificate.map { (SecCertificateCopyData($0) as Data).sha256Hex } }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let meta = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    sec_protocol_metadata_access_peer_certificate_chain(meta.securityProtocolMetadata) { cert in
                        if self.clientCertificate == nil { self.clientCertificate = sec_certificate_copy_ref(cert).takeRetainedValue() }
                    }
                }
                self.onReady?()
                self.receive()
            case .failed, .cancelled:
                self.close()
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ w: ProtoWriter) {
        connection.send(content: Framer.frame(w.data), completion: .idempotent)
    }

    func close() {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel()
        pingTimer = nil
        connection.cancel()
        onClose?()
        onReady = nil
        onMessage = nil
        onClose = nil
    }

    func startPings() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            var w = ProtoWriter()
            w.message(8) { $0.int(1, 1) }
            self?.send(w)
        }
        pingTimer = timer
        timer.resume()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, let messages = try? self.framer.append(data) {
                for raw in messages { if let m = try? ProtoMessage(raw) { self.onMessage?(m) } }
            }
            if complete || error != nil { self.close(); return }
            self.receive()
        }
    }
}
