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

    @Test("WantBlock roundtrip")
    func testWantBlockRoundtrip() {
        let cid = "abc123def456"
        let msg = Message.wantBlock(cid: cid)
        let decoded = Message.deserialize(msg.serialize())
        if case .wantBlock(let c) = decoded {
            #expect(c == cid)
        } else {
            Issue.record("Expected wantBlock")
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
        if case .findNode(let t) = decoded {
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
}
