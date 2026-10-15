import CryptoKit
import Foundation
import Security

public struct RSAPublicNumbers: Equatable {
    public let modulus: Data
    public let exponent: Data

    public init(modulus: Data, exponent: Data) {
        self.modulus = modulus.droppingLeadingZeros()
        self.exponent = exponent.droppingLeadingZeros()
    }

    public init?(key: SecKey) {
        guard let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        self.init(pkcs1: der)
    }

    public init?(certificate: SecCertificate) {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        self.init(key: key)
    }

    /// Parses a PKCS#1 RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER exponent }.
    public init?(pkcs1 der: Data) {
        var reader = DERReader([UInt8](der))
        guard let seq = reader.read(tag: 0x30) else { return nil }
        var inner = DERReader(seq)
        guard let n = inner.read(tag: 0x02), let e = inner.read(tag: 0x02) else { return nil }
        self.init(modulus: Data(n), exponent: Data(e))
    }
}

struct DERReader {
    private let bytes: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(tag: UInt8) -> [UInt8]? {
        guard i < bytes.count, bytes[i] == tag else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, i + count <= bytes.count else { return nil }
            length = bytes[i..<i + count].reduce(0) { $0 << 8 | Int($1) }
            i += count
        }
        guard i + length <= bytes.count else { return nil }
        defer { i += length }
        return Array(bytes[i..<i + length])
    }
}

extension Data {
    func droppingLeadingZeros() -> Data {
        let trimmed = drop(while: { $0 == 0 })
        return trimmed.isEmpty ? Data([0]) : Data(trimmed)
    }
}

public enum PairingSecretError: Error, Equatable {
    case badFormat
    case codeMismatch
}

public enum PairingSecret {
    /// The TV shows 6 hex characters. The first byte is a checksum: it must equal the first
    /// byte of SHA-256(client n, client e, server n, server e, last two code bytes).
    public static func compute(code: String, client: RSAPublicNumbers, server: RSAPublicNumbers) throws -> Data {
        let code = code.uppercased()
        guard code.count == 6, let codeBytes = Data(hex: code) else { throw PairingSecretError.badFormat }
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: codeBytes.dropFirst())
        let digest = Data(hash.finalize())
        guard digest.first == codeBytes.first else { throw PairingSecretError.codeMismatch }
        return digest
    }
}

extension Data {
    public init?(hex: String) {
        var out = Data()
        var chars = hex.makeIterator()
        while let a = chars.next() {
            guard let b = chars.next(), let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(byte)
        }
        self = out
    }

    public var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClientIdentity {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    public let publicNumbers: RSAPublicNumbers

    public enum LoadError: Error, LocalizedError {
        case generationFailed(String)
        case importFailed(OSStatus)
        case badCertificate

        public var errorDescription: String? {
            switch self {
            case .generationFailed(let detail): "Couldn't create the remote's certificate: \(detail)"
            case .importFailed(let status): "Couldn't load the remote's certificate (\(status))."
            case .badCertificate: "The remote's certificate is unreadable."
            }
        }
    }

    // The p12 is protected by file permissions (0600 in a 0700 folder), not by this passphrase;
    // SecPKCS12Import just refuses empty ones.
    private static let passphrase = "iremote"

    public static func loadOrCreate(in directory: URL) throws -> ClientIdentity {
        let p12 = directory.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            try generate(at: p12)
        }
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else {
            throw LoadError.importFailed(status)
        }
        let identity = ref as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert, let numbers = RSAPublicNumbers(certificate: cert) else { throw LoadError.badCertificate }
        return ClientIdentity(identity: identity, certificate: cert, publicNumbers: numbers)
    }

    private static func generate(at p12: URL) throws {
        let fm = FileManager.default
        let dir = p12.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let work = dir.appendingPathComponent("tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let key = work.appendingPathComponent("key.pem").path
        let cert = work.appendingPathComponent("cert.pem").path
        let out = work.appendingPathComponent("identity.p12").path
        // An explicit config makes LibreSSL issue an X.509 v3 certificate; Apple's TLS rejects
        // the extension-less v1 certificate it creates by default.
        let config = work.appendingPathComponent("req.cnf")
        try """
        [req]
        distinguished_name=dn
        x509_extensions=v3
        prompt=no
        [dn]
        CN=iRemote
        [v3]
        basicConstraints=critical,CA:TRUE,pathlen:0
        keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
        extendedKeyUsage=serverAuth,clientAuth
        subjectAltName=DNS:iremote.local

        """.write(to: config, atomically: true, encoding: .utf8)
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                     "-config", config.path, "-keyout", key, "-out", cert])
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", out,
                     "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1",
                     "-passout", "pass:\(passphrase)"])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out)
        try fm.moveItem(atPath: out, toPath: p12.path)
    }

    private static func openssl(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw LoadError.generationFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LoadError.generationFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
