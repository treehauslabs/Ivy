import Foundation
import Crypto

public struct NodeRecord: Sendable, Equatable {
    public let publicKey: String
    public let host: String
    public let port: UInt16
    public let sequenceNumber: UInt64
    public let issuedAt: UInt64
    public let expiresAt: UInt64
    public let signature: Data

    public static let maxSize = 340
    public static let defaultTTLSeconds: UInt64 = 86_400
    public static let maxTTLSeconds: UInt64 = 86_400
    public static let maxFutureSkewSeconds: UInt64 = 300

    public init(
        publicKey: String,
        host: String,
        port: UInt16,
        sequenceNumber: UInt64,
        issuedAt: UInt64,
        expiresAt: UInt64,
        signature: Data
    ) {
        self.publicKey = publicKey
        self.host = host
        self.port = port
        self.sequenceNumber = sequenceNumber
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    public static func create(
        publicKey: String,
        host: String,
        port: UInt16,
        sequenceNumber: UInt64,
        signingKey: Data,
        issuedAt: UInt64 = UInt64(Date().timeIntervalSince1970),
        ttlSeconds: UInt64 = NodeRecord.defaultTTLSeconds
    ) -> NodeRecord? {
        guard signingKey.count == 32 else { return nil }
        guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey) else { return nil }
        let ttl = min(ttlSeconds, maxTTLSeconds)
        let expiresAt = issuedAt.saturatingAdd(ttl)
        let material = signingMaterial(
            publicKey: publicKey,
            host: host,
            port: port,
            sequenceNumber: sequenceNumber,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        guard let sig = try? privateKey.signature(for: material) else { return nil }
        return NodeRecord(
            publicKey: publicKey,
            host: host,
            port: port,
            sequenceNumber: sequenceNumber,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signature: sig
        )
    }

    public func verify(at now: UInt64 = UInt64(Date().timeIntervalSince1970)) -> Bool {
        guard isTimeValid(at: now) else { return false }
        guard let pubKeyBytes = hexDecode(publicKey), pubKeyBytes.count == 32,
              let verifyKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            return false
        }
        let material = Self.signingMaterial(
            publicKey: publicKey,
            host: host,
            port: port,
            sequenceNumber: sequenceNumber,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        return verifyKey.isValidSignature(signature, for: material)
    }

    public func isExpired(at now: UInt64 = UInt64(Date().timeIntervalSince1970)) -> Bool {
        expiresAt <= now
    }

    public func isTimeValid(at now: UInt64 = UInt64(Date().timeIntervalSince1970)) -> Bool {
        guard expiresAt > issuedAt else { return false }
        guard expiresAt - issuedAt <= Self.maxTTLSeconds else { return false }
        guard issuedAt <= now.saturatingAdd(Self.maxFutureSkewSeconds) else { return false }
        guard expiresAt > now else { return false }
        return true
    }

    private static func signingMaterial(
        publicKey: String,
        host: String,
        port: UInt16,
        sequenceNumber: UInt64,
        issuedAt: UInt64,
        expiresAt: UInt64
    ) -> Data {
        var data = Data()
        data.appendLengthPrefixedString("ivy.nodeRecord.v2")
        data.append(contentsOf: publicKey.utf8)
        data.append(contentsOf: host.utf8)
        var p = port.bigEndian
        data.append(Data(bytes: &p, count: 2))
        var s = sequenceNumber.bigEndian
        data.append(Data(bytes: &s, count: 8))
        var issued = issuedAt.bigEndian
        data.append(Data(bytes: &issued, count: 8))
        var expires = expiresAt.bigEndian
        data.append(Data(bytes: &expires, count: 8))
        return data
    }

    public func serialize() -> Data {
        var buf = Data()
        buf.appendLengthPrefixedString(publicKey)
        buf.appendLengthPrefixedString(host)
        buf.appendUInt16(port)
        buf.appendUInt64(sequenceNumber)
        buf.appendUInt64(issuedAt)
        buf.appendUInt64(expiresAt)
        buf.appendLengthPrefixedData(signature)
        return buf
    }

    static func deserialize(_ reader: inout DataReader) -> NodeRecord? {
        guard let publicKey = reader.readString(),
              let host = reader.readString(),
              let port = reader.readUInt16(),
              let sequenceNumber = reader.readUInt64(),
              let issuedAt = reader.readUInt64(),
              let expiresAt = reader.readUInt64(),
              let signature = reader.readData() else {
            return nil
        }
        return NodeRecord(
            publicKey: publicKey,
            host: host,
            port: port,
            sequenceNumber: sequenceNumber,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signature: signature
        )
    }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? UInt64.max : result
    }
}

private func hexDecode(_ hex: String) -> Data? {
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        guard nextIndex != index else { return nil }
        guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
        data.append(byte)
        index = nextIndex
    }
    return data
}
