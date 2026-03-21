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
    }

    public struct BucketEntry: Sendable {
        public let id: PeerID
        public let hash: [UInt8]
        public let endpoint: PeerEndpoint
        public var lastSeen: ContinuousClock.Instant
    }

    public func addPeer(_ id: PeerID, endpoint: PeerEndpoint, tally: Tally) {
        addPeer(id, hash: Self.hash(id.publicKey), endpoint: endpoint, tally: tally)
    }

    public func addPeer(_ id: PeerID, hash peerHash: [UInt8], endpoint: PeerEndpoint, tally: Tally) {
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
            let newRep = tally.reputation(for: id)
            var worstIdx = 0
            var worstRep = tally.reputation(for: bucket[0].id)
            for i in 1..<bucket.count {
                let rep = tally.reputation(for: bucket[i].id)
                if rep < worstRep {
                    worstRep = rep
                    worstIdx = i
                }
            }
            if newRep > worstRep {
                state.buckets[idx][worstIdx] = BucketEntry(id: id, hash: peerHash, endpoint: endpoint, lastSeen: .now)
            }
        }
    }

    public func closestPeers(to target: [UInt8], count: Int) -> [BucketEntry] {
        _state.withLock { state in
            let targetBucket = min(Self.commonPrefixLength(localHash, target), 255)

            var candidates: [BucketEntry] = []
            candidates.reserveCapacity(count * 2)

            candidates.append(contentsOf: state.buckets[targetBucket])

            var lo = targetBucket - 1
            var hi = targetBucket + 1
            while candidates.count < count && (lo >= 0 || hi < 256) {
                if hi < 256 {
                    candidates.append(contentsOf: state.buckets[hi])
                    hi += 1
                }
                if lo >= 0 {
                    candidates.append(contentsOf: state.buckets[lo])
                    lo -= 1
                }
            }

            if candidates.count <= count {
                return candidates
            }
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
