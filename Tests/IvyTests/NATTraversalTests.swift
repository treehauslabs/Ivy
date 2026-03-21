import Testing
import Foundation
@testable import Ivy
import NIOCore

@Suite("NAT Traversal Messages")
struct NATTraversalMessageTests {

    @Test("Identify roundtrip")
    func testIdentifyRoundtrip() {
        let msg = Message.identify(
            publicKey: "pk_abc123",
            observedHost: "203.0.113.5",
            observedPort: 4001,
            listenAddrs: [("0.0.0.0", 4001), ("203.0.113.5", 4001)]
        )
        let decoded = Message.deserialize(msg.serialize())
        if case .identify(let pk, let host, let port, let addrs) = decoded {
            #expect(pk == "pk_abc123")
            #expect(host == "203.0.113.5")
            #expect(port == 4001)
            #expect(addrs.count == 2)
            #expect(addrs[0].0 == "0.0.0.0")
            #expect(addrs[0].1 == 4001)
            #expect(addrs[1].0 == "203.0.113.5")
            #expect(addrs[1].1 == 4001)
        } else {
            Issue.record("Expected identify")
        }
    }

    @Test("Identify with no listen addrs")
    func testIdentifyEmpty() {
        let msg = Message.identify(publicKey: "pk", observedHost: "1.2.3.4", observedPort: 80, listenAddrs: [])
        let decoded = Message.deserialize(msg.serialize())
        if case .identify(let pk, _, _, let addrs) = decoded {
            #expect(pk == "pk")
            #expect(addrs.isEmpty)
        } else {
            Issue.record("Expected identify")
        }
    }

    @Test("DialBack roundtrip")
    func testDialBackRoundtrip() {
        let msg = Message.dialBack(nonce: 12345, host: "192.168.1.100", port: 4001)
        let decoded = Message.deserialize(msg.serialize())
        if case .dialBack(let n, let h, let p) = decoded {
            #expect(n == 12345)
            #expect(h == "192.168.1.100")
            #expect(p == 4001)
        } else {
            Issue.record("Expected dialBack")
        }
    }

    @Test("DialBackResult roundtrip success")
    func testDialBackResultSuccess() {
        let msg = Message.dialBackResult(nonce: 999, success: true)
        let decoded = Message.deserialize(msg.serialize())
        if case .dialBackResult(let n, let s) = decoded {
            #expect(n == 999)
            #expect(s == true)
        } else {
            Issue.record("Expected dialBackResult")
        }
    }

    @Test("DialBackResult roundtrip failure")
    func testDialBackResultFailure() {
        let msg = Message.dialBackResult(nonce: 888, success: false)
        let decoded = Message.deserialize(msg.serialize())
        if case .dialBackResult(let n, let s) = decoded {
            #expect(n == 888)
            #expect(s == false)
        } else {
            Issue.record("Expected dialBackResult")
        }
    }

    @Test("RelayConnect roundtrip")
    func testRelayConnectRoundtrip() {
        let msg = Message.relayConnect(srcKey: "alice_key", dstKey: "bob_key")
        let decoded = Message.deserialize(msg.serialize())
        if case .relayConnect(let src, let dst) = decoded {
            #expect(src == "alice_key")
            #expect(dst == "bob_key")
        } else {
            Issue.record("Expected relayConnect")
        }
    }

    @Test("RelayStatus roundtrip")
    func testRelayStatusRoundtrip() {
        for code: UInt8 in [0, 1, 2, 255] {
            let msg = Message.relayStatus(code: code)
            let decoded = Message.deserialize(msg.serialize())
            if case .relayStatus(let c) = decoded {
                #expect(c == code)
            } else {
                Issue.record("Expected relayStatus for code \(code)")
            }
        }
    }

    @Test("RelayData roundtrip")
    func testRelayDataRoundtrip() {
        let inner = Message.ping(nonce: 42).serialize()
        let msg = Message.relayData(peerKey: "target_key", data: inner)
        let decoded = Message.deserialize(msg.serialize())
        if case .relayData(let pk, let data) = decoded {
            #expect(pk == "target_key")
            #expect(data == inner)
            if case .ping(let n) = Message.deserialize(data) {
                #expect(n == 42)
            } else {
                Issue.record("Inner message decode failed")
            }
        } else {
            Issue.record("Expected relayData")
        }
    }

