import Testing
import Foundation
@testable import Ivy
import Tally

@Suite("ChainDestination")
struct ChainDestinationTests {

    @Test("Nexus destination is deterministic")
    func testNexusDeterministic() {
        let a = ChainDestination.nexus()
        let b = ChainDestination.nexus()
        #expect(a.destinationHash == b.destinationHash)
        #expect(a.destinationHash.count == 16)
        #expect(a.chainDirectory == "Nexus")
    }

    @Test("Different chains have different hashes")
    func testDifferentChainsDifferentHashes() {
        let nexus = ChainDestination(chainDirectory: "Nexus")
        let payments = ChainDestination(chainDirectory: "Nexus/Payments")
        let identity = ChainDestination(chainDirectory: "Nexus/Identity")
        #expect(nexus.destinationHash != payments.destinationHash)
        #expect(payments.destinationHash != identity.destinationHash)
    }

    @Test("Spec CID changes destination hash")
    func testSpecCIDChangesHash() {
        let a = ChainDestination(chainDirectory: "Nexus", specCID: "spec-v1")
        let b = ChainDestination(chainDirectory: "Nexus", specCID: "spec-v2")
        #expect(a.destinationHash != b.destinationHash)
    }

    @Test("Hash is 16 bytes")
    func testHashLength() {
        let chain = ChainDestination(chainDirectory: "Test/Chain")
        #expect(chain.destinationHash.count == 16)
    }

    @Test("Hashable conformance")
    func testHashable() {
        let a = ChainDestination(chainDirectory: "Nexus")
        let b = ChainDestination(chainDirectory: "Nexus")
        var set = Set<ChainDestination>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}

@Suite("ChainAnnounceData")
struct ChainAnnounceDataTests {

    @Test("Serialization roundtrip")
    func testRoundtrip() {
        let data = ChainAnnounceData(
            chainDirectory: "Nexus/Payments",
            tipIndex: 42000,
            tipCID: "abc123def456",
            specCID: "spec-cid-789",
            capabilities: [.fullNode, .miner]
        )

        let serialized = data.serialize()
        let decoded = ChainAnnounceData.deserialize(serialized)!

        #expect(decoded.chainDirectory == "Nexus/Payments")
        #expect(decoded.tipIndex == 42000)
        #expect(decoded.tipCID == "abc123def456")
        #expect(decoded.specCID == "spec-cid-789")
        #expect(decoded.capabilities.contains(.fullNode))
        #expect(decoded.capabilities.contains(.miner))
        #expect(!decoded.capabilities.contains(.archiveNode))
    }

    @Test("All capabilities roundtrip")
    func testAllCapabilities() {
        let all: ChainCapabilities = [.fullNode, .miner, .archiveNode, .lightClient, .transportServer]
        let data = ChainAnnounceData(
            chainDirectory: "X",
            tipIndex: 0,
            tipCID: "",
            specCID: "",
            capabilities: all
        )
        let decoded = ChainAnnounceData.deserialize(data.serialize())!
        #expect(decoded.capabilities == all)
    }

    @Test("Empty chain directory")
    func testEmptyDirectory() {
        let data = ChainAnnounceData(chainDirectory: "", tipIndex: 0, tipCID: "", specCID: "")
        let decoded = ChainAnnounceData.deserialize(data.serialize())!
        #expect(decoded.chainDirectory == "")
    }
}

@Suite("ChainCapabilities")
struct ChainCapabilitiesTests {

    @Test("Default is fullNode")
    func testDefault() {
        let caps = ChainCapabilities.default
        #expect(caps.contains(.fullNode))
        #expect(!caps.contains(.miner))
    }

    @Test("OptionSet operations")
    func testOptionSet() {
        var caps: ChainCapabilities = [.fullNode]
        caps.insert(.miner)
        #expect(caps.contains(.fullNode))
        #expect(caps.contains(.miner))

        caps.remove(.fullNode)
        #expect(!caps.contains(.fullNode))
        #expect(caps.contains(.miner))
    }

    @Test("Raw values are distinct powers of 2")
    func testRawValues() {
        #expect(ChainCapabilities.fullNode.rawValue == 1)
        #expect(ChainCapabilities.miner.rawValue == 2)
        #expect(ChainCapabilities.archiveNode.rawValue == 4)
        #expect(ChainCapabilities.lightClient.rawValue == 8)
        #expect(ChainCapabilities.transportServer.rawValue == 16)
    }
}

@Suite("ChainSubscriptionRegistry")
struct ChainSubscriptionRegistryTests {

    @Test("Subscribe and check")
    func testSubscribe() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let chain = ChainDestination(chainDirectory: "Nexus")
        await registry.subscribe(to: chain)

        let subscribed = await registry.isSubscribed(to: chain.destinationHash)
        #expect(subscribed)
    }

