import Foundation

/// Pairing ("polo") protocol on port 6467. Callbacks run on the main queue.
public final class PairingSession {
    public enum Event: Equatable {
        case awaitingCode
        case invalidCode(String)
        case paired(serverCertificateSHA256: String)
        case failed(String)
    }

    public static let port: UInt16 = 6467
    static let statusOK = 200

    private enum Field {
        static let pairingRequest = 10, pairingRequestAck = 11
        static let options = 20, configuration = 30, configurationAck = 31
        static let secret = 40, secretAck = 41
    }

    private let channel: TLSChannel
    private let client: ClientIdentity
    private let clientName: String
    private let onEvent: (Event) -> Void
    private var finished = false
    private enum Phase { case connecting, request, options, configuration, code, secret }
    private var phase = Phase.connecting
    private var timeout: DispatchWorkItem?

    public init(host: String, port: UInt16 = PairingSession.port, identity: ClientIdentity, clientName: String = "iRemote", onEvent: @escaping (Event) -> Void) {
        self.client = identity
        self.clientName = clientName
        self.onEvent = onEvent
        channel = TLSChannel(host: host, port: port, identity: identity.identity)
    }

    public func start() {
        channel.onState = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                self.phase = .request
                self.send { w in
                    w.message(Field.pairingRequest) { r in
                        r.string(1, "atvremote")
                        r.string(2, self.clientName)
                    }
                }
                self.armTimeout()
            case .closed(let reason):
                self.finish(.failed(reason ?? "The TV closed the pairing connection."))
            case .untrusted:
                self.finish(.failed("The TV's certificate could not be verified."))
            }
        }
        channel.onMessage = { [weak self] in self?.handle($0) }
        channel.start()
    }

    public func submit(code: String) {
        guard !finished, phase == .code else { return }
        guard let cert = channel.serverCertificate, let server = RSAPublicNumbers(certificate: cert) else {
            finish(.failed("The TV's certificate is unreadable."))
            return
        }
        let secret: Data
        do {
            secret = try PairingSecret.compute(code: code, client: client.publicNumbers, server: server)
        } catch PairingSecretError.codeMismatch {
            onEvent(.invalidCode("That code doesn't match. Check the code on the TV."))
            return
        } catch {
            onEvent(.invalidCode("The code is 6 characters, 0–9 and A–F."))
            return
        }
        phase = .secret
        send { w in w.message(Field.secret) { $0.bytes(1, secret) } }
        armTimeout()
    }

    public func cancel() {
        finished = true
        timeout?.cancel()
        channel.close()
    }

    func handle(_ message: ProtoMessage) {
        guard !finished else { return }
        guard message.int(2) == Self.statusOK else {
            finish(.failed(phase == .secret ? "The TV rejected the code." : "The TV refused pairing (status \(message.int(2)))."))
            return
        }
        if phase == .request, message.has(Field.pairingRequestAck) {
            phase = .options
            send { w in
                w.message(Field.options) { o in
                    o.message(1) { e in e.int(1, 3); e.int(2, 6) }
                    o.int(3, 1)
                }
            }
        } else if phase == .options, message.has(Field.options) {
            phase = .configuration
            send { w in
                w.message(Field.configuration) { c in
                    c.message(1) { e in e.int(1, 3); e.int(2, 6) }
                    c.int(2, 1)
                }
            }
        } else if phase == .configuration, message.has(Field.configurationAck) {
            timeout?.cancel()
            phase = .code
            onEvent(.awaitingCode)
        } else if phase == .secret, message.has(Field.secretAck) {
            guard let hash = channel.serverCertificateSHA256 else {
                finish(.failed("The TV's certificate is unreadable."))
                return
            }
            finish(.paired(serverCertificateSHA256: hash))
        } else {
            finish(.failed("The TV sent an unexpected pairing response. Try pairing again."))
        }
    }

    private func send(_ build: (inout ProtoWriter) -> Void) {
        var w = ProtoWriter()
        w.int(1, 2)
        w.int(2, Self.statusOK)
        build(&w)
        channel.send(w)
    }

    private func armTimeout() {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.finish(.failed("The TV didn't answer in time.")) }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    private func finish(_ event: Event) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        channel.close()
        onEvent(event)
    }
}
