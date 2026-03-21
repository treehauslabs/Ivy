import Testing
import Foundation
@testable import Ivy
import NIOCore
import Tally

@Suite("TransportPacket Serialization")
struct TransportPacketTests {

    @Test("Header1 data packet roundtrip")
    func testHeader1DataRoundtrip() {
        let destHash = Data(repeating: 0xAB, count: 16)
        let payload = Data("hello reticulum".utf8)
        let packet = TransportPacket(
            headerType: .header1,
            propagationType: .broadcast,
            destinationType: .single,
            packetType: .data,
            hops: 3,
            destinationHash: destHash,
            payload: payload
        )

        let serialized = packet.serialize()
        let decoded = TransportPacket.deserialize(serialized)!

        #expect(decoded.headerType == .header1)
        #expect(decoded.propagationType == .broadcast)
        #expect(decoded.destinationType == .single)
        #expect(decoded.packetType == .data)
        #expect(decoded.hops == 3)
        #expect(decoded.destinationHash == destHash)
        #expect(decoded.payload == payload)
        #expect(decoded.transportID == nil)
    }

    @Test("Header2 transport packet roundtrip")
    func testHeader2TransportRoundtrip() {
        let destHash = Data(repeating: 0xCD, count: 16)
        let transportID = Data(repeating: 0xEF, count: 16)
        let payload = Data([1, 2, 3, 4])
        let packet = TransportPacket(
            headerType: .header2,
            propagationType: .transport,
            destinationType: .single,
            packetType: .data,
            hops: 7,
            destinationHash: destHash,
            transportID: transportID,
            payload: payload
        )

        let serialized = packet.serialize()
        let decoded = TransportPacket.deserialize(serialized)!

        #expect(decoded.headerType == .header2)
        #expect(decoded.propagationType == .transport)
        #expect(decoded.transportID == transportID)
        #expect(decoded.destinationHash == destHash)
        #expect(decoded.hops == 7)
        #expect(decoded.payload == payload)
    }

    @Test("Announce packet roundtrip")
    func testAnnouncePacketRoundtrip() {
        let destHash = Data(repeating: 0x11, count: 16)
        let payload = Data("announce-data".utf8)
        let packet = TransportPacket(
            packetType: .announce,
            hops: 0,
            destinationHash: destHash,
            payload: payload
        )

        let serialized = packet.serialize()
        let decoded = TransportPacket.deserialize(serialized)!

        #expect(decoded.packetType == .announce)
        #expect(decoded.hops == 0)
        #expect(decoded.destinationHash == destHash)
        #expect(decoded.payload == payload)
    }

    @Test("Context flag roundtrip")
    func testContextFlagRoundtrip() {
        let destHash = Data(repeating: 0x22, count: 16)
        let packet = TransportPacket(
            contextFlag: true,
            destinationHash: destHash,
            context: 0x09,
            payload: Data([0xFF])
        )

        let serialized = packet.serialize()
        let decoded = TransportPacket.deserialize(serialized)!

        #expect(decoded.contextFlag == true)
        #expect(decoded.context == 0x09)
        #expect(decoded.payload == Data([0xFF]))
    }

    @Test("Empty payload roundtrip")
    func testEmptyPayloadRoundtrip() {
        let destHash = Data(repeating: 0x33, count: 16)
        let packet = TransportPacket(destinationHash: destHash, payload: Data())

        let serialized = packet.serialize()
        let decoded = TransportPacket.deserialize(serialized)!

        #expect(decoded.payload.isEmpty)
    }

    @Test("Truncated data returns nil")
    func testTruncatedReturnsNil() {
        let short = Data([0x00, 0x01])
        #expect(TransportPacket.deserialize(short) == nil)
    }

    @Test("Packet hash excludes transport headers")
    func testPacketHashDeterministic() {
        let destHash = Data(repeating: 0x44, count: 16)
        let packet = TransportPacket(
            hops: 0,
            destinationHash: destHash,
            payload: Data("test".utf8)
        )
        let hash1 = packet.packetHash
        let hash2 = packet.packetHash
        #expect(hash1 == hash2)
        #expect(hash1.count == 16)
    }

    @Test("Max hops constant")
    func testMaxHops() {
        #expect(TransportPacket.maxHops == 128)
    }
}

