import Foundation

public struct InventorySet: Sendable {
    private var recent: BoundedSet<String>

    public init(capacity: Int = 65_536, bloomBits: Int = 1 << 20, bloomHashes: Int = 7) {
        self.recent = BoundedSet(capacity: capacity)
    }

    public mutating func insert(_ cid: String) {
        recent.insert(cid)
    }

    public func contains(_ cid: String) -> Bool {
        recent.contains(cid)
    }

    @discardableResult
    public mutating func remove(_ cid: String) -> Bool {
        recent.remove(cid)
    }

    public var count: Int { recent.count }
}

struct BloomFilter: Sendable {
    private var bits: [UInt64]
    private let bitCount: Int
    private let hashCount: Int

    init(bits bitCount: Int, hashCount: Int) {
        self.bitCount = max(1, bitCount)
        self.hashCount = max(0, hashCount)
        self.bits = [UInt64](repeating: 0, count: (self.bitCount + 63) / 64)
    }

    mutating func insert(_ item: String) {
        for idx in computeHashes(item) {
            bits[idx / 64] |= 1 << (idx % 64)
        }
    }

    func mightContain(_ item: String) -> Bool {
        for idx in computeHashes(item) {
            if bits[idx / 64] & (1 << (idx % 64)) == 0 { return false }
        }
        return true
    }

    private func computeHashes(_ item: String) -> [Int] {
        let bytes = Array(item.utf8)
        let h1 = fnv1a(bytes)
        let h2 = murmur(bytes)
        return Self.bitPositions(h1: h1, h2: h2, hashCount: hashCount, bitCount: bitCount)
    }

    static func bitPositions(h1: Int, h2: Int, hashCount: Int, bitCount: Int) -> [Int] {
        let bitCount = max(1, bitCount)
        let hashCount = max(0, hashCount)
        var result = [Int]()
        result.reserveCapacity(hashCount)
        let modulus = UInt(bitCount)
        let base = UInt(bitPattern: h1)
        let step = UInt(bitPattern: h2)
        for i in 0..<hashCount {
            let hash = base &+ UInt(i) &* step
            result.append(Int(hash % modulus))
        }
        return result
    }

    private func fnv1a(_ bytes: [UInt8]) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return Int(truncatingIfNeeded: hash)
    }

    private func murmur(_ bytes: [UInt8]) -> Int {
        var h: UInt64 = 0x9747b28c
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x5bd1e995
            h ^= h >> 15
        }
        return Int(truncatingIfNeeded: h)
    }
}
