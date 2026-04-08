import Testing
import Foundation
@testable import Ivy

@Suite("Message")
struct MessageTests {

    @Test("Ping roundtrip")
    func testPingRoundtrip() {
        let msg = Message.ping(nonce: 42)
        let data = msg.serialize()
        let decoded = Message.deserialize(data)
        if case .ping(let nonce) = decoded {
            #expect(nonce == 42)
        } else {
            Issue.record("Expected ping")
        }
    }

    @Test("Pong roundtrip")
    func testPongRoundtrip() {
        let msg = Message.pong(nonce: 99)
        let data = msg.serialize()
        let decoded = Message.deserialize(data)
        if case .pong(let nonce) = decoded {
            #expect(nonce == 99)
        } else {
            Issue.record("Expected pong")
        }
    }

    @Test("Block roundtrip")
    func testBlockRoundtrip() {
        let cid = "deadbeef"
        let payload = Data([1, 2, 3, 4, 5])
        let msg = Message.block(cid: cid, data: payload)
        let decoded = Message.deserialize(msg.serialize())
        if case .block(let c, let d) = decoded {
            #expect(c == cid)
            #expect(d == payload)
        } else {
            Issue.record("Expected block")
        }
    }

    @Test("DontHave roundtrip")
    func testDontHaveRoundtrip() {
        let msg = Message.dontHave(cid: "missing")
        let decoded = Message.deserialize(msg.serialize())
        if case .dontHave(let c) = decoded {
            #expect(c == "missing")
        } else {
            Issue.record("Expected dontHave")
        }
    }

    @Test("FindNode roundtrip")
    func testFindNodeRoundtrip() {
        let target = Data(repeating: 0xAB, count: 32)
        let msg = Message.findNode(target: target)
        let decoded = Message.deserialize(msg.serialize())
        if case .findNode(let t, _) = decoded {
            #expect(t == target)
        } else {
            Issue.record("Expected findNode")
        }
    }

    @Test("Neighbors roundtrip")
    func testNeighborsRoundtrip() {
        let peers = [
            PeerEndpoint(publicKey: "key1", host: "192.168.1.1", port: 4001),
            PeerEndpoint(publicKey: "key2", host: "10.0.0.1", port: 4002),
        ]
        let msg = Message.neighbors(peers)
        let decoded = Message.deserialize(msg.serialize())
        if case .neighbors(let p) = decoded {
            #expect(p.count == 2)
            #expect(p[0].publicKey == "key1")
            #expect(p[0].host == "192.168.1.1")
            #expect(p[0].port == 4001)
            #expect(p[1].publicKey == "key2")
        } else {
            Issue.record("Expected neighbors")
        }
    }

    @Test("AnnounceBlock roundtrip")
    func testAnnounceBlockRoundtrip() {
        let msg = Message.announceBlock(cid: "newblock")
        let decoded = Message.deserialize(msg.serialize())
        if case .announceBlock(let c) = decoded {
            #expect(c == "newblock")
        } else {
            Issue.record("Expected announceBlock")
        }
    }

    @Test("Frame includes length prefix")
    func testFrame() {
        let msg = Message.ping(nonce: 1)
        let framed = Message.frame(msg)
        let length = framed.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        #expect(Int(length) == framed.count - 4)
    }

    @Test("Empty data returns nil")
    func testEmptyData() {
        #expect(Message.deserialize(Data()) == nil)
    }

    @Test("Invalid tag returns nil")
    func testInvalidTag() {
        #expect(Message.deserialize(Data([255])) == nil)
    }

    @Test("Large block roundtrip")
    func testLargeBlock() {
        let payload = Data(repeating: 0xFF, count: 1_000_000)
        let msg = Message.block(cid: "large", data: payload)
        let decoded = Message.deserialize(msg.serialize())
        if case .block(let c, let d) = decoded {
            #expect(c == "large")
            #expect(d.count == 1_000_000)
        } else {
            Issue.record("Expected block")
        }
    }

    @Test("DHTForward roundtrip")
    func testDHTForwardRoundtrip() {
        let msg = Message.dhtForward(cid: "QmTest123", ttl: 3)
        let decoded = Message.deserialize(msg.serialize())
        if case .dhtForward(let cid, let ttl, _, _, _) = decoded {
            #expect(cid == "QmTest123")
            #expect(ttl == 3)
        } else {
            Issue.record("Expected dhtForward")
        }
    }

    @Test("DHTForward zero TTL roundtrip")
    func testDHTForwardZeroTTL() {
        let msg = Message.dhtForward(cid: "abc", ttl: 0)
        let decoded = Message.deserialize(msg.serialize())
        if case .dhtForward(_, let ttl, _, _, _) = decoded {
            #expect(ttl == 0)
        } else {
            Issue.record("Expected dhtForward")
        }
    }

    @Test("PexRequest roundtrip")
    func testPexRequestRoundtrip() {
        let msg = Message.pexRequest(nonce: 12345)
        let decoded = Message.deserialize(msg.serialize())
        if case .pexRequest(let nonce) = decoded {
            #expect(nonce == 12345)
        } else {
            Issue.record("Expected pexRequest")
        }
    }