@Suite("Announce Message Serialization")
struct AnnounceMessageTests {

    @Test("Announce message roundtrip")
    func testAnnounceMessageRoundtrip() {
        let destHash = Data(repeating: 0xAA, count: 16)
        let payload = Data("announce-payload".utf8)
        let msg = Message.announce(destinationHash: destHash, hops: 5, payload: payload)
        let decoded = Message.deserialize(msg.serialize())
        if case .announce(let dh, let h, let p) = decoded {
            #expect(dh == destHash)
            #expect(h == 5)
            #expect(p == payload)
        } else {
            Issue.record("Expected announce")
        }
    }

    @Test("PathRequest roundtrip")
    func testPathRequestRoundtrip() {
        let destHash = Data(repeating: 0xBB, count: 16)
        let msg = Message.pathRequest(destinationHash: destHash)
        let decoded = Message.deserialize(msg.serialize())
        if case .pathRequest(let dh) = decoded {
            #expect(dh == destHash)
        } else {
            Issue.record("Expected pathRequest")
        }
    }

    @Test("PathResponse roundtrip")
    func testPathResponseRoundtrip() {
        let destHash = Data(repeating: 0xCC, count: 16)
        let payload = Data([1, 2, 3])
        let msg = Message.pathResponse(destinationHash: destHash, hops: 3, announcePayload: payload)
        let decoded = Message.deserialize(msg.serialize())
        if case .pathResponse(let dh, let h, let p) = decoded {
            #expect(dh == destHash)
            #expect(h == 3)
            #expect(p == payload)
        } else {
            Issue.record("Expected pathResponse")
        }
    }

    @Test("TransportPacket message roundtrip")
    func testTransportPacketMessageRoundtrip() {
        let inner = TransportPacket(
            destinationHash: Data(repeating: 0xDD, count: 16),
            payload: Data("inner".utf8)
        ).serialize()
        let msg = Message.transportPacket(data: inner)
        let decoded = Message.deserialize(msg.serialize())
        if case .transportPacket(let data) = decoded {
            #expect(data == inner)
            let innerDecoded = TransportPacket.deserialize(data)
            #expect(innerDecoded != nil)
            #expect(innerDecoded?.payload == Data("inner".utf8))
        } else {
            Issue.record("Expected transportPacket")
        }
    }
}

@Suite("AnnouncePayload")
struct AnnouncePayloadTests {

    @Test("Payload serialization roundtrip")
    func testPayloadRoundtrip() {
        let payload = AnnouncePayload(
            publicKey: "pk_test_key_123",
            nameHash: Data(repeating: 0x01, count: 10),
            randomHash: AnnouncePayload.makeRandomHash(),
            signature: Data(repeating: 0xFF, count: 32),
            appData: Data("app-data".utf8)
        )

        let serialized = payload.serialize()
        let decoded = AnnouncePayload.deserialize(serialized)!

        #expect(decoded.publicKey == "pk_test_key_123")
        #expect(decoded.nameHash == payload.nameHash)
        #expect(decoded.randomHash == payload.randomHash)
        #expect(decoded.signature == payload.signature)
        #expect(decoded.appData == Data("app-data".utf8))
    }

    @Test("Payload without app data")
    func testPayloadNoAppData() {
        let payload = AnnouncePayload(
            publicKey: "pk",
            nameHash: Data(repeating: 0x02, count: 10),
            randomHash: AnnouncePayload.makeRandomHash(),
            signature: Data(repeating: 0xAA, count: 32),
            appData: nil
        )

        let serialized = payload.serialize()
        let decoded = AnnouncePayload.deserialize(serialized)!

        #expect(decoded.publicKey == "pk")
        #expect(decoded.appData == nil)
    }

    @Test("Random hash is 10 bytes")
    func testRandomHashLength() {
        let rh = AnnouncePayload.makeRandomHash()
        #expect(rh.count == 10)
    }

    @Test("Destination hash is deterministic")
    func testDestinationHashDeterministic() {
        let p1 = AnnouncePayload(
            publicKey: "key1",
            nameHash: Data(repeating: 0x03, count: 10),
            randomHash: Data(repeating: 0, count: 10),
            signature: Data()
        )
        let p2 = AnnouncePayload(
            publicKey: "key1",
            nameHash: Data(repeating: 0x03, count: 10),
            randomHash: Data(repeating: 0, count: 10),
            signature: Data()
        )
        #expect(p1.destinationHash == p2.destinationHash)
        #expect(p1.destinationHash.count == 16)
    }
}

