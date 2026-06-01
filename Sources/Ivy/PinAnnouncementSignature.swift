import Foundation
import Crypto

public enum PinAnnouncementSignature {
    private static let domain = "ivy.pinAnnounce.v1"
    public static let maxTTLSeconds: UInt64 = 86_400

    public static func signingMaterial(rootCID: String, publicKey: String, expiry: UInt64, fee: UInt64) -> Data {
        var data = Data()
        data.appendLengthPrefixedString(domain)
        data.appendLengthPrefixedString(rootCID)
        data.appendLengthPrefixedString(publicKey)
        data.appendUInt64(expiry)
        data.appendUInt64(fee)
        return data
    }

    public static func sign(rootCID: String, publicKey: String, expiry: UInt64, fee: UInt64, signingKey: Data) -> Data? {
        guard signingKey.count == 32,
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey) else {
            return nil
        }
        return try? privateKey.signature(for: signingMaterial(rootCID: rootCID, publicKey: publicKey, expiry: expiry, fee: fee))
    }

    public static func verify(rootCID: String, publicKey: String, expiry: UInt64, fee: UInt64, signature: Data) -> Bool {
        guard !signature.isEmpty,
              let publicKeyBytes = hexDecode(publicKey), publicKeyBytes.count == 32,
              let verifyKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes) else {
            return false
        }
        let material = signingMaterial(rootCID: rootCID, publicKey: publicKey, expiry: expiry, fee: fee)
        return verifyKey.isValidSignature(signature, for: material)
    }

    public static func isExpiryValid(_ expiry: UInt64, now: UInt64 = UInt64(Date().timeIntervalSince1970)) -> Bool {
        guard expiry > now else { return false }
        return expiry <= now.saturatingAdd(maxTTLSeconds)
    }

    private static func hexDecode(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? UInt64.max : result
    }
}