    @Test("Unsubscribe")
    func testUnsubscribe() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let chain = ChainDestination(chainDirectory: "Nexus")
        await registry.subscribe(to: chain)
        await registry.unsubscribe(from: chain)

        let subscribed = await registry.isSubscribed(to: chain.destinationHash)
        #expect(!subscribed)
    }

    @Test("Register and retrieve chain peers")
    func testRegisterPeer() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let chain = ChainDestination(chainDirectory: "Nexus")
        await registry.subscribe(to: chain)

        let peer = PeerID(publicKey: "peer-miner-1")
        let announceData = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipIndex: 100,
            tipCID: "tip-abc",
            specCID: "spec-xyz",
            capabilities: [.fullNode, .miner]
        )

        await registry.registerPeer(peer, for: chain.destinationHash, announceData: announceData)

        let peers = await registry.peersForChain(chain.destinationHash)
        #expect(peers.count == 1)
        #expect(peers[0].peerID == peer)
        #expect(peers[0].tipIndex == 100)
        #expect(peers[0].capabilities.contains(.miner))
    }

    @Test("Best peers sorted by reputation")
    func testBestPeersSorted() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let chain = ChainDestination(chainDirectory: "Nexus")
        await registry.subscribe(to: chain)

        for i in 0..<10 {
            let peer = PeerID(publicKey: "peer-\(i)")
            if i < 5 {
                tally.recordSuccess(peer: peer)
                tally.recordReceived(peer: peer, bytes: 1000 * (i + 1), cpl: 0)
            }
            let data = ChainAnnounceData(chainDirectory: "Nexus", tipIndex: UInt64(i), tipCID: "tip-\(i)", specCID: "spec")
            await registry.registerPeer(peer, for: chain.destinationHash, announceData: data)
        }

        let best = await registry.bestPeersForChain(chain.destinationHash, count: 3)
        #expect(best.count == 3)
    }

    @Test("Filter by capability")
    func testFilterByCapability() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let chain = ChainDestination(chainDirectory: "Nexus")
        await registry.subscribe(to: chain)

        let fullNode = PeerID(publicKey: "full-node")
        let miner = PeerID(publicKey: "miner-node")

        await registry.registerPeer(fullNode, for: chain.destinationHash, announceData:
            ChainAnnounceData(chainDirectory: "Nexus", tipIndex: 100, tipCID: "t1", specCID: "s", capabilities: [.fullNode]))

        await registry.registerPeer(miner, for: chain.destinationHash, announceData:
            ChainAnnounceData(chainDirectory: "Nexus", tipIndex: 100, tipCID: "t2", specCID: "s", capabilities: [.fullNode, .miner]))

        let miners = await registry.peersWithCapability(.miner, for: chain.destinationHash)
        #expect(miners.count == 1)
        #expect(miners[0].peerID == miner)

        let fullNodes = await registry.peersWithCapability(.fullNode, for: chain.destinationHash)
        #expect(fullNodes.count == 2)
    }

    @Test("Peer count")
    func testPeerCount() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let chain = ChainDestination(chainDirectory: "Nexus")
        await registry.subscribe(to: chain)

        for i in 0..<5 {
            let peer = PeerID(publicKey: "p-\(i)")
            let data = ChainAnnounceData(chainDirectory: "Nexus", tipIndex: 0, tipCID: "", specCID: "")
            await registry.registerPeer(peer, for: chain.destinationHash, announceData: data)
        }

        let count = await registry.peerCount(for: chain.destinationHash)
        #expect(count == 5)
    }

    @Test("Remove peer")
    func testRemovePeer() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let chain = ChainDestination(chainDirectory: "Nexus")
        let peer = PeerID(publicKey: "removable")
        await registry.subscribe(to: chain)
        await registry.registerPeer(peer, for: chain.destinationHash, announceData:
            ChainAnnounceData(chainDirectory: "Nexus", tipIndex: 0, tipCID: "", specCID: ""))

        await registry.removePeer(peer, from: chain.destinationHash)
        let count = await registry.peerCount(for: chain.destinationHash)
        #expect(count == 0)
    }

    @Test("Multiple chains independent")
    func testMultipleChains() async {
        let tally = Tally(config: .default)
        let registry = ChainSubscriptionRegistry(tally: tally)

        let nexus = ChainDestination(chainDirectory: "Nexus")
        let payments = ChainDestination(chainDirectory: "Nexus/Payments")
        await registry.subscribe(to: nexus)
        await registry.subscribe(to: payments)

        let peer = PeerID(publicKey: "nexus-only")
        await registry.registerPeer(peer, for: nexus.destinationHash, announceData:
            ChainAnnounceData(chainDirectory: "Nexus", tipIndex: 0, tipCID: "", specCID: ""))

        #expect(await registry.peerCount(for: nexus.destinationHash) == 1)
        #expect(await registry.peerCount(for: payments.destinationHash) == 0)
    }
}