@Suite("Transport Path Table")
struct TransportPathTableTests {

    @Test("Record and lookup path")
    func testRecordAndLookup() async {
        let localID = PeerID(publicKey: "local-transport-node")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        let peer = PeerID(publicKey: "peer-a")
        let destHash = Data(repeating: 0x01, count: 16)

        await transport.recordPath(
            destinationHash: destHash,
            from: peer,
            onInterface: "tcp0",
            hops: 2
        )

        let path = await transport.lookupPath(destHash)
        #expect(path != nil)
        #expect(path?.hops == 2)
        #expect(path?.receivedFrom == peer)
        #expect(path?.receivedOnInterface == "tcp0")
    }

    @Test("Shorter path replaces longer")
    func testShorterPathReplaces() async {
        let localID = PeerID(publicKey: "local-transport-2")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        let peerA = PeerID(publicKey: "peer-far")
        let peerB = PeerID(publicKey: "peer-close")
        let destHash = Data(repeating: 0x02, count: 16)

        await transport.recordPath(destinationHash: destHash, from: peerA, onInterface: "tcp0", hops: 5)
        await transport.recordPath(destinationHash: destHash, from: peerB, onInterface: "tcp0", hops: 2)

        let path = await transport.lookupPath(destHash)
        #expect(path?.receivedFrom == peerB)
        #expect(path?.hops == 2)
    }

    @Test("Longer path does not replace shorter")
    func testLongerPathNoReplace() async {
        let localID = PeerID(publicKey: "local-transport-3")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        let peerA = PeerID(publicKey: "peer-close-first")
        let peerB = PeerID(publicKey: "peer-far-second")
        let destHash = Data(repeating: 0x03, count: 16)

        await transport.recordPath(destinationHash: destHash, from: peerA, onInterface: "tcp0", hops: 2)
        await transport.recordPath(destinationHash: destHash, from: peerB, onInterface: "tcp0", hops: 5)

        let path = await transport.lookupPath(destHash)
        #expect(path?.receivedFrom == peerA)
    }

    @Test("Unknown destination returns nil")
    func testUnknownDestination() async {
        let localID = PeerID(publicKey: "local-transport-4")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally)

        let path = await transport.lookupPath(Data(repeating: 0xFF, count: 16))
        #expect(path == nil)
    }

    @Test("Path count")
    func testPathCount() async {
        let localID = PeerID(publicKey: "local-transport-5")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        for i in 0..<5 {
            let peer = PeerID(publicKey: "peer-\(i)")
            var destHash = Data(repeating: 0, count: 16)
            destHash[0] = UInt8(i)
            await transport.recordPath(destinationHash: destHash, from: peer, onInterface: "tcp0", hops: UInt8(i))
        }

        let count = await transport.pathCount
        #expect(count == 5)
    }
}

@Suite("Transport Packet Forwarding")
struct TransportForwardingTests {

    @Test("Transport node forwards announce")
    func testForwardAnnounce() async {
        let localID = PeerID(publicKey: "transport-node")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        let peer = PeerID(publicKey: "announce-source")
        let destHash = Data(repeating: 0xAA, count: 16)
        let packet = TransportPacket(
            packetType: .announce,
            hops: 2,
            destinationHash: destHash,
            payload: Data("announce".utf8)
        )

        let action = await transport.handleInboundPacket(packet, from: peer, onInterface: "tcp0")

        if case .forwardOnAllExcept(let excludeIface, let forwarded) = action {
            #expect(excludeIface == "tcp0")
            #expect(forwarded.hops == 3)
            #expect(forwarded.destinationHash == destHash)
        } else {
            Issue.record("Expected forwardOnAllExcept, got \(action)")
        }
    }

    @Test("Non-transport node delivers announce")
    func testNonTransportDeliversAnnounce() async {
        let localID = PeerID(publicKey: "endpoint-node")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: false)

        let peer = PeerID(publicKey: "announce-source-2")
        let destHash = Data(repeating: 0xBB, count: 16)
        let packet = TransportPacket(
            packetType: .announce,
            hops: 1,
            destinationHash: destHash,
            payload: Data("announce-2".utf8)
        )

