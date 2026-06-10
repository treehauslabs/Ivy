import Foundation
import Crypto
import Tally
#if canImport(os)
import os
#endif

public struct Router: Sendable {
    public let localID: PeerID
    public let localHash: [UInt8]
    private let k: Int
    private let _state: LockedState<State>

    public init(localID: PeerID, k: Int = 20) {
        self.localID = localID
        self.localHash = Self.hash(localID.publicKey)
        self.k = k
        self._state = LockedState(initialState: State())
    }

    struct State: Sendable {
        var buckets: [[BucketEntry]] = Array(repeating: [], count: 256)
        var replacementCaches: [[BucketEntry]] = Array(repeating: [], count: 256)
        var hashCache: [String: [UInt8]] = [:]
    }

    public struct BucketEntry: Sendable {
        public let id: PeerID
        public let hash: [UInt8]
        public let endpoint: PeerEndpoint
        public var lastSeen: ContinuousClock.Instant
    }

    public func addPeer(_ id: PeerID, endpoint: PeerEndpoint, tally: Tally) {
        addPeer(id, hash: cachedHash(id.publicKey), endpoint: endpoint, tally: tally)
    }

    public func cachedHash(_ key: String) -> [UInt8] {
        _state.withLock { state in
            if let cached = state.hashCache[key] { return cached }
            let h = Self.hash(key)
            if state.hashCache.count < 10_000 {
                state.hashCache[key] = h
            }
            return h
        }
    }

    public func addPeer(_ id: PeerID, hash peerHash: [UInt8], endpoint: PeerEndpoint, tally _: Tally) {
        let idx = min(Self.commonPrefixLength(localHash, peerHash), 255)

        _state.withLock { state in
            let bucket = state.buckets[idx]
            for i in 0..<bucket.count {
                if bucket[i].id == id {
                    state.buckets[idx][i].lastSeen = .now
                    return
                }
            }
            if bucket.count < k {
                state.buckets[idx].append(BucketEntry(id: id, hash: peerHash, endpoint: endpoint, lastSeen: .now))
                return
            }

            var replacements = state.replacementCaches[idx]
            if let existing = replacements.firstIndex(where: { $0.id == id }) {
                replacements.remove(at: existing)
            }
            replacements.append(BucketEntry(id: id, hash: peerHash, endpoint: endpoint, lastSeen: .now))
            while replacements.count > k {
                replacements.removeFirst()
            }
            state.replacementCaches[idx] = replacements
        }
    }

    public func pingResult(id: PeerID, alive: Bool) {
        let peerHash = cachedHash(id.publicKey)
        let idx = min(Self.commonPrefixLength(localHash, peerHash), 255)

        _state.withLock { state in
            guard let entryIndex = state.buckets[idx].firstIndex(where: { $0.id == id }) else { return }

            if alive {
                state.buckets[idx][entryIndex].lastSeen = .now
                if !state.replacementCaches[idx].isEmpty {
                    state.replacementCaches[idx].removeFirst()
                }
                return
            }

            state.buckets[idx].remove(at: entryIndex)
            while !state.replacementCaches[idx].isEmpty {
                let promoted = state.replacementCaches[idx].removeFirst()
                guard !state.buckets[idx].contains(where: { $0.id == promoted.id }) else { continue }
                state.buckets[idx].append(BucketEntry(
                    id: promoted.id,
                    hash: promoted.hash,
                    endpoint: promoted.endpoint,
                    lastSeen: .now
                ))
                break
            }
        }
    }

    public func removePeer(_ id: PeerID) {
        let peerHash = cachedHash(id.publicKey)
        let idx = min(Self.commonPrefixLength(localHash, peerHash), 255)
        _state.withLock { state in
            state.buckets[idx].removeAll { $0.id == id }
            state.replacementCaches[idx].removeAll { $0.id == id }
        }
    }

    public func closestPeers(to target: [UInt8], count: Int) -> [BucketEntry] {
        _state.withLock { state in
            var candidates = state.buckets.flatMap { $0 }
            candidates.sort { Self.isCloser($0.hash, than: $1.hash, to: target) }
            return Array(candidates.prefix(count))
        }
    }

    public func closestPeers(to target: String, count: Int) -> [BucketEntry] {
        closestPeers(to: Self.hash(target), count: count)
    }

    public func allPeers() -> [BucketEntry] {
        _state.withLock { state in
            state.buckets.flatMap { $0 }
        }
    }

    public func peerCount() -> Int {
        _state.withLock { state in
            state.buckets.reduce(0) { $0 + $1.count }
        }
    }

    public func bucketIndex(for peerKey: String) -> Int {
        min(Self.commonPrefixLength(localHash, Self.hash(peerKey)), 255)
    }

    public static func hash(_ key: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(key.utf8)))
    }

    static let truncatedHashLength = 16

    public static func hash(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    public static func truncatedHash(_ data: Data) -> Data {
        Data(hash(data).prefix(truncatedHashLength))
    }

    public static func destinationHash(name: String, identityHash: Data) -> Data {
        let nameHash = Data(hash(Data(name.utf8)).prefix(10))
        let material = nameHash + identityHash
        return truncatedHash(material)
    }

    public static func commonPrefixLength(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var cpl = 0
        for (x, y) in zip(a, b) {
            let xored = x ^ y
            if xored == 0 {
                cpl += 8
            } else {
                cpl += xored.leadingZeroBitCount
                break
            }
        }
        return cpl
    }

    public static func xorDistance(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        zip(a, b).map { $0 ^ $1 }
    }

    @inline(__always)
    public static func isCloser(_ a: [UInt8], than b: [UInt8], to target: [UInt8]) -> Bool {
        for i in 0..<min(a.count, min(b.count, target.count)) {
            let da = a[i] ^ target[i]
            let db = b[i] ^ target[i]
            if da != db { return da < db }
        }
        return false
    }
}

extension [UInt8]: @retroactive Comparable {
    public static func < (lhs: [UInt8], rhs: [UInt8]) -> Bool {
        for (a, b) in zip(lhs, rhs) {
            if a != b { return a < b }
        }
        return lhs.count < rhs.count
    }
}