    @Test("PexResponse roundtrip")
    func testPexResponseRoundtrip() {
        let peers = [
            PeerEndpoint(publicKey: "pex-key1", host: "10.0.0.1", port: 4001),
            PeerEndpoint(publicKey: "pex-key2", host: "10.0.0.2", port: 4002),
            PeerEndpoint(publicKey: "pex-key3", host: "192.168.1.5", port: 4003),
        ]
        let msg = Message.pexResponse(nonce: 99999, peers: peers)
        let decoded = Message.deserialize(msg.serialize())
        if case .pexResponse(let nonce, let p) = decoded {
            #expect(nonce == 99999)
            #expect(p.count == 3)
            #expect(p[0].publicKey == "pex-key1")
            #expect(p[0].host == "10.0.0.1")
            #expect(p[0].port == 4001)
            #expect(p[1].publicKey == "pex-key2")
            #expect(p[2].host == "192.168.1.5")
            #expect(p[2].port == 4003)
        } else {
            Issue.record("Expected pexResponse")
        }
    }

    @Test("PexResponse with empty peers roundtrip")
    func testPexResponseEmpty() {
        let msg = Message.pexResponse(nonce: 1, peers: [])
        let decoded = Message.deserialize(msg.serialize())
        if case .pexResponse(let nonce, let p) = decoded {
            #expect(nonce == 1)
            #expect(p.isEmpty)
        } else {
            Issue.record("Expected pexResponse")
        }
    }

    @Test("GetZoneInventory roundtrip")
    func testGetZoneInventoryRoundtrip() {
        let nodeHash = Data(repeating: 0xAB, count: 32)
        let msg = Message.getZoneInventory(nodeHash: nodeHash, limit: 256)
        let decoded = Message.deserialize(msg.serialize())
        if case .getZoneInventory(let nh, let lim) = decoded {
            #expect(nh == nodeHash)
            #expect(lim == 256)
        } else {
            Issue.record("Expected getZoneInventory")
        }
    }

    @Test("ZoneInventory roundtrip")
    func testZoneInventoryRoundtrip() {
        let cids = ["cid-abc", "cid-def", "cid-ghi"]
        let msg = Message.zoneInventory(cids: cids)
        let decoded = Message.deserialize(msg.serialize())
        if case .zoneInventory(let c) = decoded {
            #expect(c == cids)
        } else {
            Issue.record("Expected zoneInventory")
        }
    }

    @Test("ZoneInventory empty roundtrip")
    func testZoneInventoryEmpty() {
        let msg = Message.zoneInventory(cids: [])
        let decoded = Message.deserialize(msg.serialize())
        if case .zoneInventory(let c) = decoded {
            #expect(c.isEmpty)
        } else {
            Issue.record("Expected zoneInventory")
        }
    }

    @Test("HaveCIDs roundtrip")
    func testHaveCIDsRoundtrip() {
        let cids = ["block-1", "block-2", "block-3"]
        let msg = Message.haveCIDs(nonce: 42424242, cids: cids)
        let decoded = Message.deserialize(msg.serialize())
        if case .haveCIDs(let nonce, let c) = decoded {
            #expect(nonce == 42424242)
            #expect(c == cids)
        } else {
            Issue.record("Expected haveCIDs")
        }
    }

    @Test("HaveCIDsResult roundtrip")
    func testHaveCIDsResultRoundtrip() {
        let have = ["block-1", "block-3"]
        let msg = Message.haveCIDsResult(nonce: 99887766, have: have)
        let decoded = Message.deserialize(msg.serialize())
        if case .haveCIDsResult(let nonce, let h) = decoded {
            #expect(nonce == 99887766)
            #expect(h == have)
        } else {
            Issue.record("Expected haveCIDsResult")
        }
    }

    @Test("HaveCIDsResult empty roundtrip")
    func testHaveCIDsResultEmpty() {
        let msg = Message.haveCIDsResult(nonce: 1, have: [])
        let decoded = Message.deserialize(msg.serialize())
        if case .haveCIDsResult(let nonce, let h) = decoded {
            #expect(nonce == 1)
            #expect(h.isEmpty)
        } else {
            Issue.record("Expected haveCIDsResult")
        }
    }

    @Test("Identify with signature roundtrip")
    func testIdentifyWithSignature() {
        let sig = Data(repeating: 0xAB, count: 64)
        let msg = Message.identify(
            publicKey: "pk_test",
            observedHost: "1.2.3.4",
            observedPort: 4001,
            listenAddrs: [("0.0.0.0", 4001)],
            signature: sig
        )
        let decoded = Message.deserialize(msg.serialize())
        if case .identify(let pk, let host, let port, let addrs, let s) = decoded {
            #expect(pk == "pk_test")
            #expect(host == "1.2.3.4")
            #expect(port == 4001)
            #expect(addrs.count == 1)
            #expect(s == sig)
        } else {
            Issue.record("Expected identify")
        }
    }

    @Test("Identify with empty signature roundtrip")
    func testIdentifyEmptySignature() {
        let msg = Message.identify(publicKey: "pk", observedHost: "h", observedPort: 80, listenAddrs: [], signature: Data())
        let decoded = Message.deserialize(msg.serialize())
        if case .identify(_, _, _, _, let s) = decoded {
            #expect(s.isEmpty)
        } else {
            Issue.record("Expected identify")
        }
    }

    @Test("WantBlocks roundtrip")
    func testWantBlocksRoundtrip() {
        let cids = ["cid-1", "cid-2", "cid-3"]
        let msg = Message.wantBlocks(cids: cids)
        let decoded = Message.deserialize(msg.serialize())
        if case .wantBlocks(let c) = decoded {
            #expect(c == cids)
        } else {
            Issue.record("Expected wantBlocks")
        }
    }
}
