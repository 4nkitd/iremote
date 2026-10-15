import CryptoKit
@testable import FakeTVKit
@testable import RemoteCore
import XCTest

final class ProtoTests: XCTestCase {
    func testHostileLengthsAndVarintsAreRejected() {
        for length in [UInt64.max, UInt64(Int.max)] {
            var w = ProtoWriter()
            w.varint(10)
            w.varint(length)
            XCTAssertThrowsError(try ProtoMessage(w.data))
        }
        let overflow = Data(Array(repeating: UInt8(0xFF), count: 9) + [2])
        XCTAssertThrowsError(try ProtoMessage(Data([8]) + overflow))
        var framer = Framer()
        XCTAssertThrowsError(try framer.append(overflow))
        XCTAssertThrowsError(try ProtoMessage(Data([0, 1])))
    }
    func testRoundTripNestedMessage() throws {
        var w = ProtoWriter()
        w.int(1, 2)
        w.int(2, 200)
        w.message(10) { r in r.string(1, "atvremote"); r.string(2, "iRemote") }
        let m = try ProtoMessage(w.data)
        XCTAssertEqual(m.int(1), 2)
        XCTAssertEqual(m.int(2), 200)
        XCTAssertEqual(m.message(10)?.string(1), "atvremote")
        XCTAssertEqual(m.message(10)?.string(2), "iRemote")
        XCTAssertFalse(m.has(11))
    }

    func testEmptySubmessageIsPresent() throws {
        var w = ProtoWriter()
        w.message(31) { _ in }
        XCTAssertTrue(try ProtoMessage(w.data).has(31))
    }

    func testMatchesProtobufWireBytes() {
        var w = ProtoWriter()
        w.int(1, 150)
        XCTAssertEqual([UInt8](w.data), [0x08, 0x96, 0x01])
    }

    func testTruncatedMessageThrows() {
        XCTAssertThrowsError(try ProtoMessage(Data([0x0A, 0x05, 0x01])))
    }

    func testFramerHandlesSplitsAndBatches() throws {
        var a = ProtoWriter(); a.int(1, 7)
        var b = ProtoWriter(); b.string(2, String(repeating: "x", count: 300))
        let stream = Framer.frame(a.data) + Framer.frame(b.data)
        var framer = Framer()
        var out: [Data] = []
        for byte in stream { out += try framer.append(Data([byte])) }
        XCTAssertEqual(out, [a.data, b.data])
        var whole = Framer()
        XCTAssertEqual(try whole.append(stream), [a.data, b.data])
    }

    func testFramerRejectsHugeLength() {
        var framer = Framer()
        var w = ProtoWriter(); w.varint(UInt64(Framer.maxMessage + 1))
        XCTAssertThrowsError(try framer.append(w.data))
    }
}

final class PairingSecretTests: XCTestCase {
    let client = RSAPublicNumbers(modulus: Data([0x00, 0xC1, 0x02, 0x03]), exponent: Data([0x01, 0x00, 0x01]))
    let server = RSAPublicNumbers(modulus: Data([0xD4, 0x05, 0x06]), exponent: Data([0x00, 0x01, 0x00, 0x01]))

    func testLeadingZerosAreDropped() {
        XCTAssertEqual(client.modulus, Data([0xC1, 0x02, 0x03]))
        XCTAssertEqual(server.exponent, Data([0x01, 0x00, 0x01]))
    }

    func testMatchesReferenceHash() throws {
        // Same input order as androidtvremote2: client n, client e, server n, server e, code[2:].
        var h = SHA256()
        h.update(data: Data([0xC1, 0x02, 0x03, 0x01, 0x00, 0x01, 0xD4, 0x05, 0x06, 0x01, 0x00, 0x01, 0xAB, 0xCD]))
        let digest = Data(h.finalize())
        let code = String(format: "%02X", digest[0]) + "abcd"
        XCTAssertEqual(try PairingSecret.compute(code: code, client: client, server: server), digest)
    }

    func testWrongChecksumIsRejected() throws {
        let (code, _) = FakeTV.makeCode(client: client, server: server)
        let bad = String(format: "%02X", (UInt8(code.prefix(2), radix: 16)! &+ 1)) + code.dropFirst(2)
        XCTAssertThrowsError(try PairingSecret.compute(code: bad, client: client, server: server)) {
            XCTAssertEqual($0 as? PairingSecretError, .codeMismatch)
        }
    }

    func testBadFormatIsRejected() {
        for code in ["12345", "1234567", "GG1234", ""] {
            XCTAssertThrowsError(try PairingSecret.compute(code: code, client: client, server: server)) {
                XCTAssertEqual($0 as? PairingSecretError, .badFormat)
            }
        }
    }

