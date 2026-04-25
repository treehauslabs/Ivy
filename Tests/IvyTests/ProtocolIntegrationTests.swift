import Testing
import Foundation
@testable import Ivy
import VolumeBroker
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
        replicationInterval: .seconds(999),
        zoneSyncInterval: .seconds(999)
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
        let nodeA = Ivy(config: config, broker: MemoryBroker())
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
        let nodeA = Ivy(config: config, broker: MemoryBroker())
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

// Helper extension to set delegate from async context
extension Ivy {
    func setDelegate(_ delegate: IvyDelegate?) {
        self.delegate = delegate
    }
}
