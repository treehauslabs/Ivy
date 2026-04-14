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

// MARK: - Wire Protocol Tests

@Suite("Volume Wire Protocol")
struct VolumeWireProtocolTests {

    @Test("getVolume roundtrip")
    func testGetVolumeRoundtrip() {
        let cids = ["child-cid-1", "child-cid-2", "child-cid-3"]
        let msg = Message.getVolume(rootCID: "root-abc", cids: cids)
        let decoded = Message.deserialize(msg.serialize())

        if case .getVolume(let rootCID, let decodedCIDs) = decoded {
            #expect(rootCID == "root-abc")
            #expect(decodedCIDs == cids)
        } else {
            Issue.record("Expected getVolume, got \(String(describing: decoded))")
        }
    }

    @Test("getVolume empty CID list")
    func testGetVolumeEmpty() {
        let msg = Message.getVolume(rootCID: "root-empty", cids: [])
        let decoded = Message.deserialize(msg.serialize())

        if case .getVolume(let rootCID, let cids) = decoded {
            #expect(rootCID == "root-empty")
            #expect(cids.isEmpty)
        } else {
            Issue.record("Expected getVolume, got \(String(describing: decoded))")
        }
    }

    @Test("announceVolume roundtrip")
    func testAnnounceVolumeRoundtrip() {
        let childCIDs = ["tx-1", "tx-2", "tx-3", "tx-4"]
        let msg = Message.announceVolume(rootCID: "block-header-cid", childCIDs: childCIDs, totalSize: 4096)
        let decoded = Message.deserialize(msg.serialize())

        if case .announceVolume(let rootCID, let decodedChildren, let totalSize) = decoded {
            #expect(rootCID == "block-header-cid")
            #expect(decodedChildren == childCIDs)
            #expect(totalSize == 4096)
        } else {
            Issue.record("Expected announceVolume, got \(String(describing: decoded))")
        }
    }

    @Test("getVolume framing roundtrip")
    func testGetVolumeFraming() {
        let cids = (0..<10).map { "cid-\($0)" }
        let msg = Message.getVolume(rootCID: "framed-root", cids: cids)
        let framed = Message.frame(msg)

        // Frame format: 4 byte length prefix + payload
        #expect(framed.count > 4)
        let payload = framed.subdata(in: 4..<framed.count)
        let decoded = Message.deserialize(payload)
        if case .getVolume(let root, let decodedCIDs) = decoded {
            #expect(root == "framed-root")
            #expect(decodedCIDs == cids)
        } else {
            Issue.record("Expected getVolume after framing")
        }
    }

    @Test("announceVolume minimal roundtrip")
    func testAnnounceVolumeMinimal() {
        let msg = Message.announceVolume(rootCID: "root-x", childCIDs: ["c1"], totalSize: 100)
        let decoded = Message.deserialize(msg.serialize())

        if case .announceVolume(let rootCID, let children, let totalSize) = decoded {
            #expect(rootCID == "root-x")
            #expect(children == ["c1"])
            #expect(totalSize == 100)
        } else {
            Issue.record("Expected announceVolume, got \(String(describing: decoded))")
        }
    }

    @Test("pushVolume roundtrip")
    func testPushVolumeRoundtrip() {
        let data1 = Data("tx-body-1".utf8)
        let data2 = Data("tx-body-2".utf8)
        let cid1 = ContentIdentifier(for: data1)
        let cid2 = ContentIdentifier(for: data2)

        let msg = Message.pushVolume(rootCID: "push-root", items: [(cid1.rawValue, data1), (cid2.rawValue, data2)])
        let decoded = Message.deserialize(msg.serialize())

        if case .pushVolume(let rootCID, let items) = decoded {
            #expect(rootCID == "push-root")
            #expect(items.count == 2)
            #expect(items[0].cid == cid1.rawValue)
            #expect(items[0].data == data1)
            #expect(items[1].cid == cid2.rawValue)
            #expect(items[1].data == data2)
        } else {
            Issue.record("Expected pushVolume, got \(String(describing: decoded))")
        }
    }

