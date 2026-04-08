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
        } else {
            Issue.record("Expected blockTxns")
        }
    }

    @Test("ChainAnnounce roundtrip")
    func testChainAnnounceRoundtrip() {
        let destHash = Data(repeating: 0xEE, count: 16)
        let chainData = Data("chain-specific-data".utf8)

        let msg = Message.chainAnnounce(
            destinationHash: destHash,
            hops: 3,
            chainData: chainData
        )
        let decoded = Message.deserialize(msg.serialize())

        if case .chainAnnounce(let dh, let h, let cd) = decoded {
            #expect(dh == destHash)
            #expect(h == 3)
            #expect(cd == chainData)
        } else {
            Issue.record("Expected chainAnnounce")
        }
    }

    @Test("Frame preserves chain messages")
    func testFrameChainMessages() {
        let messages: [Message] = [
            .chainAnnounce(destinationHash: Data(repeating: 0, count: 16), hops: 0, chainData: Data()),
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