        let action = await transport.handleInboundPacket(packet, from: peer, onInterface: "tcp0")

        if case .deliver(let delivered) = action {
            #expect(delivered.destinationHash == destHash)
        } else {
            Issue.record("Expected deliver, got \(action)")
        }
    }

    @Test("Max hops announce is dropped")
    func testMaxHopsDropped() async {
        let localID = PeerID(publicKey: "transport-max-hops")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        let peer = PeerID(publicKey: "far-peer")
        let destHash = Data(repeating: 0xCC, count: 16)
        let packet = TransportPacket(
            packetType: .announce,
            hops: 128,
            destinationHash: destHash,
            payload: Data("max-hops".utf8)
        )

        let action = await transport.handleInboundPacket(packet, from: peer, onInterface: "tcp0")
        if case .drop = action {
        } else {
            Issue.record("Expected drop for max hops, got \(action)")
        }
    }

    @Test("Duplicate announce is dropped")
    func testDuplicateAnnounceDrop() async {
        let localID = PeerID(publicKey: "transport-dedup")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        let peer = PeerID(publicKey: "dup-source")
        let destHash = Data(repeating: 0xDD, count: 16)
        let packet = TransportPacket(
            packetType: .announce,
            hops: 1,
            destinationHash: destHash,
            payload: Data("dup-announce".utf8)
        )

        let action1 = await transport.handleInboundPacket(packet, from: peer, onInterface: "tcp0")
        let action2 = await transport.handleInboundPacket(packet, from: peer, onInterface: "tcp0")

        if case .forwardOnAllExcept = action1 {} else {
            Issue.record("First should forward")
        }
        if case .drop = action2 {} else {
            Issue.record("Second should be dropped as duplicate")
        }
    }

    @Test("Data packet forwarded via known path")
    func testDataForwardedViaPath() async {
        let localID = PeerID(publicKey: "transport-forward")
        let tally = Tally(config: .default)
        let transport = Transport(localID: localID, tally: tally, enableTransport: true)

        let nextHop = PeerID(publicKey: "next-hop-peer")
        let destHash = Data(repeating: 0xEE, count: 16)

        await transport.recordPath(
            destinationHash: destHash,
            from: nextHop,
            onInterface: "tcp0",
            hops: 1
        )

        let sender = PeerID(publicKey: "data-sender")
        let packet = TransportPacket(
            propagationType: .broadcast,
            destinationType: .single,
            packetType: .data,
            hops: 0,
            destinationHash: destHash,
            payload: Data("routed-data".utf8)
        )

        let action = await transport.handleInboundPacket(packet, from: sender, onInterface: "tcp0")

        if case .forwardTo(let peer, _, let forwarded) = action {
            #expect(peer == nextHop)
            #expect(forwarded.hops == 1)
        } else {
            Issue.record("Expected forwardTo, got \(action)")
        }
    }
}

@Suite("AnnounceService")
struct AnnounceServiceTests {

    @Test("Process and retrieve announce")
    func testProcessAndRetrieve() async {
        let localID = PeerID(publicKey: "announce-service-node")
        let tally = Tally(config: .default)
        let service = AnnounceService(localID: localID, tally: tally)

        let destHash = Data(repeating: 0x11, count: 16)
        let payload = AnnouncePayload(
            publicKey: "announced-peer",
            nameHash: Data(repeating: 0x01, count: 10),
            randomHash: AnnouncePayload.makeRandomHash(),
            signature: Data(repeating: 0xAB, count: 32)
        )

        let packet = TransportPacket(
            packetType: .announce,
            hops: 2,
            destinationHash: destHash,
            payload: payload.serialize()
        )

        let peer = PeerID(publicKey: "relay-peer")
        let accepted = await service.processAnnounce(packet, from: peer, hops: 2)
        #expect(accepted == true)

        let dest = await service.knownDestination(for: destHash)
        #expect(dest != nil)
        #expect(dest?.publicKey == "announced-peer")
        #expect(dest?.hops == 2)
    }

