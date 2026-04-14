import Testing
import Foundation
@testable import Ivy
import Acorn
import Tally

private actor MemStore: AcornCASWorker {
    var near: (any AcornCASWorker)?
    var far: (any AcornCASWorker)?
    var timeout: Duration? { nil }
    var storage: [String: Data] = [:]

    func has(cid: ContentIdentifier) async -> Bool { storage[cid.rawValue] != nil }
    func getLocal(cid: ContentIdentifier) async -> Data? { storage[cid.rawValue] }
    func storeLocal(cid: ContentIdentifier, data: Data) async { storage[cid.rawValue] = data }
}

private struct TestProtection: EvictionProtectionPolicy, Sendable {
    let protectedCIDs: Set<String>
    func isProtected(_ cid: String) async -> Bool { protectedCIDs.contains(cid) }
}

@Suite("ProfitWeightedStore")
struct ProfitWeightedStoreTests {

    @Test("Rejects data whose hash does not match CID")
    func testRejectsTamperedData() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("hello".utf8)
        let fakeCID = ContentIdentifier(rawValue: "not-the-real-hash")

        await store.storeLocal(cid: fakeCID, data: data)

        let retrieved = await mem.has(cid: fakeCID)
        #expect(!retrieved)
    }

    @Test("Accepts data whose hash matches CID")
    func testAcceptsVerifiedData() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("hello world".utf8)
        let cid = ContentIdentifier(for: data)

        await store.storeLocal(cid: cid, data: data)

        let retrieved = await mem.getLocal(cid: cid)
        #expect(retrieved == data)
    }

    @Test("getLocal rejects corrupted data in underlying store")
    func testGetLocalRejectsCorrupted() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("original".utf8)
        let cid = ContentIdentifier(for: data)

        await mem.storeLocal(cid: cid, data: Data("tampered".utf8))

        let retrieved = await store.getLocal(cid: cid)
        #expect(retrieved == nil)
    }

    @Test("getLocal returns valid data and records access")
    func testGetLocalReturnsValid() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("verified content".utf8)
        let cid = ContentIdentifier(for: data)
        await store.storeLocal(cid: cid, data: data)

        let retrieved = await store.getLocal(cid: cid)
        #expect(retrieved == data)
    }

    @Test("Entry count tracks stored items")
    func testEntryCount() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "counter-node")

        for i in 0..<5 {
            let data = Data("content-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let count = await store.entryCount
        #expect(count == 5)
    }

    @Test("Rejected data does not increment entry count")
    func testRejectedDoesNotCount() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "reject-node")

        let data = Data("real".utf8)
        let fakeCID = ContentIdentifier(rawValue: "fake")
        await store.storeLocal(cid: fakeCID, data: data)

        let count = await store.entryCount
        #expect(count == 0)
    }

    @Test("Multiple stores accumulate")
    func testMultipleStores() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "multi-node", maxEntries: 1000)

        var cids: [ContentIdentifier] = []
        for i in 0..<20 {
            let data = Data("block-\(i)-data".utf8)
            let cid = ContentIdentifier(for: data)
            cids.append(cid)
            await store.storeLocal(cid: cid, data: data)
        }

        for cid in cids {
            let has = await store.has(cid: cid)
            #expect(has)
        }
    }

    @Test("Protection policy prevents eviction")
    func testProtectionPolicyPreventsEviction() async {
        let mem = MemStore()
        let protectedData = Data("protected-block".utf8)
        let protectedCID = ContentIdentifier(for: protectedData)
        let policy = TestProtection(protectedCIDs: [protectedCID.rawValue])
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "policy-node", maxEntries: 5, protectionPolicy: policy)

        await store.storeLocal(cid: protectedCID, data: protectedData)

        for i in 0..<20 {
            let data = Data("filler-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let stillThere = await mem.getLocal(cid: protectedCID)
        #expect(stillThere == protectedData)
    }

    @Test("storeVerified bypasses eviction pressure")
    func testStoreVerifiedBypassesEviction() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "verified-node", maxEntries: 2)

        for i in 0..<2 {
            let data = Data("fill-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let extraData = Data("verified-bypass".utf8)
        let extraCID = ContentIdentifier(for: extraData)
        await store.storeVerified(cid: extraCID, data: extraData)

        let has = await mem.getLocal(cid: extraCID)
        #expect(has == extraData)
    }

    @Test("storeVerified rejects tampered data")
    func testStoreVerifiedRejectsTampered() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "verified-reject")

        await store.storeVerified(cid: ContentIdentifier(rawValue: "fake"), data: Data("real".utf8))
        let has = await mem.has(cid: ContentIdentifier(rawValue: "fake"))
        #expect(!has)
    }

    @Test("NoProtection allows everything")
    func testNoProtection() async {
        let policy = NoProtection()
        let result = await policy.isProtected("anything")
        #expect(!result)
    }

    @Test("storedCIDsClosestTo returns CIDs sorted by distance")
    func testStoredCIDsClosestTo() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "zone-node", maxEntries: 1000)

        for i in 0..<20 {
            let data = Data("zone-block-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let targetHash = Router.hash("some-other-node")
        let closest = await store.storedCIDsClosestTo(hash: targetHash, limit: 5)

        #expect(closest.count == 5)

        var prevDistance: [UInt8]? = nil
        for cid in closest {
            let cidHash = Router.hash(cid)
            let dist = Router.xorDistance(targetHash, cidHash)
            if let prev = prevDistance {
                #expect(prev <= dist)
            }
            prevDistance = dist
        }
    }

    @Test("storedCIDsClosestTo returns empty for empty store")
    func testStoredCIDsClosestToEmpty() async {
        let store = ProfitWeightedStore(inner: MemStore(), nodePublicKey: "empty-node")
        let result = await store.storedCIDsClosestTo(hash: Router.hash("target"), limit: 10)
        #expect(result.isEmpty)
    }

    @Test("storedCIDsClosestTo respects limit")
    func testStoredCIDsClosestToLimit() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "limit-node", maxEntries: 1000)

        for i in 0..<10 {
            let data = Data("limit-block-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let result = await store.storedCIDsClosestTo(hash: Router.hash("target"), limit: 3)
        #expect(result.count == 3)
    }

    @Test("sampleStoredCIDs returns requested count")
    func testSampleStoredCIDs() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "sample-node", maxEntries: 1000)

        for i in 0..<20 {
            let data = Data("sample-block-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let sample = await store.sampleStoredCIDs(count: 5)
        #expect(sample.count == 5)
        #expect(Set(sample).count == 5)
    }

    @Test("sampleStoredCIDs returns all when count exceeds stored")
    func testSampleStoredCIDsExceedsStored() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "small-node", maxEntries: 1000)

        for i in 0..<3 {
            let data = Data("small-block-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let sample = await store.sampleStoredCIDs(count: 10)
        #expect(sample.count == 3)
    }

    @Test("sampleStoredCIDs returns empty for empty store")
    func testSampleStoredCIDsEmpty() async {
        let store = ProfitWeightedStore(inner: MemStore(), nodePublicKey: "empty-sample")
        let sample = await store.sampleStoredCIDs(count: 5)
        #expect(sample.isEmpty)
    }

    @Test("entryCount matches stored items")
    func testEntryCountMatchesStored() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "tracked-node", maxEntries: 1000)

        for i in 0..<7 {
            let data = Data("tracked-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let count = await store.entryCount
        #expect(count == 7)
    }

    @Test("Frequently accessed CIDs survive eviction over cold CIDs")
    func testProfitEviction() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "profit-node", maxEntries: 5)

        // Store 5 CIDs to fill the store
        var hotData = Data("hot-content".utf8)
        let hotCID = ContentIdentifier(for: hotData)
        await store.storeLocal(cid: hotCID, data: hotData)

        // Access the hot CID many times to boost its profit score
        for _ in 0..<20 {
            _ = await store.getLocal(cid: hotCID)
        }

        // Fill remaining slots
        for i in 0..<4 {
            let data = Data("cold-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        // Store more to trigger eviction — cold CIDs should be evicted, not the hot one
        for i in 0..<10 {
            let data = Data("new-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        // The hot CID should still be there
        let stillThere = await mem.getLocal(cid: hotCID)
        #expect(stillThere == hotData, "Frequently accessed CID should survive eviction")
    }

    @Test("recordServe boosts profit score")
    func testRecordServe() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "serve-node", maxEntries: 3)

        let servedData = Data("served-content".utf8)
        let servedCID = ContentIdentifier(for: servedData)
        await store.storeLocal(cid: servedCID, data: servedData)

        // Simulate serving this CID to peers
        for _ in 0..<10 {
            await store.recordServe(servedCID.rawValue)
        }

        // Fill and overflow
        for i in 0..<2 {
            let data = Data("filler-\(i)".utf8)
            await store.storeLocal(cid: ContentIdentifier(for: data), data: data)
        }
        for i in 0..<5 {
            let data = Data("overflow-\(i)".utf8)
            await store.storeLocal(cid: ContentIdentifier(for: data), data: data)
        }

        let stillThere = await mem.getLocal(cid: servedCID)
        #expect(stillThere == servedData, "Served CID should survive eviction")
    }
}
