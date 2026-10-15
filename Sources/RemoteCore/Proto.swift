import Foundation

public struct ProtoWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    public mutating func int(_ field: Int, _ value: Int) {
        varint(UInt64(field << 3))
        varint(UInt64(bitPattern: Int64(value)))
    }

    public mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field << 3 | 2))
        varint(UInt64(value.count))
        data.append(value)
    }

    public mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

public enum ProtoError: Error, Equatable {
    case truncated
    case malformed
    case unsupportedWireType(Int)
}

public struct ProtoMessage {
    private var varints: [Int: UInt64] = [:]
    private var blobs: [Int: [Data]] = [:]

    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let key = try Self.readVarint(bytes, &i)
            guard key >> 3 > 0, key >> 3 <= 0x1FFF_FFFF else { throw ProtoError.malformed }
            let field = Int(key >> 3)
            switch Int(key & 7) {
            case 0:
                varints[field] = try Self.readVarint(bytes, &i)
            case 1:
                guard i + 8 <= bytes.count else { throw ProtoError.truncated }
                i += 8
            case 2:
                let rawLength = try Self.readVarint(bytes, &i)
                guard rawLength <= UInt64(bytes.count - i) else { throw ProtoError.truncated }
                let length = Int(rawLength)
                blobs[field, default: []].append(Data(bytes[i..<i + length]))
                i += length
            case 5:
                guard i + 4 <= bytes.count else { throw ProtoError.truncated }
                i += 4
            case let wire:
                throw ProtoError.unsupportedWireType(wire)
            }
        }
    }

    static func readVarint(_ bytes: [UInt8], _ i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard shift < 64 else { throw ProtoError.malformed }
            guard i < bytes.count else { throw ProtoError.truncated }
            let b = bytes[i]
            i += 1
            guard shift != 63 || b <= 1 else { throw ProtoError.malformed }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    public func has(_ field: Int) -> Bool { varints[field] != nil || blobs[field] != nil }
    public func int(_ field: Int) -> Int { Int(truncatingIfNeeded: varints[field] ?? 0) }
    public func uint(_ field: Int) -> UInt64 { varints[field] ?? 0 }
    public func bool(_ field: Int) -> Bool { (varints[field] ?? 0) != 0 }
    public func data(_ field: Int) -> Data? { blobs[field]?.last }
    public func string(_ field: Int) -> String { data(field).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public func message(_ field: Int) -> ProtoMessage? { data(field).flatMap { try? ProtoMessage($0) } }
}

public struct Framer {
    private var buffer: [UInt8] = []
    public static let maxMessage = 1 << 20

    public init() {}

    public static func frame(_ payload: Data) -> Data {
        var w = ProtoWriter()
        w.varint(UInt64(payload.count))
        return w.data + payload
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var out: [Data] = []
        while !buffer.isEmpty {
            var i = 0
            let length: UInt64
            do {
                length = try ProtoMessage.readVarint(buffer, &i)
            } catch ProtoError.truncated {
                break
            }
            guard length <= UInt64(Self.maxMessage) else { throw ProtoError.truncated }
            let end = i + Int(length)
            guard buffer.count >= end else { break }
            out.append(Data(buffer[i..<end]))
            buffer.removeFirst(end)
        }
        return out
    }
}
