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
    private var storedCIDs: BoundedSet<String>
    private var cidDistances: BoundedDictionary<String, [UInt8]>
    private let maxEntries: Int
    public var protectionPolicy: any EvictionProtectionPolicy

    public init(inner: any AcornCASWorker, nodePublicKey: String, maxEntries: Int = 100_000, protectionPolicy: any EvictionProtectionPolicy = NoProtection()) {
        self.inner = inner
        self.nodeHash = Router.hash(nodePublicKey)
        self.maxEntries = maxEntries
        self.storedCIDs = BoundedSet(capacity: maxEntries)
        self.cidDistances = BoundedDictionary(capacity: maxEntries)
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
            storedCIDs.insert(cid.rawValue)
            await inner.storeLocal(cid: cid, data: data)
            return
        }

        let cidHash = Router.hash(cid.rawValue)
        let distance = Router.xorDistance(nodeHash, cidHash)

        if storedCIDs.count >= maxEntries {
            if let mostDistant = await findMostDistant(), mostDistant.distance > distance {
                storedCIDs.insert(cid.rawValue)
                cidDistances[cid.rawValue] = distance
                await inner.storeLocal(cid: cid, data: data)
            }
        } else {
            storedCIDs.insert(cid.rawValue)
            cidDistances[cid.rawValue] = distance
            await inner.storeLocal(cid: cid, data: data)
        }
    }

    public func storeVerified(cid: ContentIdentifier, data: Data) async {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return }
        storedCIDs.insert(cid.rawValue)
        await inner.storeLocal(cid: cid, data: data)
    }

    // MARK: - Distance queries

    public func xorDistance(to cid: String) -> [UInt8] {
        Router.xorDistance(nodeHash, Router.hash(cid))
    }

    public func isCloserThan(cid: String, threshold: [UInt8]) -> Bool {
        xorDistance(to: cid) < threshold
    }

    public var entryCount: Int { storedCIDs.count }

    // MARK: - Eviction

    private struct DistantEntry {
        let cid: String
        let distance: [UInt8]
    }

    private func findMostDistant() async -> DistantEntry? {
        var worst: DistantEntry?
        let sample = cidDistances.filter { _, _ in true }
        let subset = sample.prefix(16)
        for (cid, distance) in subset {
            if await protectionPolicy.isProtected(cid) { continue }
            if let current = worst {
                if distance > current.distance {
                    worst = DistantEntry(cid: cid, distance: distance)
                }
            } else {
                worst = DistantEntry(cid: cid, distance: distance)
            }
        }
        return worst
    }
}
