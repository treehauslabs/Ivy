import Testing
import Foundation
@testable import Ivy
import Acorn
import Tally
import Crypto

/// Real TCP integration tests: two Ivy nodes on localhost, actual NIO sockets.
/// These tests verify what unit tests can't: wire protocol, connection handshake,
/// message framing, and end-to-end data flow over real network connections.

private nonisolated(unsafe) var _nextPort: UInt16 = 29100
private func nextPort() -> UInt16 { _nextPort += 1; return _nextPort }

private func generateKey() -> (publicKey: String, privateKey: String) {
    let key = P256.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    let priv = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    return (pub, priv)
}

private func makeConfig(port: UInt16, publicKey: String, bootstrapPeers: [PeerEndpoint] = []) -> IvyConfig {
    IvyConfig(
        publicKey: publicKey,
        listenPort: port,
        bootstrapPeers: bootstrapPeers,
        enableLocalDiscovery: false,
        stunServers: [],
        enablePEX: false
    )
}

@Suite("TCP Integration")
struct TCPIntegrationTests {

    @Test("Two nodes connect over real TCP")
    func testTwoNodesConnect() async throws {
        let kp1 = generateKey()
        let kp2 = generateKey()
        let p1 = nextPort(); let p2 = nextPort()

        let ivy1 = Ivy(config: makeConfig(port: p1, publicKey: kp1.publicKey))
        let ivy2 = Ivy(config: makeConfig(port: p2, publicKey: kp2.publicKey))

        try await ivy1.start()
        try await ivy2.start()

        // Node 2 connects to Node 1
        try await ivy2.connect(to: PeerEndpoint(
            publicKey: kp1.publicKey, host: "127.0.0.1", port: p1
        ))

        // Wait for connection to establish
        try await Task.sleep(for: .milliseconds(500))

        let peers1 = await ivy1.directPeerCount
        let peers2 = await ivy2.directPeerCount

        // ivy2 connected to ivy1 outbound; ivy1 accepted inbound
        #expect(peers2 >= 1, "Node 2 should have at least 1 peer")

        await ivy1.stop()
        await ivy2.stop()
    }

    @Test("Block announcement propagates over TCP")
    func testBlockAnnouncementOverTCP() async throws {
        let kp1 = generateKey()
        let kp2 = generateKey()
        let p1 = nextPort(); let p2 = nextPort()

        let ivy1 = Ivy(config: makeConfig(port: p1, publicKey: kp1.publicKey))
        let ivy2 = Ivy(config: makeConfig(port: p2, publicKey: kp2.publicKey))

        let collector = AnnouncementCollector()
        await ivy2.setDelegate(collector)

        try await ivy1.start()
        try await ivy2.start()

        try await ivy2.connect(to: PeerEndpoint(
            publicKey: kp1.publicKey, host: "127.0.0.1", port: p1
        ))
        try await Task.sleep(for: .milliseconds(500))

        // Node 1 announces a block
        await ivy1.announceBlock(cid: "test-block-cid-123")
        try await Task.sleep(for: .milliseconds(500))

        let announcements = await collector.announcements
        #expect(announcements.contains("test-block-cid-123"), "Block announcement should reach Node 2")

        await ivy1.stop()
        await ivy2.stop()
    }

    @Test("Direct block send over TCP")
    func testDirectBlockSendOverTCP() async throws {
        let kp1 = generateKey()
        let kp2 = generateKey()
        let p1 = nextPort(); let p2 = nextPort()

        let ivy1 = Ivy(config: makeConfig(port: p1, publicKey: kp1.publicKey))
        let ivy2 = Ivy(config: makeConfig(port: p2, publicKey: kp2.publicKey))

        let collector = BlockCollector()
        await ivy2.setDelegate(collector)

        try await ivy1.start()
        try await ivy2.start()

        try await ivy2.connect(to: PeerEndpoint(
            publicKey: kp1.publicKey, host: "127.0.0.1", port: p1
        ))
        try await Task.sleep(for: .milliseconds(500))

        // Send block data directly to the connected peer
        let testData = Data("hello-block-data".utf8)
        let peer2 = PeerID(publicKey: kp2.publicKey)
        await ivy1.fireToPeer(peer2, .block(cid: "block-with-data", data: testData))
        try await Task.sleep(for: .seconds(1))

        let blocks = await collector.blocks
        #expect(blocks["block-with-data"] != nil, "Block data should reach Node 2")
        #expect(blocks["block-with-data"] == testData, "Block data should be intact")

        await ivy1.stop()
        await ivy2.stop()
    }