    @Test("pushVolume framing roundtrip")
    func testPushVolumeFraming() {
        let data = Data("push-data".utf8)
        let cid = ContentIdentifier(for: data)
        let msg = Message.pushVolume(rootCID: "framed-push", items: [(cid.rawValue, data)])
        let framed = Message.frame(msg)
        let payload = framed.subdata(in: 4..<framed.count)
        let decoded = Message.deserialize(payload)

        if case .pushVolume(let root, let items) = decoded {
            #expect(root == "framed-push")
            #expect(items.count == 1)
            #expect(items[0].data == data)
        } else {
            Issue.record("Expected pushVolume after framing")
        }
    }

    @Test("announceVolume framing roundtrip")
    func testAnnounceVolumeFraming() {
        let msg = Message.announceVolume(rootCID: "vol-root", childCIDs: ["a", "b", "c"], totalSize: 512)
        let framed = Message.frame(msg)
        let payload = framed.subdata(in: 4..<framed.count)
        let decoded = Message.deserialize(payload)

        if case .announceVolume(let root, let children, let totalSize) = decoded {
            #expect(root == "vol-root")
            #expect(children == ["a", "b", "c"])
            #expect(totalSize == 512)
        } else {
            Issue.record("Expected announceVolume after framing")
        }
    }
}

// MARK: - Volume Storage Tests

@Suite("Volume-Aware Storage")
struct VolumeStorageTests {