    @Test("HolepunchConnect roundtrip")
    func testHolepunchConnectRoundtrip() {
        let addrs: [(String, UInt16)] = [("203.0.113.5", 4001), ("10.0.0.1", 4002)]
        let msg = Message.holepunchConnect(addrs: addrs, nonce: 77777)
        let decoded = Message.deserialize(msg.serialize())
        if case .holepunchConnect(let a, let n) = decoded {
            #expect(n == 77777)
            #expect(a.count == 2)
            #expect(a[0].0 == "203.0.113.5")
            #expect(a[0].1 == 4001)
            #expect(a[1].0 == "10.0.0.1")
            #expect(a[1].1 == 4002)
        } else {
            Issue.record("Expected holepunchConnect")
        }
    }

    @Test("HolepunchSync roundtrip")
    func testHolepunchSyncRoundtrip() {
        let msg = Message.holepunchSync(nonce: 55555)
        let decoded = Message.deserialize(msg.serialize())
        if case .holepunchSync(let n) = decoded {
            #expect(n == 55555)
        } else {
            Issue.record("Expected holepunchSync")
        }
    }

    @Test("DHTForward roundtrip")
    func testDHTForwardRoundtrip() {
        let msg = Message.dhtForward(cid: "QmTest123", ttl: 3)
        let decoded = Message.deserialize(msg.serialize())
        if case .dhtForward(let cid, let ttl) = decoded {
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
        if case .dhtForward(_, let ttl) = decoded {
            #expect(ttl == 0)
        } else {
            Issue.record("Expected dhtForward")
        }
    }

    @Test("Frame preserves new message types")
    func testFrameNewMessages() {
        let messages: [Message] = [
            .identify(publicKey: "pk", observedHost: "1.2.3.4", observedPort: 80, listenAddrs: []),
            .dialBack(nonce: 1, host: "h", port: 1),
            .dialBackResult(nonce: 1, success: true),
            .relayConnect(srcKey: "a", dstKey: "b"),
            .relayStatus(code: 0),
            .relayData(peerKey: "k", data: Data([1, 2, 3])),
            .holepunchConnect(addrs: [("h", 1)], nonce: 1),
            .holepunchSync(nonce: 1),
            .dhtForward(cid: "test", ttl: 5),
        ]
        for msg in messages {
            let framed = Message.frame(msg)
            let length = framed.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            #expect(Int(length) == framed.count - 4)
        }
    }
}

@Suite("STUN Response Parsing")
struct STUNParsingTests {

    @Test("Parse XOR-MAPPED-ADDRESS IPv4")
    func testXorMappedAddress() {
        var buf = buildSTUNResponse(attrType: 0x0020, xorMapped: true, ip: "203.0.113.5", port: 4001)
        let addr = STUNResponseHandler.parseResponse(&buf)
        #expect(addr != nil)
        #expect(addr?.host == "203.0.113.5")
        #expect(addr?.port == 4001)
    }

    @Test("Parse MAPPED-ADDRESS IPv4")
    func testMappedAddress() {
        var buf = buildSTUNResponse(attrType: 0x0001, xorMapped: false, ip: "192.168.1.1", port: 8080)
        let addr = STUNResponseHandler.parseResponse(&buf)
        #expect(addr != nil)
        #expect(addr?.host == "192.168.1.1")
        #expect(addr?.port == 8080)
    }

    @Test("Invalid magic cookie returns nil")
    func testBadMagic() {
        var buf = ByteBuffer()
        buf.writeInteger(UInt16(0x0101), endianness: .big)
        buf.writeInteger(UInt16(0), endianness: .big)
        buf.writeInteger(UInt32(0xDEADBEEF), endianness: .big)
        buf.writeRepeatingByte(0, count: 12)
        #expect(STUNResponseHandler.parseResponse(&buf) == nil)
    }

    @Test("Truncated response returns nil")
    func testTruncated() {
        var buf = ByteBuffer()
        buf.writeBytes([0x01, 0x01, 0x00])
        #expect(STUNResponseHandler.parseResponse(&buf) == nil)
    }

