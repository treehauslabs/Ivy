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

@Suite("VerifiedDistanceStore")
struct VerifiedDistanceStoreTests {

    @Test("Rejects data whose hash does not match CID")
    func testRejectsTamperedData() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("hello".utf8)
        let fakeCID = ContentIdentifier(rawValue: "not-the-real-hash")

        await store.storeLocal(cid: fakeCID, data: data)

        let retrieved = await mem.has(cid: fakeCID)
        #expect(!retrieved)
    }

    @Test("Accepts data whose hash matches CID")
    func testAcceptsVerifiedData() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("hello world".utf8)
        let cid = ContentIdentifier(for: data)

        await store.storeLocal(cid: cid, data: data)

        let retrieved = await mem.getLocal(cid: cid)
        #expect(retrieved == data)
    }

    @Test("getLocal rejects corrupted data in underlying store")
    func testGetLocalRejectsCorrupted() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("original".utf8)
        let cid = ContentIdentifier(for: data)

        await mem.storeLocal(cid: cid, data: Data("tampered".utf8))

        let retrieved = await store.getLocal(cid: cid)
        #expect(retrieved == nil)
    }

    @Test("getLocal returns valid data")
    func testGetLocalReturnsValid() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "node-key")

        let data = Data("verified content".utf8)
        let cid = ContentIdentifier(for: data)
        await store.storeLocal(cid: cid, data: data)

        let retrieved = await store.getLocal(cid: cid)
        #expect(retrieved == data)
    }

    @Test("XOR distance is computed correctly")
    func testXorDistance() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "node-A")

        let d1 = await store.xorDistance(to: "cid-1")
        let d2 = await store.xorDistance(to: "cid-2")

        #expect(d1.count == 32)
        #expect(d2.count == 32)
        #expect(d1 != d2)
    }

    @Test("Closer content is identified correctly")
    func testIsCloserThan() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "node-B")

        let maxDistance = [UInt8](repeating: 0xFF, count: 32)
        let close = await store.isCloserThan(cid: "any-cid", threshold: maxDistance)
        #expect(close)

        let zeroDistance = [UInt8](repeating: 0x00, count: 32)
        let far = await store.isCloserThan(cid: "any-cid", threshold: zeroDistance)
        #expect(!far)
    }

    @Test("Entry count tracks stored items")
    func testEntryCount() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "counter-node")

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
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "reject-node")

        let data = Data("real".utf8)
        let fakeCID = ContentIdentifier(rawValue: "fake")
        await store.storeLocal(cid: fakeCID, data: data)

        let count = await store.entryCount
        #expect(count == 0)
    }

    @Test("Multiple verified stores accumulate")
    func testMultipleStores() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "multi-node", maxEntries: 1000)

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

    @Test("Pinned content is never evicted")
    func testPinnedNeverEvicted() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "pin-node", maxEntries: 5)

        let pinnedData = Data("my-mined-block".utf8)
        let pinnedCID = ContentIdentifier(for: pinnedData)
        await store.storePinned(cid: pinnedCID, data: pinnedData)

        for i in 0..<20 {
            let data = Data("foreign-block-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let stillHas = await mem.getLocal(cid: pinnedCID)
        #expect(stillHas == pinnedData)
        #expect(await store.isPinned(pinnedCID.rawValue))
    }

    @Test("storePinned verifies data")
    func testStorePinnedVerifies() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "pin-verify")

        let data = Data("legit".utf8)
        let fakeCID = ContentIdentifier(rawValue: "wrong-hash")
        await store.storePinned(cid: fakeCID, data: data)

        let has = await mem.has(cid: fakeCID)
        #expect(!has)
        #expect(await store.pinnedCount == 0)
    }

    @Test("storePinned bypasses distance check")
    func testStorePinnedBypassesDistance() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "pin-bypass", maxEntries: 2)

        for i in 0..<2 {
            let data = Data("fill-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let farData = Data("far-away-pinned-content".utf8)
        let farCID = ContentIdentifier(for: farData)
        await store.storePinned(cid: farCID, data: farData)

        let has = await mem.getLocal(cid: farCID)
        #expect(has == farData)
    }

    @Test("Pinned count tracks pins")
    func testPinnedCount() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "count-pins")

        for i in 0..<3 {
            let data = Data("pin-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storePinned(cid: cid, data: data)
        }

        #expect(await store.pinnedCount == 3)
    }

    @Test("Unpin allows future eviction")
    func testUnpin() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "unpin-node")

        let data = Data("pinnable".utf8)
        let cid = ContentIdentifier(for: data)
        await store.storePinned(cid: cid, data: data)
        #expect(await store.isPinned(cid.rawValue))

        await store.unpin(cid.rawValue)
        #expect(!(await store.isPinned(cid.rawValue)))
    }

    @Test("Chain tip content is protected from eviction")
    func testChainTipProtected() async {
        let mem = MemStore()
        let store = VerifiedDistanceStore(inner: mem, nodePublicKey: "tip-node", maxEntries: 5)

        let tipData = Data("nexus-tip-block".utf8)
        let tipCID = ContentIdentifier(for: tipData)
        let refData = Data("tip-transaction".utf8)
        let refCID = ContentIdentifier(for: refData)

        await store.setChainTip(chain: "Nexus", tipCID: tipCID.rawValue, referencedCIDs: [refCID.rawValue])
        await store.storeLocal(cid: tipCID, data: tipData)
        await store.storeLocal(cid: refCID, data: refData)

        for i in 0..<20 {
            let data = Data("filler-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        let tipStillThere = await mem.getLocal(cid: tipCID)
        let refStillThere = await mem.getLocal(cid: refCID)
        #expect(tipStillThere == tipData)
        #expect(refStillThere == refData)
    }

    @Test("setChainTip replaces old tip for same chain")
    func testChainTipReplacement() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "replace-tip")

        let old = ContentIdentifier(for: Data("old-tip".utf8))
        let new = ContentIdentifier(for: Data("new-tip".utf8))

        await store.setChainTip(chain: "Nexus", tipCID: old.rawValue, referencedCIDs: [])
        #expect(await store.isChainTip(old.rawValue))

        await store.setChainTip(chain: "Nexus", tipCID: new.rawValue, referencedCIDs: [])
        #expect(await store.isChainTip(new.rawValue))
        #expect(!(await store.isChainTip(old.rawValue)))
    }

    @Test("clearChainTip removes protection")
    func testClearChainTip() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "clear-tip")

        let tip = ContentIdentifier(for: Data("tip".utf8))
        await store.setChainTip(chain: "Nexus", tipCID: tip.rawValue, referencedCIDs: [])
        #expect(await store.isChainTip(tip.rawValue))

        await store.clearChainTip(chain: "Nexus")
        #expect(!(await store.isChainTip(tip.rawValue)))
    }

    @Test("Multiple chain tips coexist")
    func testMultipleChainTips() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "multi-tip")

        let nexusTip = ContentIdentifier(for: Data("nexus".utf8))
        let payTip = ContentIdentifier(for: Data("payments".utf8))

        await store.setChainTip(chain: "Nexus", tipCID: nexusTip.rawValue, referencedCIDs: [])
        await store.setChainTip(chain: "Nexus/Payments", tipCID: payTip.rawValue, referencedCIDs: [])

        #expect(await store.isChainTip(nexusTip.rawValue))
        #expect(await store.isChainTip(payTip.rawValue))
        #expect(await store.chainTipCount >= 2)
    }

    @Test("Chain tip count tracks referenced CIDs")
    func testChainTipCountIncludesRefs() async {
        let store = VerifiedDistanceStore(inner: MemStore(), nodePublicKey: "ref-count")

        let tip = ContentIdentifier(for: Data("tip".utf8))
        let ref1 = ContentIdentifier(for: Data("ref1".utf8))
        let ref2 = ContentIdentifier(for: Data("ref2".utf8))

        await store.setChainTip(chain: "Nexus", tipCID: tip.rawValue, referencedCIDs: [ref1.rawValue, ref2.rawValue])
        #expect(await store.chainTipCount == 3)
    }
}
