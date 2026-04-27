import Testing
import Foundation
@testable import Ivy
@testable import Tally

/// Helper to create a minimal IvyConfig for testing
func testConfig(publicKey: String, port: UInt16 = 0) -> IvyConfig {
    IvyConfig(
        publicKey: publicKey,
        listenPort: port,
        bootstrapPeers: [],
        enableLocalDiscovery: false,
        healthConfig: PeerHealthConfig(keepaliveInterval: .seconds(999), staleTimeout: .seconds(999), maxMissedPongs: 99, enabled: false),
        enablePEX: false,
        replicationInterval: .seconds(999)
    )
}

/// Collects messages received by a delegate
final class MessageCollector: IvyDelegate, @unchecked Sendable {
    private var _messages: [(message: Message, from: PeerID)] = []

    func ivy(_ ivy: Ivy, didReceiveMessage message: Message, from peer: PeerID) {
        _messages.append((message: message, from: peer))
    }

    var allMessages: [(message: Message, from: PeerID)] { _messages }
}

@Suite("Protocol Integration")
struct ProtocolIntegrationTests {

    @Test("Pin announcement stored and discoverable")
    func testPinAnnouncementStored() async throws {
        let config = testConfig(publicKey: "node-a")
        let nodeA = Ivy(config: config)
        let peerBID = PeerID(publicKey: "node-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        // B publishes a pin announcement through A
        bSide.send(.pinAnnounce(rootCID: "QmRoot", selector: "/", publicKey: "pinner-z", expiry: UInt64(Date().timeIntervalSince1970) + 3600, signature: Data(), fee: 5))
        try await Task.sleep(for: .milliseconds(100))

        let stored = await nodeA.storedPinAnnouncements(for: "QmRoot")
        #expect(stored.count == 1)
        #expect(stored[0].publicKey == "pinner-z")
        #expect(stored[0].selector == "/")
        bSide.close()
    }

    @Test("Peer message delivered to delegate")
    func testPeerMessageDelivered() async throws {
        let config = testConfig(publicKey: "node-a")
        let nodeA = Ivy(config: config)
        let collector = MessageCollector()
        await nodeA.setDelegate(collector)

        let peerBID = PeerID(publicKey: "node-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let payload = Data("new block header".utf8)
        bSide.send(.peerMessage(topic: "newBlock", payload: payload))
        try await Task.sleep(for: .milliseconds(100))

        let peerMsgs = collector.allMessages.compactMap { entry -> String? in
            if case .peerMessage(let topic, _) = entry.message { return topic }
            return nil
        }
        #expect(peerMsgs.contains("newBlock"))
        bSide.close()
    }
}

// Helper extension to set delegate/dataSource from async context
extension Ivy {
    func setDelegate(_ delegate: IvyDelegate?) {
        self.delegate = delegate
    }

    func setDataSource(_ dataSource: IvyDataSource?) {
        self.dataSource = dataSource
    }
}

/// Dict-backed data source for tests
final class DictDataSource: IvyDataSource, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    subscript(cid: String) -> Data? {
        get { lock.withLock { storage[cid] } }
        set { lock.withLock { storage[cid] = newValue } }
    }

    func data(for cid: String) async -> Data? {
        lock.withLock { storage[cid] }
    }

    func volumeData(for rootCID: String, cids: [String]) async -> [(cid: String, data: Data)] {
        lock.withLock {
            cids.compactMap { cid in
                if let d = storage[cid] { return (cid: cid, data: d) }
                return nil
            }
        }
    }
}
