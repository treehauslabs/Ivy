import Foundation
import Acorn
import Tally

public actor CASBridge {
    private let localCAS: any AcornCASWorker
    private weak var node: Ivy?

    public init(node: Ivy, localCAS: any AcornCASWorker) {
        self.node = node
        self.localCAS = localCAS
    }

    public func resolveCIDs(_ cids: [String]) async -> [String: Data] {
        var result: [String: Data] = [:]
        var missing: [String] = []

        for cid in cids {
            if let data = await localCAS.getLocal(cid: ContentIdentifier(rawValue: cid)) {
                result[cid] = data
            } else {
                missing.append(cid)
            }
        }

        if !missing.isEmpty, let node {
            for cid in missing {
                if let data = await node.fetchBlock(cid: cid) {
                    result[cid] = data
                    await localCAS.storeLocal(cid: ContentIdentifier(rawValue: cid), data: data)
                }
            }
        }

        return result
    }

    public func hasCID(_ cid: String) async -> Bool {
        await localCAS.has(cid: ContentIdentifier(rawValue: cid))
    }

    public func filterMissing(_ cids: [String]) async -> [String] {
        var missing: [String] = []
        for cid in cids {
            let cidObj = ContentIdentifier(rawValue: cid)
            if !(await localCAS.has(cid: cidObj)) {
                missing.append(cid)
            }
        }
        return missing
    }

    public func storeVerified(cid: String, data: Data) async -> Bool {
        let computed = ContentIdentifier(for: data)
        guard computed.rawValue == cid else { return false }
        await localCAS.storeLocal(cid: computed, data: data)
        return true
    }

    public func storeAll(_ items: [(String, Data)]) async -> Int {
        var stored = 0
        for (cid, data) in items {
            if await storeVerified(cid: cid, data: data) {
                stored += 1
            }
        }
        return stored
    }

    // MARK: - Volume-Aware Resolution

    /// Resolve a volume's CIDs, batch-fetching from the volume's provider.
    /// This is the CASBridge equivalent of Ivy.fetchVolume().
    public func resolveVolume(rootCID: String, childCIDs: [String]) async -> [String: Data] {
        var result: [String: Data] = [:]
        var missing: [String] = []

        // Check local storage first
        for cid in childCIDs {
            if let data = await localCAS.getLocal(cid: ContentIdentifier(rawValue: cid)) {
                result[cid] = data
            } else {
                missing.append(cid)
            }
        }

        // Batch-fetch missing via Ivy's volume-aware fetch
        if !missing.isEmpty, let node {
            let fetched = await node.fetchVolume(rootCID: rootCID, childCIDs: missing)
            for (cid, data) in fetched {
                result[cid] = data
                await localCAS.storeLocal(cid: ContentIdentifier(rawValue: cid), data: data)
            }
        }

        return result
    }

    /// Store all items as a volume — uses volume-aware storage for co-location.
    public func storeVolume(rootCID: String, items: [(String, Data)]) async -> Int {
        var stored = 0

        if let store = localCAS as? ProfitWeightedStore {
            await store.registerVolume(rootCID: rootCID, childCIDs: items.map(\.0))
            for (cid, data) in items {
                let computed = ContentIdentifier(for: data)
                guard computed.rawValue == cid else { continue }
                await store.storeVolumeBlock(cid: computed, data: data, volumeRootCID: rootCID)
                stored += 1
            }
        } else {
            for (cid, data) in items {
                if await storeVerified(cid: cid, data: data) {
                    stored += 1
                }
            }
        }

        return stored
    }
}
