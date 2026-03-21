import Foundation

public struct InventorySet: Sendable {
    private var recent: BoundedSet<String>
    private var filter: BloomFilter

    public init(capacity: Int = 65_536, bloomBits: Int = 1 << 20, bloomHashes: Int = 7) {
        self.recent = BoundedSet(capacity: capacity)
        self.filter = BloomFilter(bits: bloomBits, hashCount: bloomHashes)
    }

    public mutating func insert(_ cid: String) {
        recent.insert(cid)
        filter.insert(cid)
    }

    public func contains(_ cid: String) -> Bool {
        recent.contains(cid) || filter.mightContain(cid)
    }

    public var count: Int { recent.count }
}

struct BloomFilter: Sendable {
    private var bits: [UInt64]
    private let bitCount: Int
    private let hashCount: Int

    init(bits bitCount: Int, hashCount: Int) {
        self.bitCount = bitCount
        self.hashCount = hashCount
        self.bits = [UInt64](repeating: 0, count: (bitCount + 63) / 64)
    }

    mutating func insert(_ item: String) {
        let hashes = computeHashes(item)
        for h in hashes {
            let idx = h % bitCount
            bits[idx / 64] |= 1 << (idx % 64)
        }
    }

    func mightContain(_ item: String) -> Bool {
        let hashes = computeHashes(item)
        for h in hashes {
            let idx = h % bitCount
            if bits[idx / 64] & (1 << (idx % 64)) == 0 { return false }
        }
        return true
    }

    private func computeHashes(_ item: String) -> [Int] {
        let bytes = Array(item.utf8)
        let h1 = fnv1a(bytes)
        let h2 = murmur(bytes)
        var result = [Int]()
        result.reserveCapacity(hashCount)
        for i in 0..<hashCount {
            result.append(abs(h1 &+ i &* h2))
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