@Suite("Compact Block Messages")
struct CompactBlockMessageTests {

    @Test("CompactBlock roundtrip")
    func testCompactBlockRoundtrip() {
        let chainHash = Data(repeating: 0xAA, count: 16)
        let txCIDs = ["tx-cid-1", "tx-cid-2", "tx-cid-3"]
        let msg = Message.compactBlock(chainHash: chainHash, headerCID: "block-header-abc", txCIDs: txCIDs)
        let decoded = Message.deserialize(msg.serialize())

        if case .compactBlock(let ch, let hcid, let txs) = decoded {
            #expect(ch == chainHash)
            #expect(hcid == "block-header-abc")
            #expect(txs == txCIDs)
        } else {
            Issue.record("Expected compactBlock")
        }
    }

    @Test("CompactBlock empty txCIDs")
    func testCompactBlockEmpty() {
        let chainHash = Data(repeating: 0xBB, count: 16)
        let msg = Message.compactBlock(chainHash: chainHash, headerCID: "h", txCIDs: [])
        let decoded = Message.deserialize(msg.serialize())

        if case .compactBlock(_, _, let txs) = decoded {
            #expect(txs.isEmpty)
        } else {
            Issue.record("Expected compactBlock")
        }
    }

    @Test("GetBlockTxns roundtrip")
    func testGetBlockTxnsRoundtrip() {
        let chainHash = Data(repeating: 0xCC, count: 16)
        let missing = ["tx-5", "tx-9"]
        let msg = Message.getBlockTxns(chainHash: chainHash, headerCID: "block-xyz", missingTxCIDs: missing)
        let decoded = Message.deserialize(msg.serialize())

        if case .getBlockTxns(let ch, let hcid, let m) = decoded {
            #expect(ch == chainHash)
            #expect(hcid == "block-xyz")
            #expect(m == missing)
        } else {
            Issue.record("Expected getBlockTxns")
        }
    }

    @Test("BlockTxns roundtrip")
    func testBlockTxnsRoundtrip() {
        let chainHash = Data(repeating: 0xDD, count: 16)
        let txns = [
            ("tx-1", Data("transaction-body-1".utf8)),
            ("tx-2", Data("transaction-body-2".utf8)),
        ]
        let msg = Message.blockTxns(chainHash: chainHash, headerCID: "block-abc", transactions: txns)
        let decoded = Message.deserialize(msg.serialize())

        if case .blockTxns(let ch, let hcid, let t) = decoded {
            #expect(ch == chainHash)
            #expect(hcid == "block-abc")
            #expect(t.count == 2)
            #expect(t[0].0 == "tx-1")
            #expect(t[0].1 == Data("transaction-body-1".utf8))
            #expect(t[1].0 == "tx-2")
            #expect(t[1].1 == Data("transaction-body-2".utf8))
        } else {
            Issue.record("Expected blockTxns")
        }
    }

    @Test("ChainAnnounce roundtrip")
    func testChainAnnounceRoundtrip() {
        let destHash = Data(repeating: 0xEE, count: 16)
        let chainData = ChainAnnounceData(
            chainDirectory: "Nexus/Payments",
            tipIndex: 5000,
            tipCID: "tip-cid",
            specCID: "spec-cid",
            capabilities: [.fullNode, .miner]
        ).serialize()
        let announcePayload = Data("announce-signed-data".utf8)

        let msg = Message.chainAnnounce(
            destinationHash: destHash,
            hops: 3,
            chainData: chainData,
            announcePayload: announcePayload
        )
        let decoded = Message.deserialize(msg.serialize())

        if case .chainAnnounce(let dh, let h, let cd, let ap) = decoded {
            #expect(dh == destHash)
            #expect(h == 3)
            #expect(cd == chainData)
            #expect(ap == announcePayload)

            let inner = ChainAnnounceData.deserialize(cd)!
            #expect(inner.chainDirectory == "Nexus/Payments")
            #expect(inner.tipIndex == 5000)
        } else {
            Issue.record("Expected chainAnnounce")
        }
    }

    @Test("Frame preserves chain messages")
    func testFrameChainMessages() {
        let messages: [Message] = [
            .chainAnnounce(destinationHash: Data(repeating: 0, count: 16), hops: 0, chainData: Data(), announcePayload: Data()),
            .compactBlock(chainHash: Data(repeating: 0, count: 16), headerCID: "h", txCIDs: ["t1", "t2"]),
            .getBlockTxns(chainHash: Data(repeating: 0, count: 16), headerCID: "h", missingTxCIDs: ["t1"]),
            .blockTxns(chainHash: Data(repeating: 0, count: 16), headerCID: "h", transactions: [("t1", Data([1]))]),
        ]
        for msg in messages {
            let framed = Message.frame(msg)
            let length = framed.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            #expect(Int(length) == framed.count - 4)
        }
    }
}
