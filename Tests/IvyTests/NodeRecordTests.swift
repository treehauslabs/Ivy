import Testing
import Foundation
import Crypto
@testable import Ivy
@testable import Tally

@Suite("NodeRecord")
struct NodeRecordTests {

    private func generateKeyPair() -> (publicKey: String, privateKey: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return (pubHex, privateKey.rawRepresentation)
    }

    @Test("Create and verify roundtrip")
    func testCreateAndVerify() {
        let (pub, priv) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signingKey: priv)
        #expect(record != nil)
        #expect(record!.verify())
        #expect(record!.publicKey == pub)
        #expect(record!.host == "1.2.3.4")
        #expect(record!.port == 4001)
        #expect(record!.sequenceNumber == 1)
    }

    @Test("Verify rejects tampered host")
    func testTamperedHost() {
        let (pub, priv) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signingKey: priv)!
        let tampered = NodeRecord(publicKey: pub, host: "5.6.7.8", port: 4001, sequenceNumber: 1, signature: record.signature)
        #expect(!tampered.verify())
    }

    @Test("Verify rejects tampered port")
    func testTamperedPort() {
        let (pub, priv) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signingKey: priv)!
        let tampered = NodeRecord(publicKey: pub, host: "1.2.3.4", port: 9999, sequenceNumber: 1, signature: record.signature)
        #expect(!tampered.verify())
    }

    @Test("Verify rejects tampered sequence number")
    func testTamperedSeq() {
        let (pub, priv) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signingKey: priv)!
        let tampered = NodeRecord(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 2, signature: record.signature)
        #expect(!tampered.verify())
    }

    @Test("Verify rejects wrong public key")
    func testWrongPublicKey() {
        let (pub, priv) = generateKeyPair()
        let (otherPub, _) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signingKey: priv)!
        let tampered = NodeRecord(publicKey: otherPub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signature: record.signature)
        #expect(!tampered.verify())
    }

    @Test("Create fails with invalid signing key")
    func testInvalidSigningKey() {
        let (pub, _) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signingKey: Data([0, 1, 2]))
        #expect(record == nil)
    }

    @Test("Serialize and deserialize roundtrip")
    func testSerializeRoundtrip() {
        let (pub, priv) = generateKeyPair()
        let original = NodeRecord.create(publicKey: pub, host: "192.168.1.100", port: 8080, sequenceNumber: 42, signingKey: priv)!
        let data = original.serialize()
        var reader = DataReader(data)
        let decoded = NodeRecord.deserialize(&reader)
        #expect(decoded != nil)
        #expect(decoded! == original)
        #expect(decoded!.verify())
    }

    @Test("Record fits within max size")
    func testMaxSize() {
        let (pub, priv) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "255.255.255.255", port: 65535, sequenceNumber: UInt64.max, signingKey: priv)!
        let data = record.serialize()
        #expect(data.count <= NodeRecord.maxSize)
    }

    @Test("Higher sequence number supersedes lower")
    func testSequenceOrdering() {
        let (pub, priv) = generateKeyPair()
        let old = NodeRecord.create(publicKey: pub, host: "1.2.3.4", port: 4001, sequenceNumber: 1, signingKey: priv)!
        let new = NodeRecord.create(publicKey: pub, host: "5.6.7.8", port: 4002, sequenceNumber: 2, signingKey: priv)!
        #expect(new.sequenceNumber > old.sequenceNumber)
        #expect(old.verify())
        #expect(new.verify())
        #expect(new.host == "5.6.7.8")
    }
}

@Suite("NodeRecord Messages")
struct NodeRecordMessageTests {

    private func generateKeyPair() -> (publicKey: String, privateKey: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return (pubHex, privateKey.rawRepresentation)
    }

    @Test("nodeRecord message roundtrip")
    func testNodeRecordMessageRoundtrip() {
        let (pub, priv) = generateKeyPair()
        let record = NodeRecord.create(publicKey: pub, host: "10.0.0.1", port: 4001, sequenceNumber: 7, signingKey: priv)!
        let msg = Message.nodeRecord(record: record)
        let decoded = Message.deserialize(msg.serialize())
        if case .nodeRecord(let r) = decoded {
            #expect(r == record)
            #expect(r.verify())
        } else {
            Issue.record("Expected nodeRecord")
        }
    }

    @Test("getNodeRecord message roundtrip")
    func testGetNodeRecordRoundtrip() {
        let msg = Message.getNodeRecord(publicKey: "abc123")
        let decoded = Message.deserialize(msg.serialize())
        if case .getNodeRecord(let pk) = decoded {
            #expect(pk == "abc123")
        } else {
            Issue.record("Expected getNodeRecord")
        }
    }
}

@Suite("NodeRecord Protocol Integration")
struct NodeRecordProtocolTests {

    private func generateKeyPair() -> (publicKey: String, privateKey: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return (pubHex, privateKey.rawRepresentation)
    }

    private func makeConfig(pub: String, priv: Data) -> IvyConfig {
        IvyConfig(
            publicKey: pub,
            listenPort: 0,
            enableLocalDiscovery: false,
            healthConfig: PeerHealthConfig(keepaliveInterval: .seconds(999), staleTimeout: .seconds(999), maxMissedPongs: 99, enabled: false),
            enablePEX: false,
            replicationInterval: .seconds(999),
            signingKey: priv
        )
    }