    func testPKCS1Parsing() {
        // SEQUENCE { INTEGER 0x00C10203, INTEGER 0x010001 }
        let der = Data([0x30, 0x0B, 0x02, 0x04, 0x00, 0xC1, 0x02, 0x03, 0x02, 0x03, 0x01, 0x00, 0x01])
        XCTAssertEqual(RSAPublicNumbers(pkcs1: der), client)
        XCTAssertNil(RSAPublicNumbers(pkcs1: Data([0x30, 0x05, 0x02])))
    }
}

final class IntegrationTests: XCTestCase {
    static var clientDir: URL!
    static var tvDir: URL!

    override class func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iremote-tests-\(UUID().uuidString)")
        clientDir = base.appendingPathComponent("client")
        tvDir = base.appendingPathComponent("tv")
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: clientDir.deletingLastPathComponent())
    }

    func testIdentityIsCreatedOncePrivatelyAndReloads() throws {
        let a = try ClientIdentity.loadOrCreate(in: Self.clientDir)
        let b = try ClientIdentity.loadOrCreate(in: Self.clientDir)
        XCTAssertEqual(a.publicNumbers, b.publicNumbers)
        XCTAssertEqual(a.publicNumbers.exponent, Data([0x01, 0x00, 0x01]))
        XCTAssertEqual(a.publicNumbers.modulus.count, 256)
        let p12 = Self.clientDir.appendingPathComponent("identity.p12").path
        let perms = try FileManager.default.attributesOfItem(atPath: p12)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: Self.clientDir.path)
        XCTAssertEqual(leftovers, ["identity.p12"])
    }

    func testPairThenControl() throws {
        let client = try ClientIdentity.loadOrCreate(in: Self.clientDir)
        let tv = FakeTV(identity: try ClientIdentity.loadOrCreate(in: Self.tvDir))
        defer { tv.stop() }
        let up = expectation(description: "listening")
        try tv.start { up.fulfill() }
        wait(for: [up], timeout: 5)

        // Pair: a wrong code is rejected without ending the session, then the right one works.
        var code = ""
        tv.onCode = { code = $0 }
        let awaiting = expectation(description: "awaiting code")
        let wrong = expectation(description: "wrong code")
        let paired = expectation(description: "paired")
        var pin = ""
        var pairing: PairingSession!
        pairing = PairingSession(host: "127.0.0.1", port: tv.pairingPort, identity: client) { event in
            switch event {
            case .awaitingCode: awaiting.fulfill()
            case .invalidCode: wrong.fulfill()
            case .paired(let hash): pin = hash; paired.fulfill()
            case .failed(let reason): XCTFail("pairing failed: \(reason)")
            }
        }
        pairing.start()
        wait(for: [awaiting], timeout: 10)
        XCTAssertEqual(code.count, 6)
        let bad = String(format: "%02X", (UInt8(code.prefix(2), radix: 16)! &+ 1)) + code.dropFirst(2)
        pairing.submit(code: bad)
        wait(for: [wrong], timeout: 2)
        pairing.submit(code: code.lowercased())
        wait(for: [paired], timeout: 10)
        XCTAssertEqual(tv.pairedClients.count, 1)

        // Control: connect, receive state, send keys and an app link.
        let connected = expectation(description: "connected")
        let gotApp = expectation(description: "current app")
        let gotVolume = expectation(description: "volume 18")
        let louder = expectation(description: "volume 19")
        let onNetflix = expectation(description: "netflix")
        var volumes: [Int] = []
        let remote = RemoteSession(host: "127.0.0.1", port: tv.remotePort, identity: client, pinnedCertificateSHA256: pin) { event in
            switch event {
            case .connected: connected.fulfill()
            case .currentApp(let p):
                if p == "com.google.android.youtube.tv" { gotApp.fulfill() }
                if p == "com.netflix.ninja" { onNetflix.fulfill() }
            case .volume(let v):
                volumes.append(v.level)
                if v.level == 18, volumes.count == 1 { gotVolume.fulfill() }
                if v.level == 19 { louder.fulfill() }
            case .disconnected(let r): XCTFail("disconnected: \(r ?? "-")")
            case .untrustedTV: XCTFail("untrusted")
            case .power, .textField, .typingError: break
            }
        }
        remote.start()
        wait(for: [connected, gotApp, gotVolume], timeout: 10)
        remote.press(.volumeUp)
        remote.press(.dpadCenter)
        remote.launch("https://www.netflix.com/title")
        wait(for: [louder, onNetflix], timeout: 5)
        XCTAssertEqual(tv.log.keys, [KeyCode.volumeUp.rawValue, KeyCode.dpadCenter.rawValue])
        XCTAssertEqual(tv.log.links, ["https://www.netflix.com/title"])
        remote.close()
    }

    func testWrongPinnedCertificateIsRefused() throws {
        let client = try ClientIdentity.loadOrCreate(in: Self.clientDir)
        let tv = FakeTV(identity: try ClientIdentity.loadOrCreate(in: Self.tvDir))
        defer { tv.stop() }
        let up = expectation(description: "listening")
        try tv.start { up.fulfill() }
        wait(for: [up], timeout: 5)
        tv.trust(clientCertificateSHA256: (SecCertificateCopyData(client.certificate) as Data).sha256Hex)
        let refused = expectation(description: "untrusted")
        let remote = RemoteSession(host: "127.0.0.1", port: tv.remotePort, identity: client, pinnedCertificateSHA256: String(repeating: "0", count: 64)) { event in
            if event == .untrustedTV { refused.fulfill() }
            if event == .connected { XCTFail("connected to an unpinned TV") }
        }
        remote.start()
        wait(for: [refused], timeout: 10)
        XCTAssertTrue(tv.log.keys.isEmpty)
    }

    func testUnpairedClientIsRejectedByTV() throws {
        let client = try ClientIdentity.loadOrCreate(in: Self.clientDir)
        let tvIdentity = try ClientIdentity.loadOrCreate(in: Self.tvDir)
        let tv = FakeTV(identity: tvIdentity)
        defer { tv.stop() }
        let up = expectation(description: "listening")
        try tv.start { up.fulfill() }
        wait(for: [up], timeout: 5)
        let pin = (SecCertificateCopyData(tvIdentity.certificate) as Data).sha256Hex
        let dropped = expectation(description: "disconnected")
        let remote = RemoteSession(host: "127.0.0.1", port: tv.remotePort, identity: client, pinnedCertificateSHA256: pin) { event in
            if case .disconnected = event { dropped.fulfill() }
            if event == .connected { XCTFail("unpaired client got in") }
        }
        remote.start()
        wait(for: [dropped], timeout: 10)
    }

    func testPrematurePairingAcknowledgementIsRejected() throws {
        let client = try ClientIdentity.loadOrCreate(in: Self.clientDir)
        var events: [PairingSession.Event] = []
        let session = PairingSession(host: "127.0.0.1", identity: client) { events.append($0) }
        var ack = ProtoWriter()
        ack.int(1, 2)
        ack.int(2, 200)
        ack.message(41) { _ in }
        session.handle(try ProtoMessage(ack.data))
        XCTAssertEqual(events.count, 1)
        if case .failed = events[0] {} else { XCTFail("Accepted unsolicited pairing") }
        session.handle(try ProtoMessage(ack.data))
        XCTAssertEqual(events.count, 1)
    }

    func testTypingOverTLSAndIdlePings() throws {
        let client = try ClientIdentity.loadOrCreate(in: Self.clientDir)
        let tvIdentity = try ClientIdentity.loadOrCreate(in: Self.tvDir)
        let tv = FakeTV(identity: tvIdentity)
        defer { tv.stop() }
        tv.trust(clientCertificateSHA256: (SecCertificateCopyData(client.certificate) as Data).sha256Hex)
        tv.focusText("a")
        let up = expectation(description: "up")
        try tv.start { up.fulfill() }
        wait(for: [up], timeout: 5)
        let focused = expectation(description: "focused")
        let typed = expectation(description: "typed")
        let pin = (SecCertificateCopyData(tvIdentity.certificate) as Data).sha256Hex
        var complete = false
        let remote = RemoteSession(host: "127.0.0.1", port: tv.remotePort, identity: client, pinnedCertificateSHA256: pin) { event in
            if case .textField(let field) = event {
                if field.value == "a", field.active { focused.fulfill() }
                if field.value == "a😀hello world", !complete { complete = true; typed.fulfill() }
            }
            if case .typingError(let error) = event { XCTFail(error) }
            if case .disconnected(let error) = event { XCTFail(error ?? "disconnected") }
        }
        remote.start()
        wait(for: [focused], timeout: 5)
        remote.insertText("😀")
        remote.insertText("hello world")
        wait(for: [typed], timeout: 5)
        let idle = expectation(description: "survives idle watchdog")
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { idle.fulfill() }
        wait(for: [idle], timeout: 20)
        XCTAssertEqual(tv.fieldText, "a😀hello world")
        XCTAssertEqual(tv.fieldCursor, "a😀hello world".utf16.count)
        XCTAssertTrue(tv.log.keys.isEmpty)
        remote.close()
    }
}
