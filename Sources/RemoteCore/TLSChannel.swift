import Foundation
import Network
import Security

/// One TLS connection carrying varint-length-delimited protobuf messages.
/// Every callback is delivered on the main queue.
public final class TLSChannel {
    public enum State: Equatable {
        case ready
        case untrusted
        case closed(String?)
    }

    public var onState: ((State) -> Void)?
    public var onMessage: ((ProtoMessage) -> Void)?
    private let connection: NWConnection
    private let queue = DispatchQueue.main
    private let captured: CertificateSlot
    private var framer = Framer()
    private var closed = false

    public init(host: String, port: UInt16, identity: SecIdentity, pinnedCertificateSHA256: String? = nil) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let local = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, local)
        }
        // Pairing establishes trust with the screen code. Later sessions must match the pin
        // inside the TLS verifier, before any application data is accepted.
        let captured = CertificateSlot()
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let ref = sec_trust_copy_ref(trust).takeRetainedValue()
            captured.certificate = (SecTrustCopyCertificateChain(ref) as? [SecCertificate])?.first
            guard let certificate = captured.certificate else { complete(false); return }
            if let pin = pinnedCertificateSHA256 {
                captured.rejected = (SecCertificateCopyData(certificate) as Data).sha256Hex != pin
            }
            complete(!captured.rejected)
        }, queue)
        self.captured = captured
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    public var serverCertificate: SecCertificate? { captured.certificate }

    public var serverCertificateSHA256: String? {
        serverCertificate.map { (SecCertificateCopyData($0) as Data).sha256Hex }
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.ready)
                self.receive()
            case .waiting(let error):
                self.fail(error.localizedDescription)
            case .failed(let error):
                self.fail(error.localizedDescription)
            case .cancelled:
                self.fail(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: ProtoWriter) {
        guard !closed else { return }
        connection.send(content: Framer.frame(message.data), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        })
    }

    public func close() {
        closed = true
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for raw in try self.framer.append(data) {
                        let message = try ProtoMessage(raw)
                        guard !self.closed else { return }
                        self.onMessage?(message)
                    }
                } catch {
                    self.fail("The TV sent a malformed message.")
                    return
                }
            }
            if let error { self.fail(error.localizedDescription); return }
            if isComplete { self.fail("The TV closed the connection."); return }
            self.receive()
        }
    }

    private func fail(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        emit(captured.rejected ? .untrusted : .closed(reason))
    }

    private func emit(_ state: State) {
        onState?(state)
    }
}

private final class CertificateSlot {
    var certificate: SecCertificate?
    var rejected = false
}