    @Test("Record accepted and cached from peer")
    func testRecordAcceptedFromPeer() async throws {
        let (pubA, privA) = generateKeyPair()
        let nodeA = Ivy(config: makeConfig(pub: pubA, priv: privA))
        let (pubB, privB) = generateKeyPair()
        let peerBID = PeerID(publicKey: pubB)
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let record = NodeRecord.create(publicKey: pubB, host: "10.0.0.1", port: 4001, sequenceNumber: 1, signingKey: privB)!
        bSide.send(Message.nodeRecord(record: record))
        try await Task.sleep(for: .milliseconds(100))

        let cached = await nodeA.nodeRecord(for: pubB)
        #expect(cached != nil)
        #expect(cached! == record)
        bSide.close()
    }

    @Test("Replay with equal seq rejected")
    func testReplayEqualSeqRejected() async throws {
        let (pubA, privA) = generateKeyPair()
        let nodeA = Ivy(config: makeConfig(pub: pubA, priv: privA))
        let (pubB, privB) = generateKeyPair()
        let peerBID = PeerID(publicKey: pubB)
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let record1 = NodeRecord.create(publicKey: pubB, host: "10.0.0.1", port: 4001, sequenceNumber: 5, signingKey: privB)!
        bSide.send(Message.nodeRecord(record: record1))
        try await Task.sleep(for: .milliseconds(50))

        let record2 = NodeRecord.create(publicKey: pubB, host: "99.99.99.99", port: 9999, sequenceNumber: 5, signingKey: privB)!
        bSide.send(Message.nodeRecord(record: record2))
        try await Task.sleep(for: .milliseconds(50))

        let cached = await nodeA.nodeRecord(for: pubB)
        #expect(cached!.host == "10.0.0.1")
        bSide.close()
    }

    @Test("Replay with lower seq rejected")
    func testReplayLowerSeqRejected() async throws {
        let (pubA, privA) = generateKeyPair()
        let nodeA = Ivy(config: makeConfig(pub: pubA, priv: privA))
        let (pubB, privB) = generateKeyPair()
        let peerBID = PeerID(publicKey: pubB)
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let newer = NodeRecord.create(publicKey: pubB, host: "10.0.0.1", port: 4001, sequenceNumber: 10, signingKey: privB)!
        bSide.send(Message.nodeRecord(record: newer))
        try await Task.sleep(for: .milliseconds(50))

        let older = NodeRecord.create(publicKey: pubB, host: "99.99.99.99", port: 9999, sequenceNumber: 3, signingKey: privB)!
        bSide.send(Message.nodeRecord(record: older))
        try await Task.sleep(for: .milliseconds(50))

        let cached = await nodeA.nodeRecord(for: pubB)
        #expect(cached!.host == "10.0.0.1")
        #expect(cached!.sequenceNumber == 10)
        bSide.close()
    }

    @Test("Higher seq supersedes cached record")
    func testHigherSeqSupersedes() async throws {
        let (pubA, privA) = generateKeyPair()
        let nodeA = Ivy(config: makeConfig(pub: pubA, priv: privA))
        let (pubB, privB) = generateKeyPair()
        let peerBID = PeerID(publicKey: pubB)
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let old = NodeRecord.create(publicKey: pubB, host: "10.0.0.1", port: 4001, sequenceNumber: 1, signingKey: privB)!
        bSide.send(Message.nodeRecord(record: old))
        try await Task.sleep(for: .milliseconds(50))

        let updated = NodeRecord.create(publicKey: pubB, host: "10.0.0.2", port: 4002, sequenceNumber: 2, signingKey: privB)!
        bSide.send(Message.nodeRecord(record: updated))
        try await Task.sleep(for: .milliseconds(50))

        let cached = await nodeA.nodeRecord(for: pubB)
        #expect(cached!.host == "10.0.0.2")
        #expect(cached!.port == 4002)
        #expect(cached!.sequenceNumber == 2)
        bSide.close()
    }

    @Test("Invalid signature rejected silently")
    func testInvalidSignatureRejected() async throws {
        let (pubA, privA) = generateKeyPair()
        let nodeA = Ivy(config: makeConfig(pub: pubA, priv: privA))
        let (pubB, _) = generateKeyPair()
        let peerBID = PeerID(publicKey: pubB)
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let forged = NodeRecord(publicKey: pubB, host: "evil.com", port: 666, sequenceNumber: 1, signature: Data(repeating: 0xFF, count: 64))
        bSide.send(Message.nodeRecord(record: forged))
        try await Task.sleep(for: .milliseconds(100))

        let cached = await nodeA.nodeRecord(for: pubB)
        #expect(cached == nil)
        bSide.close()
    }

    @Test("getNodeRecord serves cached record")
    func testGetNodeRecordServesCached() async throws {
        let (pubA, privA) = generateKeyPair()
        let nodeA = Ivy(config: makeConfig(pub: pubA, priv: privA))
        let (pubB, privB) = generateKeyPair()
        let (pubC, privC) = generateKeyPair()
        let peerBID = PeerID(publicKey: pubB)
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let recordC = NodeRecord.create(publicKey: pubC, host: "10.0.0.3", port: 4003, sequenceNumber: 1, signingKey: privC)!
        bSide.send(Message.nodeRecord(record: recordC))
        try await Task.sleep(for: .milliseconds(50))

        bSide.send(Message.getNodeRecord(publicKey: pubC))
        try await Task.sleep(for: .milliseconds(100))

        var receivedRecord: NodeRecord?
        for await msg in bSide.messages {
            if case .nodeRecord(let r) = msg {
                receivedRecord = r
                break
            }
        }
        #expect(receivedRecord != nil)
        #expect(receivedRecord! == recordC)
        bSide.close()
    }

    @Test("No public address means no local record")
    func testNoPublicAddressNoRecord() async {
        let (pub, priv) = generateKeyPair()
        let ivy = Ivy(config: makeConfig(pub: pub, priv: priv))
        await ivy.updateNodeRecord()
        let local = await ivy.nodeRecord(for: pub)
        #expect(local == nil)
    }
}