    @Test("Peer message (gossip) over TCP")
    func testPeerMessageOverTCP() async throws {
        let kp1 = generateKey()
        let kp2 = generateKey()
        let p1 = nextPort(); let p2 = nextPort()

        let ivy1 = Ivy(config: makeConfig(port: p1, publicKey: kp1.publicKey))
        let ivy2 = Ivy(config: makeConfig(port: p2, publicKey: kp2.publicKey))

        let collector = GossipCollector()
        await ivy2.setDelegate(collector)

        try await ivy1.start()
        try await ivy2.start()

        try await ivy2.connect(to: PeerEndpoint(
            publicKey: kp1.publicKey, host: "127.0.0.1", port: p1
        ))
        try await Task.sleep(for: .milliseconds(500))

        // Node 1 broadcasts a gossip message
        await ivy1.broadcastMessage(topic: "newBlock", payload: Data("block-cid-456".utf8))
        try await Task.sleep(for: .milliseconds(500))

        let messages = await collector.messages
        #expect(!messages.isEmpty, "Gossip message should reach Node 2")
        if let first = messages.first {
            #expect(first.topic == "newBlock")
            #expect(String(data: first.payload, encoding: .utf8) == "block-cid-456")
        }

        await ivy1.stop()
        await ivy2.stop()
    }

    @Test("Fee-based content retrieval over TCP")
    func testFeeRetrievalOverTCP() async throws {
        let kp1 = generateKey()
        let kp2 = generateKey()
        let p1 = nextPort(); let p2 = nextPort()

        let ivy1 = Ivy(config: makeConfig(port: p1, publicKey: kp1.publicKey))
        let ivy2 = Ivy(config: makeConfig(port: p2, publicKey: kp2.publicKey))

        // Store data on Node 1
        let testCID = "test-content-for-retrieval"
        let testData = Data("the-actual-content-bytes".utf8)
        await ivy1.publishBlock(cid: testCID, data: testData)

        try await ivy1.start()
        try await ivy2.start()

        try await ivy2.connect(to: PeerEndpoint(
            publicKey: kp1.publicKey, host: "127.0.0.1", port: p1
        ))
        // Wait for identify exchange to complete so routing table is populated
        try await Task.sleep(for: .seconds(2))

        // Node 2 requests content — targeted at Node 1 (one hop, no DHT walk needed)
        let target = PeerID(publicKey: kp1.publicKey)
        let retrieved = await ivy2.get(cid: testCID, target: target, fee: 20)

        #expect(retrieved != nil, "Should retrieve content from Node 1 via targeted request")
        if let retrieved {
            #expect(retrieved == testData, "Retrieved data should match original")
        }

        await ivy1.stop()
        await ivy2.stop()
    }
}

// MARK: - Test Helpers

private actor AnnouncementCollector: IvyDelegate {
    var announcements: [String] = []

    nonisolated func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        Task { await record(cid) }
    }
    func record(_ cid: String) { announcements.append(cid) }
}

private actor BlockCollector: IvyDelegate {
    var blocks: [String: Data] = [:]

    nonisolated func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        Task { await record(cid, data) }
    }
    func record(_ cid: String, _ data: Data) { blocks[cid] = data }
}

private actor GossipCollector: IvyDelegate {
    var messages: [(topic: String, payload: Data)] = []

    nonisolated func ivy(_ ivy: Ivy, didReceiveMessage message: Message, from peer: PeerID) {
        if case .peerMessage(let topic, let payload) = message {
            Task { await self.record(topic, payload) }
        }
    }
    func record(_ topic: String, _ payload: Data) { messages.append((topic, payload)) }
}

private extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
