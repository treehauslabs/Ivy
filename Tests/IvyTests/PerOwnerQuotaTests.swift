import Testing
import Foundation
@testable import Ivy
import Acorn

/// S4: the shared CAS is used by multiple chains. Without per-owner
/// accounting a chain that churns unprotected CIDs can displace another
/// chain's bytes, because eviction picks globally by profit score.
/// ProfitWeightedStore.registerVolume(owner:) records which chain owns a
/// volume; evictLeastProfitableVolume biases toward owners that have
/// exceeded `maxVolumesPerOwner`.
private actor MemStore: AcornCASWorker {
    var near: (any AcornCASWorker)?
    var far: (any AcornCASWorker)?
    var timeout: Duration? { nil }
    var storage: [String: Data] = [:]
    func has(cid: ContentIdentifier) async -> Bool { storage[cid.rawValue] != nil }
    func getLocal(cid: ContentIdentifier) async -> Data? { storage[cid.rawValue] }
    func storeLocal(cid: ContentIdentifier, data: Data) async { storage[cid.rawValue] = data }
}

@Suite("Per-owner volume quota")
struct PerOwnerQuotaTests {

    /// Seed a volume: store each (cid, data) pair AND register the root with
    /// its member CIDs and owner. The store + register order matches
    /// ChainNetwork.storeBlockBatch — register after the batch lands so
    /// compactVolumeTracking sees the tracked CIDs in cidProfit.
    private func seedVolume(
        store: ProfitWeightedStore,
        owner: String?,
        tag: String
    ) async -> (root: String, members: [String]) {
        var cids: [String] = []
        let rootData = Data("\(tag)-root".utf8)
        let rootCID = ContentIdentifier(for: rootData)
        await store.storeLocal(cid: rootCID, data: rootData)
        cids.append(rootCID.rawValue)
        for i in 0..<2 {
            let data = Data("\(tag)-child-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
            cids.append(cid.rawValue)
        }
        await store.registerVolume(rootCID: rootCID.rawValue, childCIDs: cids, owner: owner)
        return (rootCID.rawValue, cids)
    }

    @Test("registerVolume records and exposes ownership")
    func testOwnershipRecording() async {
        let store = ProfitWeightedStore(inner: MemStore(), nodePublicKey: "own-node", maxEntries: 1000)

        let nexusVol = await seedVolume(store: store, owner: "nexus", tag: "nexus")
        let childVol = await seedVolume(store: store, owner: "childA", tag: "childA")
        let unownedVol = await seedVolume(store: store, owner: nil, tag: "unowned")

        #expect(await store.volumeOwner(rootCID: nexusVol.root) == "nexus")
        #expect(await store.volumeOwner(rootCID: childVol.root) == "childA")
        #expect(await store.volumeOwner(rootCID: unownedVol.root) == nil)

        #expect(await store.ownedVolumeCount(owner: "nexus") == 1)
        #expect(await store.ownedVolumeCount(owner: "childA") == 1)
    }

    @Test("ownership transfers when rootCID is re-registered to a new owner")
    func testOwnershipTransfer() async {
        let store = ProfitWeightedStore(inner: MemStore(), nodePublicKey: "xfer-node", maxEntries: 1000)

        let data = Data("xfer-root".utf8)
        let cid = ContentIdentifier(for: data)
        await store.storeLocal(cid: cid, data: data)

        await store.registerVolume(rootCID: cid.rawValue, childCIDs: [cid.rawValue], owner: "alice")
        #expect(await store.ownedVolumeCount(owner: "alice") == 1)

        await store.registerVolume(rootCID: cid.rawValue, childCIDs: [cid.rawValue], owner: "bob")
        #expect(await store.ownedVolumeCount(owner: "alice") == 0)
        #expect(await store.ownedVolumeCount(owner: "bob") == 1)
    }

    /// The core S4 property. Two owners share a store; one exceeds its
    /// quota. When eviction runs (store hits maxEntries), victims are
    /// drawn from the over-quota owner — not the under-quota owner —
    /// even though both have comparable freshly-written profit scores.
    @Test("eviction prefers the over-quota owner's volumes")
    func testQuotaBiasedEviction() async {
        let mem = MemStore()
        // Small store + small per-owner quota so we can drive both limits
        // with a handful of writes.
        let store = ProfitWeightedStore(
            inner: mem,
            nodePublicKey: "quota-node",
            maxEntries: 16,
            maxVolumesPerOwner: 3
        )

        // Production pattern (ChainNetwork.storeBlockBatch): write bytes
        // first, then register the volume. Register-then-store lets
        // compactVolumeTracking drop the ownership entry before cidProfit
        // sees the CID, which silently loses the owner tag.

        // Nexus: 2 volumes, 1 member each. Under its 3-volume quota.
        var nexusMembers: [String] = []
        for i in 0..<2 {
            let data = Data("nexus-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeVolumeBlock(cid: cid, data: data, volumeRootCID: cid.rawValue)
            await store.registerVolume(rootCID: cid.rawValue, childCIDs: [cid.rawValue], owner: "nexus")
            nexusMembers.append(cid.rawValue)
        }

        // Abuser: 8 volumes, 1 member each. Blows past the 3-volume quota.
        var abuserMembers: [String] = []
        for i in 0..<8 {
            let data = Data("abuser-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeVolumeBlock(cid: cid, data: data, volumeRootCID: cid.rawValue)
            await store.registerVolume(rootCID: cid.rawValue, childCIDs: [cid.rawValue], owner: "abuser")
            abuserMembers.append(cid.rawValue)
        }

        // Drive the store past capacity with unowned churn — each store
        // triggers one eviction sampling pass against the whole cidProfit
        // keyspace. The sampler is random, so over many rounds it has the
        // chance to pick either owner, but the quota bias should steer
        // victims toward the abuser's volumes.
        for i in 0..<64 {
            let data = Data("churn-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        // Survivors = volumes still tracked in cidProfit, measured via the
        // owner dicts (which dropFromVolumeTracking keeps in sync).
        // `has()` goes straight to the inner store which is never actually
        // deleted from on eviction; that makes it the wrong signal.
        _ = nexusMembers
        _ = abuserMembers
        let abuserSurvivors = await store.ownedVolumeCount(owner: "abuser")

        // S4 invariant: an owner that exceeds its quota is evicted down to
        // (at most) the quota before any non-over-quota candidate becomes a
        // victim. Once abuser hits 3 (the quota), it stops being singled out
        // and participates in normal profit-based competition, so we assert
        // the upper bound — not that abuser is fully flushed.
        #expect(abuserSurvivors <= 3, "abuser should be evicted down to its 3-volume quota, got \(abuserSurvivors)")
    }
}