    private func buildSTUNResponse(attrType: UInt16, xorMapped: Bool, ip: String, port: UInt16) -> ByteBuffer {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        let ipNum = UInt32(parts[0]) << 24 | UInt32(parts[1]) << 16 | UInt32(parts[2]) << 8 | UInt32(parts[3])

        let magic: UInt32 = 0x2112A442

        let xPort: UInt16 = xorMapped ? (port ^ 0x2112) : port
        let xAddr: UInt32 = xorMapped ? (ipNum ^ magic) : ipNum

        var attrBuf = ByteBuffer()
        attrBuf.writeInteger(attrType, endianness: .big)
        attrBuf.writeInteger(UInt16(8), endianness: .big)
        attrBuf.writeInteger(UInt8(0))
        attrBuf.writeInteger(UInt8(0x01))
        attrBuf.writeInteger(xPort, endianness: .big)
        attrBuf.writeInteger(xAddr, endianness: .big)

        var buf = ByteBuffer()
        buf.writeInteger(UInt16(0x0101), endianness: .big)
        buf.writeInteger(UInt16(attrBuf.readableBytes), endianness: .big)
        buf.writeInteger(magic, endianness: .big)
        buf.writeRepeatingByte(0, count: 12)
        buf.writeBuffer(&attrBuf)

        return buf
    }
}

@Suite("Relay Service")
struct RelayServiceTests {

    @Test("Create and use circuit")
    func testCircuitLifecycle() async {
        let relay = RelayService()
        let created = await relay.createCircuit(initiator: "alice", target: "bob")
        #expect(created == true)

        let exists = await relay.hasCircuit(between: "alice", and: "bob")
        #expect(exists == true)

        let existsReverse = await relay.hasCircuit(between: "bob", and: "alice")
        #expect(existsReverse == true)

        let relayed = await relay.relay(from: "alice", to: "bob", bytes: 100)
        #expect(relayed == true)
    }

    @Test("Duplicate circuit denied")
    func testDuplicateCircuit() async {
        let relay = RelayService()
        let first = await relay.createCircuit(initiator: "alice", target: "bob")
        #expect(first == true)
        let second = await relay.createCircuit(initiator: "alice", target: "bob")
        #expect(second == false)
    }

    @Test("Remove circuit")
    func testRemoveCircuit() async {
        let relay = RelayService()
        _ = await relay.createCircuit(initiator: "alice", target: "bob")
        await relay.removeCircuit(between: "alice", and: "bob")
        let exists = await relay.hasCircuit(between: "alice", and: "bob")
        #expect(exists == false)
    }

    @Test("Remove all circuits for peer")
    func testRemoveAllForPeer() async {
        let relay = RelayService()
        _ = await relay.createCircuit(initiator: "alice", target: "bob")
        _ = await relay.createCircuit(initiator: "alice", target: "charlie")
        await relay.removeAllCircuits(forPeer: "alice")
        #expect(await relay.hasCircuit(between: "alice", and: "bob") == false)
        #expect(await relay.hasCircuit(between: "alice", and: "charlie") == false)
    }

    @Test("Per-peer circuit limit")
    func testPerPeerLimit() async {
        let relay = RelayService()
        for i in 0..<4 {
            let created = await relay.createCircuit(initiator: "alice", target: "peer\(i)")
            #expect(created == true)
        }
        let fifth = await relay.createCircuit(initiator: "alice", target: "peer4")
        #expect(fifth == false)
    }
}

@Suite("ObservedAddress")
struct ObservedAddressTests {

    @Test("Equality")
    func testEquality() {
        let a = ObservedAddress(host: "1.2.3.4", port: 4001)
        let b = ObservedAddress(host: "1.2.3.4", port: 4001)
        let c = ObservedAddress(host: "1.2.3.4", port: 4002)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Hashing")
    func testHashing() {
        let a = ObservedAddress(host: "1.2.3.4", port: 4001)
        let b = ObservedAddress(host: "1.2.3.4", port: 4001)
        var set: Set<ObservedAddress> = [a]
        set.insert(b)
        #expect(set.count == 1)
    }
}

@Suite("PeerEndpoint Hashable")
struct PeerEndpointHashableTests {

    @Test("PeerEndpoint in Set")
    func testPeerEndpointSet() {
        let a = PeerEndpoint(publicKey: "k1", host: "1.2.3.4", port: 4001)
        let b = PeerEndpoint(publicKey: "k1", host: "1.2.3.4", port: 4001)
        var set: Set<PeerEndpoint> = [a]
        set.insert(b)
        #expect(set.count == 1)
    }
}
