import FakeTVKit
import Foundation
import RemoteCore

// A pretend Google TV for trying iRemote without a real one. Advertises itself over Bonjour
// on the standard ports and prints the pairing code it would show on screen.

let name = CommandLine.arguments.dropFirst().first ?? "Fake TV"
let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/iRemote-FakeTV")
let trustFile = dir.appendingPathComponent("trusted.txt")

do {
    let identity = try ClientIdentity.loadOrCreate(in: dir)
    let tv = FakeTV(identity: identity, name: name, advertise: true)
    for hash in (try? String(contentsOf: trustFile, encoding: .utf8))?.split(separator: "\n") ?? [] {
        tv.trust(clientCertificateSHA256: String(hash))
    }
    tv.onLog = { line in
        print("[\(name)] \(line)")
        if line == "paired" {
            try? tv.pairedClients.sorted().joined(separator: "\n").write(to: trustFile, atomically: true, encoding: .utf8)
        }
    }
    tv.onCode = { code in print("[\(name)] >>> code on screen: \(code)") }
    try tv.start(pairingPort: PairingSession.port, remotePort: RemoteSession.port) {
        print("[\(name)] listening: pairing \(tv.pairingPort), remote \(tv.remotePort)")
    }
} catch {
    print("FakeTV failed: \(error)")
    exit(1)
}
setvbuf(stdout, nil, _IOLBF, 0)
dispatchMain()