    @Test("Duplicate announce rejected")
    func testDuplicateRejected() async {
        let localID = PeerID(publicKey: "announce-dedup-node")
        let tally = Tally(config: .default)
        let service = AnnounceService(localID: localID, tally: tally)

        let randomHash = AnnouncePayload.makeRandomHash()
        let destHash = Data(repeating: 0x22, count: 16)
        let payload = AnnouncePayload(
            publicKey: "dup-peer",
            nameHash: Data(repeating: 0x02, count: 10),
            randomHash: randomHash,
            signature: Data(repeating: 0xBB, count: 32)
        )

        let packet = TransportPacket(
            packetType: .announce,
            hops: 1,
            destinationHash: destHash,
            payload: payload.serialize()
        )

        let peer = PeerID(publicKey: "source-peer")
        let first = await service.processAnnounce(packet, from: peer, hops: 1)
        let second = await service.processAnnounce(packet, from: peer, hops: 1)
        #expect(first == true)
        #expect(second == false)
    }

    @Test("Create announce packet")
    func testCreateAnnounce() async {
        let localID = PeerID(publicKey: "creating-node")
        let tally = Tally(config: .default)
        let service = AnnounceService(localID: localID, tally: tally)

        let packet = await service.createAnnounce(
            publicKey: "my-key",
            name: "ivy.test",
            signingKey: Data("secret".utf8),
            appData: Data("meta".utf8)
        )

        #expect(packet.packetType == .announce)
        #expect(packet.hops == 0)
        #expect(packet.destinationHash.count == 16)
        #expect(!packet.payload.isEmpty)

        let decoded = AnnouncePayload.deserialize(packet.payload)
        #expect(decoded != nil)
        #expect(decoded?.publicKey == "my-key")
        #expect(decoded?.appData == Data("meta".utf8))
    }

    @Test("Destination count tracks announces")
    func testDestinationCount() async {
        let localID = PeerID(publicKey: "count-node")
        let tally = Tally(config: .default)
        let service = AnnounceService(localID: localID, tally: tally)

        for i in 0..<3 {
            var destHash = Data(repeating: 0, count: 16)
            destHash[0] = UInt8(i)
            let payload = AnnouncePayload(
                publicKey: "peer-\(i)",
                nameHash: Data(repeating: UInt8(i), count: 10),
                randomHash: AnnouncePayload.makeRandomHash(),
                signature: Data(repeating: 0xCC, count: 32)
            )
            let packet = TransportPacket(
                packetType: .announce,
                hops: 1,
                destinationHash: destHash,
                payload: payload.serialize()
            )
            let peer = PeerID(publicKey: "source-\(i)")
            _ = await service.processAnnounce(packet, from: peer, hops: 1)
        }

        let count = await service.destinationCount
        #expect(count == 3)
    }
}

@Suite("Router Hash Extensions")
struct RouterHashExtensionTests {

    @Test("Data hash is deterministic")
    func testDataHashDeterministic() {
        let data = Data("hello".utf8)
        let h1 = Router.hash(data)
        let h2 = Router.hash(data)
        #expect(h1 == h2)
    }

    @Test("Truncated hash is 16 bytes")
    func testTruncatedHashLength() {
        let data = Data("test".utf8)
        let th = Router.truncatedHash(data)
        #expect(th.count == 16)
    }

    @Test("Destination hash combines name and identity")
    func testDestinationHash() {
        let idHash = Router.truncatedHash(Data("key1".utf8))
        let dh1 = Router.destinationHash(name: "app.service", identityHash: idHash)
        let dh2 = Router.destinationHash(name: "app.service", identityHash: idHash)
        #expect(dh1 == dh2)
        #expect(dh1.count == 16)

        let dh3 = Router.destinationHash(name: "app.other", identityHash: idHash)
        #expect(dh1 != dh3)
    }
}

@Suite("InterfaceMode")
struct InterfaceModeTests {

    @Test("All modes have expected raw values")
    func testModeValues() {
        #expect(InterfaceMode.full.rawValue == 0x01)
        #expect(InterfaceMode.pointToPoint.rawValue == 0x02)
        #expect(InterfaceMode.accessPoint.rawValue == 0x03)
        #expect(InterfaceMode.roaming.rawValue == 0x04)
        #expect(InterfaceMode.boundary.rawValue == 0x05)
        #expect(InterfaceMode.gateway.rawValue == 0x06)
    }
}
