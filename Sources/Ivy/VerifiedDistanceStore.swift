import Foundation
import Acorn
import Tally

public protocol EvictionProtectionPolicy: Sendable {
    func isProtected(_ cid: String) async -> Bool
}

public struct NoProtection: EvictionProtectionPolicy, Sendable {
    public init() {}
    public func isProtected(_ cid: String) async -> Bool { false }
}

public actor VerifiedDistanceStore: AcornCASWorker {
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?
    public var timeout: Duration? { nil }

    private let inner: any AcornCASWorker
    private let nodeHash: [UInt8]
    private var cidEntries: BoundedDictionary<String, [UInt8]>
    private let maxEntries: Int
    public var protectionPolicy: any EvictionProtectionPolicy

    // Sentinel distance for protected items (all zeros = closest possible)
    private static let protectedDistance = [UInt8](repeating: 0, count: 32)

    public init(inner: any AcornCASWorker, nodePublicKey: String, maxEntries: Int = 100_000, protectionPolicy: any EvictionProtectionPolicy = NoProtection()) {
        self.inner = inner
        self.nodeHash = Router.hash(nodePublicKey)
        self.maxEntries = maxEntries
        self.cidEntries = BoundedDictionary(capacity: maxEntries)
        self.protectionPolicy = protectionPolicy
    }

    // MARK: - AcornCASWorker

    public func has(cid: ContentIdentifier) async -> Bool {
        await inner.has(cid: cid)
    }

    public func getLocal(cid: ContentIdentifier) async -> Data? {
        guard let data = await inner.getLocal(cid: cid) else { return nil }
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return nil }
        return data
    }

    public func storeLocal(cid: ContentIdentifier, data: Data) async {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return }

        if await protectionPolicy.isProtected(cid.rawValue) {
            cidEntries[cid.rawValue] = Self.protectedDistance
            await inner.storeLocal(cid: cid, data: data)
            return
        }

        let cidHash = Router.hash(cid.rawValue)
        let distance = Router.xorDistance(nodeHash, cidHash)

        if cidEntries.count >= maxEntries {
            if let mostDistant = await findMostDistant(), mostDistant.distance > distance {
                cidEntries[cid.rawValue] = distance
                await inner.storeLocal(cid: cid, data: data)
            }
        } else {
            cidEntries[cid.rawValue] = distance
            await inner.storeLocal(cid: cid, data: data)
        }
    }

    public func storeVerified(cid: ContentIdentifier, data: Data) async {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return }
        let cidHash = Router.hash(cid.rawValue)
        cidEntries[cid.rawValue] = Router.xorDistance(nodeHash, cidHash)
        await inner.storeLocal(cid: cid, data: data)
    }

    // MARK: - Distance queries

    public func xorDistance(to cid: String) -> [UInt8] {
        Router.xorDistance(nodeHash, Router.hash(cid))
    }

    public func isCloserThan(cid: String, threshold: [UInt8]) -> Bool {
        xorDistance(to: cid) < threshold
    }

    public var entryCount: Int { cidEntries.count }

    // MARK: - Zone Queries

    /// Returns stored CIDs closest to `targetHash`, for responding to zone inventory requests.
    public func storedCIDsClosestTo(hash targetHash: [UInt8], limit: Int) -> [String] {
        let allCIDs = Array(cidEntries.keys)
        guard !allCIDs.isEmpty else { return [] }

        var withDistances: [(cid: String, distance: [UInt8])] = allCIDs.map { cid in
            let cidHash = Router.hash(cid)
            let dist = Router.xorDistance(targetHash, cidHash)
            return (cid, dist)
        }

        withDistances.sort { $0.distance < $1.distance }
        return Array(withDistances.prefix(limit).map(\.cid))
    }

    /// Returns a random sample of stored CIDs for replication checks.
    public func sampleStoredCIDs(count: Int) -> [String] {
        let allCIDs = Array(cidEntries.keys)
        guard !allCIDs.isEmpty else { return [] }
        if allCIDs.count <= count { return allCIDs }
        return Array(allCIDs.shuffled().prefix(count))
    }

    /// Returns all CID keys currently tracked for distance-based storage.
    public var trackedCIDCount: Int { cidEntries.count }

    // MARK: - Eviction

    private struct DistantEntry {
        let cid: String
        let distance: [UInt8]
    }

    private func findMostDistant() async -> DistantEntry? {
        let allKeys = Array(cidEntries.keys)
        guard !allKeys.isEmpty else { return nil }

        // Random sampling — take sqrt(n) samples, minimum 16, maximum 128
        let sampleSize = min(max(Int(Double(allKeys.count).squareRoot()), 16), min(allKeys.count, 128))
        let sampledKeys = allKeys.shuffled().prefix(sampleSize)

        var worst: DistantEntry?
        for key in sampledKeys {
            guard let distance = cidEntries[key] else { continue }
            if await protectionPolicy.isProtected(key) { continue }
            if let current = worst {
                if distance > current.distance {
                    worst = DistantEntry(cid: key, distance: distance)
                }
            } else {
                worst = DistantEntry(cid: key, distance: distance)
            }
        }
        return worst
    }
}
