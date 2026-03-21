import Foundation
import Acorn
import Tally

public actor VerifiedDistanceStore: AcornCASWorker {
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?
    public var timeout: Duration? { nil }

    private let inner: any AcornCASWorker
    private let nodeHash: [UInt8]
    private var storedCIDs: BoundedSet<String>
    private var cidDistances: BoundedDictionary<String, [UInt8]>
    private var pinnedCIDs: Set<String> = []
    private var chainTipCIDs: Set<String> = []
    private var chainTipsByCID: [String: String] = [:]
    private let maxEntries: Int

    public init(inner: any AcornCASWorker, nodePublicKey: String, maxEntries: Int = 100_000) {
        self.inner = inner
        self.nodeHash = Router.hash(nodePublicKey)
        self.maxEntries = maxEntries
        self.storedCIDs = BoundedSet(capacity: maxEntries)
        self.cidDistances = BoundedDictionary(capacity: maxEntries)
    }

    // MARK: - Pinning (miner's own content)

    public func pin(_ cid: String) {
        pinnedCIDs.insert(cid)
    }

    public func pinAll(_ cids: [String]) {
        for cid in cids { pinnedCIDs.insert(cid) }
    }

    public func unpin(_ cid: String) {
        pinnedCIDs.remove(cid)
    }

    public func isPinned(_ cid: String) -> Bool {
        pinnedCIDs.contains(cid)
    }

    public func storePinned(cid: ContentIdentifier, data: Data) async {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return }
        pinnedCIDs.insert(cid.rawValue)
        storedCIDs.insert(cid.rawValue)
        await inner.storeLocal(cid: cid, data: data)
    }

    // MARK: - Chain tip tracking (subscribed chains)

    public func setChainTip(chain: String, tipCID: String, referencedCIDs: [String]) {
        if let oldTip = chainTipsByCID.first(where: { $0.value == chain })?.key {
            chainTipCIDs.remove(oldTip)
            chainTipsByCID.removeValue(forKey: oldTip)
        }

        chainTipCIDs.insert(tipCID)
        chainTipsByCID[tipCID] = chain
        for cid in referencedCIDs {
            chainTipCIDs.insert(cid)
            chainTipsByCID[cid] = chain
        }
    }

    public func clearChainTip(chain: String) {
        let toRemove = chainTipsByCID.filter { $0.value == chain }.map(\.key)
        for cid in toRemove {
            chainTipCIDs.remove(cid)
            chainTipsByCID.removeValue(forKey: cid)
        }
    }

    public func isChainTip(_ cid: String) -> Bool {
        chainTipCIDs.contains(cid)
    }

    public var chainTipCount: Int { chainTipCIDs.count }

    // MARK: - Protected check

    private func isProtected(_ cid: String) -> Bool {
        pinnedCIDs.contains(cid) || chainTipCIDs.contains(cid)
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

        if isProtected(cid.rawValue) {
            storedCIDs.insert(cid.rawValue)
            await inner.storeLocal(cid: cid, data: data)
            return
        }

        let cidHash = Router.hash(cid.rawValue)
        let distance = Router.xorDistance(nodeHash, cidHash)

        if storedCIDs.count >= maxEntries {
            if let mostDistant = findMostDistant(), mostDistant.distance > distance {
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

    // MARK: - Distance queries

    public func xorDistance(to cid: String) -> [UInt8] {
        Router.xorDistance(nodeHash, Router.hash(cid))
    }

    public func isCloserThan(cid: String, threshold: [UInt8]) -> Bool {
        xorDistance(to: cid) < threshold
    }

    public var entryCount: Int { storedCIDs.count }
    public var pinnedCount: Int { pinnedCIDs.count }

    // MARK: - Eviction

    private struct DistantEntry {
        let cid: String
        let distance: [UInt8]
    }

    private func findMostDistant() -> DistantEntry? {
        var worst: DistantEntry?
        let sample = cidDistances.filter { key, _ in !isProtected(key) }
        let subset = sample.prefix(16)
        for (cid, distance) in subset {
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
