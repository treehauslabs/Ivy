import Testing
import Foundation
@testable import Ivy
@testable import Tally

private func routingConfig(
    publicKey: String,
    minPeerKeyBits: Int = 0,
    tallyConfig: TallyConfig = .default
) -> IvyConfig {
    IvyConfig(
        publicKey: publicKey,
        listenPort: 0,
        bootstrapPeers: [],
        enableLocalDiscovery: false,
        tallyConfig: tallyConfig,
        healthConfig: PeerHealthConfig(
            keepaliveInterval: .seconds(999),
            staleTimeout: .seconds(999),
            maxMissedPongs: 99,
            enabled: false
        ),
        enablePEX: false,
        replicationInterval: .seconds(999),
        minPeerKeyBits: minPeerKeyBits
    )
}

private func keyWithDifficulty(atLeast target: Int) -> String {
    for i in 0..<10_000 {
        let key = "routing-valid-\(target)-\(i)"
        if KeyDifficulty.trailingZeroBits(of: key) >= target {
            return key
        }
    }
    fatalError("Unable to find key with target difficulty \(target)")
}

private func keyWithDifficulty(lessThan target: Int) -> String {
    for i in 0..<10_000 {
        let key = "routing-invalid-\(target)-\(i)"
        if KeyDifficulty.trailingZeroBits(of: key) < target {
            return key
        }
    }
    fatalError("Unable to find key below target difficulty \(target)")
}

private func nextMessage(
    from conn: LocalPeerConnection,
    after send: () -> Void,
    wait: Duration = .milliseconds(150)
) async throws -> Message? {
    let task = Task<Message?, Never> {
        var iterator = conn.messages.makeAsyncIterator()
        return await iterator.next()
    }
    send()
    try await Task.sleep(for: wait)
    task.cancel()
    return await task.value
}

@Suite("Routing ingress hardening")
struct RoutingIngressHardeningTests {

    @Test("Neighbors only inserts endpoints that pass routing identity and address validation")
    func neighborsRejectInvalidDiscoveredEndpoints() async throws {
        let requiredBits = 2
        let node = Ivy(config: routingConfig(publicKey: "routing-node", minPeerKeyBits: requiredBits))
        let localID = await node.localID
        let peerID = PeerID(publicKey: "routing-neighbor-sender")
        let (peerSide, nodeSide) = LocalPeerConnection.pair(localID: peerID, remoteID: localID)
        await node.registerLocalPeer(nodeSide, as: peerID)

        let badKey = keyWithDifficulty(lessThan: requiredBits)
        let goodKey = keyWithDifficulty(atLeast: requiredBits)

        peerSide.send(.neighbors([
            PeerEndpoint(publicKey: badKey, host: "10.0.0.1", port: 4001),
            PeerEndpoint(publicKey: goodKey, host: "10.0.0.2", port: 4001),
            PeerEndpoint(publicKey: keyWithDifficulty(atLeast: requiredBits), host: "0.0.0.0", port: 4001),
            PeerEndpoint(publicKey: keyWithDifficulty(atLeast: requiredBits), host: "10.0.0.3", port: 0)
        ]))
        try await Task.sleep(for: .milliseconds(100))

        let routedKeys = await Set(node.allRouterPeers().map { $0.id.publicKey })
        #expect(!routedKeys.contains(badKey))
        #expect(routedKeys.contains(goodKey))
        #expect(routedKeys.count == 1)

        peerSide.close()
    }

    @Test("Unsolicited PEX responses do not mutate routing table or earn success")
    func unsolicitedPEXResponseIsIgnored() async throws {
        let node = Ivy(config: routingConfig(publicKey: "routing-pex-node"))
        let localID = await node.localID
        let peerID = PeerID(publicKey: "routing-pex-sender")
        let (peerSide, nodeSide) = LocalPeerConnection.pair(localID: peerID, remoteID: localID)
        await node.registerLocalPeer(nodeSide, as: peerID)

        let tally = await node.tally
        tally.recordReceived(peer: peerID, bytes: 1)
        let advertised = PeerEndpoint(publicKey: "routing-pex-poison", host: "10.1.0.1", port: 4001)

        peerSide.send(.pexResponse(nonce: 0xfeed, peers: [advertised]))
        try await Task.sleep(for: .milliseconds(100))

        let routedKeys = await Set(node.allRouterPeers().map { $0.id.publicKey })
        #expect(!routedKeys.contains(advertised.publicKey))
        #expect(tally.peerLedger(for: peerID)?.successCount == 0)

        peerSide.close()
    }

    @Test("Solicited PEX with invalid endpoints is not rewarded")
    func solicitedInvalidPEXResponseIsNotRewarded() async throws {
        let requiredBits = 2
        let node = Ivy(config: routingConfig(publicKey: "routing-pex-invalid-node", minPeerKeyBits: requiredBits))
        let localID = await node.localID
        let peerID = PeerID(publicKey: "routing-pex-invalid-sender")
        let (peerSide, nodeSide) = LocalPeerConnection.pair(localID: peerID, remoteID: localID)
        await node.registerLocalPeer(nodeSide, as: peerID)

        let tally = await node.tally
        tally.recordReceived(peer: peerID, bytes: 1)
        let invalid = PeerEndpoint(
            publicKey: keyWithDifficulty(lessThan: requiredBits),
            host: "10.1.0.2",
            port: 4001
        )

        let discovered = await node.receivePEXResponseForTesting(
            nonce: 0xbeef,
            peers: [invalid],
            from: peerID
        )

        #expect(discovered.isEmpty)
        let ledger = tally.peerLedger(for: peerID)
        #expect(ledger?.successCount == 0)
        #expect(ledger?.failureCount == 1)

        peerSide.close()
    }

    @Test("findNode handler is gated by Tally before enumerating routing table")
    func findNodeIsGatedBeforeReplyingWithNeighbors() async throws {
        let tallyConfig = TallyConfig(rateLimitBytesPerSecond: 1)
        let node = Ivy(config: routingConfig(publicKey: "routing-find-node", tallyConfig: tallyConfig))
        let localID = await node.localID
        let peerID = PeerID(publicKey: "routing-find-node-sender")
        let (peerSide, nodeSide) = LocalPeerConnection.pair(localID: peerID, remoteID: localID)
        await node.registerLocalPeer(nodeSide, as: peerID)
        await node.addToRouter(
            PeerID(publicKey: "routing-table-entry"),
            endpoint: PeerEndpoint(publicKey: "routing-table-entry", host: "10.2.0.1", port: 4001)
        )

        let tally = await node.tally
        tally.recordSent(peer: PeerID(publicKey: "pressure-source"), bytes: 1_000)

        let response = try await nextMessage(from: peerSide) {
            peerSide.send(.findNode(target: Data("target".utf8)))
        }

        #expect(response == nil)

        peerSide.close()
    }
}
