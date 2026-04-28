import Foundation
import Crypto

public struct NodeRecord: Sendable, Equatable {
    public let publicKey: String
    public let host: String
    public let port: UInt16
    public let sequenceNumber: UInt64
    public let signature: Data

    public static let maxSize = 300

    public init(publicKey: String, host: String, port: UInt16, sequenceNumber: UInt64, signature: Data) {
        self.publicKey = publicKey
        self.host = host
        self.port = port
        self.sequenceNumber = sequenceNumber
        self.signature = signature
    }

    public static func create(publicKey: String, host: String, port: UInt16, sequenceNumber: UInt64, signingKey: Data) -> NodeRecord? {
        guard signingKey.count == 32 else { return nil }
        guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey) else { return nil }
        let material = signingMaterial(publicKey: publicKey, host: host, port: port, sequenceNumber: sequenceNumber)
        guard let sig = try? privateKey.signature(for: material) else { return nil }
        return NodeRecord(publicKey: publicKey, host: host, port: port, sequenceNumber: sequenceNumber, signature: sig)
    }

    public func verify() -> Bool {
        guard let pubKeyBytes = hexDecode(publicKey), pubKeyBytes.count == 32,
              let verifyKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            return false
        }
        let material = Self.signingMaterial(publicKey: publicKey, host: host, port: port, sequenceNumber: sequenceNumber)
        return verifyKey.isValidSignature(signature, for: material)
    }

    private static func signingMaterial(publicKey: String, host: String, port: UInt16, sequenceNumber: UInt64) -> Data {
        var data = Data()
        data.append(contentsOf: publicKey.utf8)
        data.append(contentsOf: host.utf8)
        var p = port.bigEndian
        data.append(Data(bytes: &p, count: 2))
        var s = sequenceNumber.bigEndian
        data.append(Data(bytes: &s, count: 8))
        return data
    }

    public func serialize() -> Data {
        var buf = Data()
        buf.appendLengthPrefixedString(publicKey)
        buf.appendLengthPrefixedString(host)
        buf.appendUInt16(port)
        buf.appendUInt64(sequenceNumber)
        buf.appendLengthPrefixedData(signature)
        return buf
    }

    static func deserialize(_ reader: inout DataReader) -> NodeRecord? {
        guard let publicKey = reader.readString(),
              let host = reader.readString(),
              let port = reader.readUInt16(),
              let sequenceNumber = reader.readUInt64(),
              let signature = reader.readData() else {
            return nil
        }
        return NodeRecord(publicKey: publicKey, host: host, port: port, sequenceNumber: sequenceNumber, signature: signature)
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