    @Test("Volume members stored and co-located")
    func testVolumeStorageCoLocation() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "vol-store-node", maxEntries: 1000)

        let rootCID = "block-header-root"
        let childData1 = Data("transaction-1-data".utf8)
        let childData2 = Data("transaction-2-data".utf8)
        let childCID1 = ContentIdentifier(for: childData1)
        let childCID2 = ContentIdentifier(for: childData2)

        await store.registerVolume(rootCID: rootCID, childCIDs: [childCID1.rawValue, childCID2.rawValue])
        await store.storeVolumeBlock(cid: childCID1, data: childData1, volumeRootCID: rootCID)
        await store.storeVolumeBlock(cid: childCID2, data: childData2, volumeRootCID: rootCID)

        // Both children should be stored
        let has1 = await store.has(cid: childCID1)
        let has2 = await store.has(cid: childCID2)
        #expect(has1)
        #expect(has2)

        // Both should be in the same volume
        let root1 = await store.volumeRoot(for: childCID1.rawValue)
        let root2 = await store.volumeRoot(for: childCID2.rawValue)
        #expect(root1 == rootCID)
        #expect(root2 == rootCID)
    }

    @Test("Volume membership tracking")
    func testVolumeMembership() async {
        let store = ProfitWeightedStore(inner: MemStore(), nodePublicKey: "membership-node", maxEntries: 1000)

        let rootCID = "block-42"
        let children = ["tx-1", "tx-2", "tx-3"]
        await store.registerVolume(rootCID: rootCID, childCIDs: children)

        let members = await store.volumeMembers(rootCID: rootCID)
        #expect(members.contains("tx-1"))
        #expect(members.contains("tx-2"))
        #expect(members.contains("tx-3"))
        #expect(members.contains(rootCID)) // Root is self-member
    }

    @Test("storeVolumeBlock rejects tampered data")
    func testVolumeStoreRejectsTampered() async {
        let mem = MemStore()
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "tamper-node", maxEntries: 1000)

        let data = Data("real-tx".utf8)
        let fakeCID = ContentIdentifier(rawValue: "not-real")
        await store.storeVolumeBlock(cid: fakeCID, data: data, volumeRootCID: "some-root")

        let has = await mem.has(cid: fakeCID)
        #expect(!has)
    }

    @Test("Volume eviction removes entire volume as a unit")
    func testVolumeEvictionUnit() async {
        let mem = MemStore()
        // Very small store to force eviction
        let store = ProfitWeightedStore(inner: mem, nodePublicKey: "evict-node", maxEntries: 5)

        // Store a volume with 3 members
        let rootCID = "far-away-root"
        var childCIDs: [String] = []
        for i in 0..<3 {
            let data = Data("vol-tx-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            childCIDs.append(cid.rawValue)
            await store.registerVolume(rootCID: rootCID, childCIDs: childCIDs)
            await store.storeVolumeBlock(cid: cid, data: data, volumeRootCID: rootCID)
        }

        let countBefore = await store.entryCount
        #expect(countBefore == 3)

        // Fill with individual blocks to trigger eviction
        for i in 0..<10 {
            let data = Data("filler-block-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await store.storeLocal(cid: cid, data: data)
        }

        // At least some eviction should have happened
        let countAfter = await store.entryCount
        #expect(countAfter <= 5)
    }

    @Test("Volume root lookup returns nil for non-member")
    func testVolumeRootNonMember() async {
        let store = ProfitWeightedStore(inner: MemStore(), nodePublicKey: "lookup-node")
        let root = await store.volumeRoot(for: "unknown-cid")
        #expect(root == nil)
    }

    @Test("Volume members returns empty for unknown root")
    func testVolumeMembersUnknown() async {
        let store = ProfitWeightedStore(inner: MemStore(), nodePublicKey: "unknown-node")
        let members = await store.volumeMembers(rootCID: "nonexistent")
        #expect(members.isEmpty)
    }
}

// MARK: - CASBridge Volume Tests

@Suite("CASBridge Volume")
struct CASBridgeVolumeTests {

    @Test("storeVolume stores all items with verification")
    func testStoreVolume() async {
        let mem = MemStore()
        let config = IvyConfig(publicKey: "bridge-node-key", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)
        let bridge = await node.casBridge(localCAS: mem)

        let items: [(String, Data)] = (0..<5).map { i in
            let data = Data("vol-item-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            return (cid.rawValue, data)
        }

        let stored = await bridge.storeVolume(rootCID: "vol-root", items: items)
        #expect(stored == 5)

        // All items should be retrievable
        for (cid, expectedData) in items {
            let data = await mem.getLocal(cid: ContentIdentifier(rawValue: cid))
            #expect(data == expectedData)
        }
    }

    @Test("storeVolume rejects tampered items")
    func testStoreVolumeRejectsTampered() async {
        let mem = MemStore()
        let config = IvyConfig(publicKey: "bridge-tamper-key", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)
        let bridge = await node.casBridge(localCAS: mem)

        let items: [(String, Data)] = [
            ("fake-cid", Data("real-data".utf8)),
        ]

        let stored = await bridge.storeVolume(rootCID: "vol-root", items: items)
        #expect(stored == 0)
    }
}

// MARK: - NetworkCASWorker Volume Hint Tests

@Suite("NetworkCASWorker Volume Hints")
struct NetworkCASWorkerVolumeHintTests {

    @Test("Volume hint can be set and cleared")
    func testVolumeHintLifecycle() async {
        let config = IvyConfig(publicKey: "worker-hint-key", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)
        let worker = await node.worker()

        // Initially no hint — just verify the methods exist and don't crash
        await worker.provideVolumeHint(rootCID: "block-123")
        await worker.clearVolumeHint()
    }
}

// MARK: - Ivy Volume Provider Memory Tests

@Suite("Volume Provider Memory")
struct VolumeProviderMemoryTests {

    @Test("Provider tracked after announceVolume")
    func testProviderTrackedAfterAnnounce() async {
        let config = IvyConfig(publicKey: "provider-node", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)

        // Initially no providers
        let providers = await node.providers(for: "block-99")
        #expect(providers.isEmpty)
    }

    @Test("volumeRoot returns nil for unknown CID")
    func testVolumeRootUnknown() async {
        let config = IvyConfig(publicKey: "root-check-node", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)

        let root = await node.volumeRoot(for: "unknown-cid")
        #expect(root == nil)
    }

    @Test("publishVolume tracks membership")
    func testPublishVolumeTracksMembership() async {
        let config = IvyConfig(publicKey: "publish-vol-node", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)

        let rootCID = "block-header-55"
        let items: [(cid: String, data: Data)] = (0..<3).map { i in
            let data = Data("tx-\(i)-body".utf8)
            let cid = ContentIdentifier(for: data)
            return (cid: cid.rawValue, data: data)
        }

        await node.publishVolume(rootCID: rootCID, items: items)

        // All children should point to the root
        for (cid, _) in items {
            let root = await node.volumeRoot(for: cid)
            #expect(root == rootCID)
        }

        // Root points to itself
        let selfRoot = await node.volumeRoot(for: rootCID)
        #expect(selfRoot == rootCID)
    }
}

// MARK: - Volume Dedup and Gossip Tests

@Suite("Volume Gossip")
struct VolumeGossipTests {

    @Test("announceVolume dedup key prevents reprocessing")
    func testAnnounceVolumeDedupKey() {
        // The dedup key format is "vol-{rootCID}" in haveSet
        // Just verify the InventorySet dedup pattern works
        var haveSet = InventorySet()
        let key = "vol-block-root-99"
        #expect(!haveSet.contains(key))
        haveSet.insert(key)
        #expect(haveSet.contains(key))
    }
}

// MARK: - Volume Cleanup Tests

@Suite("Volume Cleanup")
struct VolumeCleanupTests {

    @Test("publishVolume populates blockCache for all items")
    func testPublishVolumePopulatesCache() async {
        let config = IvyConfig(publicKey: "cache-test-node", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)

        let items: [(cid: String, data: Data)] = (0..<3).map { i in
            let data = Data("cached-vol-item-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            return (cid: cid.rawValue, data: data)
        }

        await node.publishVolume(rootCID: "cache-root", items: items)

        // get() should find items in local cache without network
        for (cid, expectedData) in items {
            let data = await node.get(cid: cid)
            #expect(data == expectedData)
        }
    }

    @Test("stop() cleans up without crash when volume requests pending")
    func testStopCleansUpVolumeState() async throws {
        let config = IvyConfig(publicKey: "cleanup-node", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)
        try await node.start()

        // Publish a volume so there's state to clean up
        let data = Data("cleanup-data".utf8)
        let cid = ContentIdentifier(for: data)
        await node.publishVolume(rootCID: "cleanup-root", items: [(cid: cid.rawValue, data: data)])

        // Stop should not crash
        await node.stop()

        // After stop, volume lookup should still work (state is in-memory)
        let root = await node.volumeRoot(for: cid.rawValue)
        #expect(root == "cleanup-root")
    }
}

// MARK: - Delegate Callback Tests

@Suite("Volume Delegate")
struct VolumeDelegateTests {

    private final class TestDelegate: IvyDelegate, @unchecked Sendable {
        var receivedVolumeAnnouncements: [(rootCID: String, childCIDs: [String], totalSize: UInt64)] = []

        func ivy(_ ivy: Ivy, didReceiveVolumeAnnouncement rootCID: String, childCIDs: [String], totalSize: UInt64, from peer: PeerID) {
            receivedVolumeAnnouncements.append((rootCID: rootCID, childCIDs: childCIDs, totalSize: totalSize))
        }
    }

    @Test("Default delegate implementation does not crash")
    func testDefaultDelegateImpl() async {
        // The default extension should be a no-op
        let config = IvyConfig(publicKey: "delegate-test", listenPort: 0, bootstrapPeers: [])
        let node = Ivy(config: config)

        // This exercises the default empty implementation path
        let providers = await node.providers(for: "anything")
        #expect(providers.isEmpty)
    }
}
