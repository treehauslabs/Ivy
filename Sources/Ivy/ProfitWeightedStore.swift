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

public actor ProfitWeightedStore: AcornCASWorker {
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?
    public var timeout: Duration? { nil }

    private let inner: any AcornCASWorker
    private let nodeHash: [UInt8]
    private let maxEntries: Int
    public var protectionPolicy: any EvictionProtectionPolicy

    // Profit tracking: CID → access metadata
    private var cidProfit: BoundedDictionary<String, CIDMetrics>

    struct CIDMetrics: Sendable {
        var accessCount: UInt32 = 0
        var lastAccess: ContinuousClock.Instant
        var isProtected: Bool = false
    }

    // Volume tracking: child CID → root CID, root CID → child CIDs
    private var volumeMembership: [String: String] = [:]
    private var volumeChildren: [String: Set<String>] = [:]

    public init(inner: any AcornCASWorker, nodePublicKey: String, maxEntries: Int = 100_000, protectionPolicy: any EvictionProtectionPolicy = NoProtection()) {
        self.inner = inner
        self.nodeHash = Router.hash(nodePublicKey)
        self.maxEntries = maxEntries
        self.cidProfit = BoundedDictionary(capacity: maxEntries)
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
        recordAccess(cid.rawValue)
        return data
    }

    public func storeLocal(cid: ContentIdentifier, data: Data) async {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return }

        if await protectionPolicy.isProtected(cid.rawValue) {
            cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now, isProtected: true)
            await inner.storeLocal(cid: cid, data: data)
            return
        }

        if cidProfit.count >= maxEntries {
            if let evicted = await findLeastProfitable() {
                cidProfit.removeValue(forKey: evicted)
                dropFromVolumeTracking(evicted)
            } else {
                return // everything is protected, can't evict
            }
        }

        cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now)
        await inner.storeLocal(cid: cid, data: data)
    }

    /// Batched store: single capacity check, single eviction pass, single
    /// delegation to the inner worker's batch path. At steady-state capacity
    /// this replaces O(batch * N) sampling work with O(batch + N).
    public func storeLocalBatch(_ entries: [(ContentIdentifier, Data)]) async {
        guard !entries.isEmpty else { return }

        var toWrite: [(ContentIdentifier, Data)] = []
        toWrite.reserveCapacity(entries.count)

        // Classify each entry as protected or evictable; make evictable entries
        // fit by calling findLeastProfitable once per slot needed.
        for (cid, data) in entries {
            let computed = ContentIdentifier(for: data)
            guard computed.rawValue == cid.rawValue else { continue }

            if await protectionPolicy.isProtected(cid.rawValue) {
                cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now, isProtected: true)
                toWrite.append((cid, data))
                continue
            }

            if cidProfit[cid.rawValue] != nil {
                // Already tracked — just refresh metrics, no eviction needed.
                cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now)
                toWrite.append((cid, data))
                continue
            }

            if cidProfit.count >= maxEntries {
                if let evicted = await findLeastProfitable() {
                    cidProfit.removeValue(forKey: evicted)
                    dropFromVolumeTracking(evicted)
                } else {
                    continue  // everything protected
                }
            }

            cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now)
            toWrite.append((cid, data))
        }

        if !toWrite.isEmpty {
            await inner.storeLocalBatch(toWrite)
        }
    }

    public func storeVerified(cid: ContentIdentifier, data: Data) async {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return }
        cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now)
        await inner.storeLocal(cid: cid, data: data)
    }

    // MARK: - Volume-Aware Storage

    public func storeVolumeBlock(cid: ContentIdentifier, data: Data, volumeRootCID: String) async {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid.rawValue else { return }

        volumeMembership[cid.rawValue] = volumeRootCID
        volumeChildren[volumeRootCID, default: []].insert(cid.rawValue)

        let cidProtected = await protectionPolicy.isProtected(cid.rawValue)
        let rootProtected = await protectionPolicy.isProtected(volumeRootCID)
        if cidProtected || rootProtected {
            cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now, isProtected: true)
            await inner.storeLocal(cid: cid, data: data)
            return
        }

        if cidProfit.count >= maxEntries {
            if let evicted = await evictLeastProfitableVolume() {
                for evictedCID in evicted {
                    cidProfit.removeValue(forKey: evictedCID)
                    if let root = volumeMembership.removeValue(forKey: evictedCID) {
                        volumeChildren[root]?.remove(evictedCID)
                        if volumeChildren[root]?.isEmpty == true { volumeChildren.removeValue(forKey: root) }
                    }
                }
            }
        }

        cidProfit[cid.rawValue] = CIDMetrics(lastAccess: .now)
        await inner.storeLocal(cid: cid, data: data)
    }

    public func registerVolume(rootCID: String, childCIDs: [String]) {
        for child in childCIDs {
            volumeMembership[child] = rootCID
            volumeChildren[rootCID, default: []].insert(child)
        }
        volumeChildren[rootCID, default: []].insert(rootCID)
        volumeMembership[rootCID] = rootCID

        // Membership tracking is pure bookkeeping on top of cidProfit. If the
        // caller registered CIDs that cidProfit already evicted (or never saw),
        // drop them here so the volume dicts stay in sync and don't grow
        // unbounded as the chain mines blocks forever.
        compactVolumeTracking()
    }

    /// Drop a CID from both volume dicts. If a root loses its last member,
    /// drop the root entry too so volumeChildren doesn't accumulate empty sets.
    private func dropFromVolumeTracking(_ cid: String) {
        if let root = volumeMembership.removeValue(forKey: cid) {
            if var children = volumeChildren[root] {
                children.remove(cid)
                if children.isEmpty {
                    volumeChildren.removeValue(forKey: root)
                } else {
                    volumeChildren[root] = children
                }
            }
        }
        // If the cid was itself a root (may or may not have children), clear
        // its child set too — any orphan child entries will be removed when
        // cidProfit evicts them.
        if volumeChildren[cid] != nil {
            volumeChildren.removeValue(forKey: cid)
        }
    }

    /// Remove volume entries whose CID is no longer tracked by cidProfit.
    /// Called after registerVolume so membership never exceeds the bounded
    /// profit dict. O(volumeMembership.count) but amortized cheap in practice
    /// because volumeMembership is bounded by cidProfit's capacity.
    private func compactVolumeTracking() {
        guard !volumeMembership.isEmpty else { return }
        let stale = volumeMembership.keys.filter { cidProfit[$0] == nil }
        for cid in stale {
            dropFromVolumeTracking(cid)
        }
    }

    public func volumeRoot(for cid: String) -> String? {
        volumeMembership[cid]
    }

    public func volumeMembers(rootCID: String) -> Set<String> {
        volumeChildren[rootCID] ?? []
    }

    // MARK: - Profit Tracking

    /// Record that a CID was accessed (served to a peer). Higher access count = more profitable to keep.
    private func recordAccess(_ cid: String) {
        if var metrics = cidProfit[cid] {
            metrics.accessCount += 1
            metrics.lastAccess = .now
            cidProfit[cid] = metrics
        }
    }

    /// Externally record that serving a CID earned revenue (called by Ivy after fee-earning serves).
    public func recordServe(_ cid: String) {
        recordAccess(cid)
    }

    // MARK: - Eviction

    /// Profit score: accessCount weighted by recency.
    /// Protected items return UInt64.max (never evicted).
    private func profitScore(_ metrics: CIDMetrics) -> UInt64 {
        if metrics.isProtected { return .max }
        // Age in seconds since last access (capped at 1 day)
        let age = max(metrics.lastAccess.duration(to: .now).components.seconds, 1)
        let cappedAge = min(age, 86400)
        // Score: accesses * 1000 / age_seconds — frequently accessed + recently accessed = high score
        // +1 to accessCount so brand-new entries start with score > 0
        return UInt64(metrics.accessCount + 1) * 1000 / UInt64(cappedAge)
    }

    /// Sampling budget: bounded regardless of cache size so per-store cost is O(1).
    private static let evictionSampleSize = 32

    /// Find the least profitable non-protected CID via random sampling.
    private func findLeastProfitable() async -> String? {
        guard cidProfit.count > 0 else { return nil }
        let sampledKeys = cidProfit.randomSampleKeys(count: Self.evictionSampleSize)

        var worstKey: String?
        var worstScore: UInt64 = .max

        for key in sampledKeys {
            guard let metrics = cidProfit[key] else { continue }
            if metrics.isProtected { continue }
            if await protectionPolicy.isProtected(key) { continue }
            let score = profitScore(metrics)
            if score < worstScore {
                worstScore = score
                worstKey = key
            }
        }
        return worstKey
    }

    /// Find and evict the least profitable volume (all members) or standalone CID.
    private func evictLeastProfitableVolume() async -> Set<String>? {
        guard cidProfit.count > 0 else { return nil }
        let sampledKeys = cidProfit.randomSampleKeys(count: Self.evictionSampleSize)

        var worstRoot: String?
        var worstScore: UInt64 = .max

        for key in sampledKeys {
            guard let metrics = cidProfit[key] else { continue }
            let root = volumeMembership[key] ?? key
            if metrics.isProtected { continue }
            if await protectionPolicy.isProtected(root) { continue }
            if await protectionPolicy.isProtected(key) { continue }
            let score = profitScore(metrics)
            if score < worstScore {
                worstScore = score
                worstRoot = root
            }
        }

        guard let root = worstRoot else { return nil }
        if let children = volumeChildren[root] {
            return children
        }
        return [root]
    }

    // MARK: - Queries

    public var entryCount: Int { cidProfit.count }

    /// Returns stored CIDs closest to `targetHash` (for zone sync compatibility).
    /// Computes XOR on-the-fly — storage itself is not distance-ordered.
    public func storedCIDsClosestTo(hash targetHash: [UInt8], limit: Int) -> [String] {
        let allCIDs = Array(cidProfit.keys)
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
        let allCIDs = Array(cidProfit.keys)
        guard !allCIDs.isEmpty else { return [] }
        if allCIDs.count <= count { return allCIDs }
        return Array(allCIDs.shuffled().prefix(count))
    }
}
