import Foundation
import Crypto

public enum KeyDifficulty: Sendable {

    public static func trailingZeroBits(of publicKey: String) -> Int {
        let hash = SHA256.hash(data: Data(publicKey.utf8))
        var count = 0
        for byte in hash.reversed() {
            if byte == 0 {
                count += 8
            } else {
                count += byte.trailingZeroBitCount
                break
            }
        }
        return count
    }

    public static func trailingZeroBitsOfHash(_ hash: Data) -> Int {
        var count = 0
        for byte in hash.reversed() {
            if byte == 0 {
                count += 8
            } else {
                count += byte.trailingZeroBitCount
                break
            }
        }
        return count
    }

    public static func baseTrust(
        publicKey: String,
        minDifficulty: Int = 0,
        maxDifficulty: Int = 32
    ) -> Double {
        let bits = trailingZeroBits(of: publicKey)
        guard bits > minDifficulty else { return 0 }
        if bits >= maxDifficulty { return 1.0 }
        return Double(bits - minDifficulty) / Double(maxDifficulty - minDifficulty)
    }
}
