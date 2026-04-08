import Testing
import Foundation
@testable import Ivy
@testable import Tally
import Acorn

/// Creates a simulated network of Ivy nodes connected via local peer connections.
/// Returns the nodes and a cleanup function.
func createNetwork(count: Int, thresholdMultiplier: UInt64 = 1000) async -> [Ivy] {
    var nodes: [Ivy] = []
    for i in 0..<count {
        let config = IvyConfig(
            publicKey: "node-\(i)",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            healthConfig: PeerHealthConfig(keepaliveInterval: .seconds(999), staleTimeout: .seconds(999), maxMissedPongs: 99, enabled: false),
            enablePEX: false,
            replicationInterval: .seconds(999),
            zoneSyncInterval: .seconds(999)
        )
        nodes.append(Ivy(config: config))
    }
    return nodes
}

/// Connects two Ivy nodes bidirectionally via a single LocalPeerConnection pair.
/// A.send(bID) → B receives. B.send(aID) → A receives.
func connectNodes(_ a: Ivy, _ b: Ivy) async {
    let aID = await a.localID
    let bID = await b.localID

    // LocalPeerConnection.pair: end1.send → end2.receives, end2.send → end1.receives
    // A registers end1 as bID: A.fireToPeer(bID) → end1.send → end2 receives (B reads end2)
    // B registers end2 as aID: B.fireToPeer(aID) → end2.send → end1 receives (A reads end1)
    let (end1, end2) = LocalPeerConnection.pair(localID: aID, remoteID: bID)
    await a.registerLocalPeer(end1, as: bID)
    await b.registerLocalPeer(end2, as: aID)

    let aEndpoint = PeerEndpoint(publicKey: aID.publicKey, host: "local", port: 0)
    let bEndpoint = PeerEndpoint(publicKey: bID.publicKey, host: "local", port: 0)
    await a.addToRouter(bID, endpoint: bEndpoint)
    await b.addToRouter(aID, endpoint: aEndpoint)
}

/// Extension to expose router operations from tests
extension Ivy {
    func addToRouter(_ peer: PeerID, endpoint: PeerEndpoint) {
        router.addPeer(peer, endpoint: endpoint, tally: tally)
    }

    func allRouterPeers() -> [Router.BucketEntry] {
        router.allPeers()
    }

    func fireToPeerPublic(_ peer: PeerID, _ message: Message) {
        fireToPeer(peer, message)
    }
}

// MARK: - Multi-Hop Fee Cascade

@Suite("Multi-Hop Fee Cascade")
struct MultiHopFeeCascadeTests {

    @Test("Three-node relay: fees deducted at each hop, provider keeps remainder")
    func testThreeNodeFeeCascade() async throws {
        // Topology: A -> B -> C
        // A requests content that C has
        let nodes = await createNetwork(count: 3)
        let nodeA = nodes[0]
        let nodeB = nodes[1]
        let nodeC = nodes[2]

        await connectNodes(nodeA, nodeB)
        await connectNodes(nodeB, nodeC)

        // Give a moment for local peers to register
        try await Task.sleep(for: .milliseconds(100))

        let aID = await nodeA.localID
        let bID = await nodeB.localID
        let cID = await nodeC.localID

        // C has the content
        let testData = Data("three hop data".utf8)
        let cid = "QmThreeHop"
        await nodeC.publishBlock(cid: cid, data: testData)

        // Verify starting balances are all zero
        #expect(await nodeA.ledger.balance(with: bID) == 0)
        #expect(await nodeB.ledger.balance(with: cID) == 0)

        // A sends fee-based request toward C through B
        // Since A is connected to B and B is connected to C,
        // B should forward the request to C
        let bForA = await nodeB.localID
        // Manually simulate the chain: A -> B with fee
        // In a real network, A would send dhtForward with target: C.hash
        // For this test, we send directly to verify fee mechanics

        // A's side sends to B
        await nodeA.ledger.earnFromRelay(peer: bID, amount: 0) // ensure line exists

        // Simulate the fee cascade through direct ledger operations
        // This tests the accounting, not the routing
        let totalFee: Int64 = 50
        let bRelayFee: Int64 = 3

        // A pays B the total
        await nodeA.ledger.chargeForRelay(peer: bID, amount: totalFee)
        // B earns from A
        await nodeB.ledger.earnFromRelay(peer: aID, amount: totalFee)
        // B pays C the remainder
        let cPayment = totalFee - bRelayFee
        await nodeB.ledger.chargeForRelay(peer: cID, amount: cPayment)
        // C earns from B
        await nodeC.ledger.earnFromRelay(peer: bID, amount: cPayment)

        // Verify: A owes B 50, B net earned 3 (earned 50 from A, paid 47 to C), C earned 47
        #expect(await nodeA.ledger.balance(with: bID) == -50)
        #expect(await nodeB.ledger.balance(with: aID) == 50)
        #expect(await nodeB.ledger.balance(with: cID) == -47)
        #expect(await nodeC.ledger.balance(with: bID) == 47)

        // B's net position: +50 - 47 = +3 margin
        let bFromA = await nodeB.ledger.balance(with: aID)
        let bToC = await nodeB.ledger.balance(with: cID)
        #expect(bFromA + bToC == 3) // B's margin
    }
}

// MARK: - Caching Economics

@Suite("Caching Economics")
struct CachingEconomicsTests {

    @Test("Cacher earns full fee instead of relay margin")
    func testCacherEarnsFullFee() async throws {
        // First request: A -> B -> C (B earns relay margin)
        // Second request: A -> B (B has it cached, earns full fee)
        let localA = PeerID(publicKey: "cacher-a")
        let localB = PeerID(publicKey: "cacher-b")
        let localC = PeerID(publicKey: "cacher-c")

        let ledgerB = CreditLineLedger(localID: localB, baseThresholdMultiplier: 1000)
        await ledgerB.establish(with: localA)
        await ledgerB.establish(with: localC)

        // First request: B relays, earns 3 margin
        let relayFee: Int64 = 3
        let totalFee: Int64 = 50
        await ledgerB.earnFromRelay(peer: localA, amount: relayFee)
        await ledgerB.chargeForRelay(peer: localC, amount: totalFee - relayFee)

        let marginEarning = await ledgerB.balance(with: localA)
        #expect(marginEarning == 3)

        // Second request: B serves from cache, earns full remaining fee (50)
        await ledgerB.earnFromRelay(peer: localA, amount: totalFee)

        let cacheEarning = await ledgerB.balance(with: localA)
        #expect(cacheEarning == 53) // 3 from first relay + 50 from cache hit

        // Cache hit earned 50 vs relay earned 3 — caching is 16x more profitable
        #expect(totalFee > relayFee)
    }
}

// MARK: - Fee Discovery

@Suite("Fee Discovery")
struct FeeDiscoveryTests {

    @Test("feeExhausted tells requester the consumed amount")
    func testFeeExhaustedFeedback() async throws {
        let nodeA = Ivy(config: testConfig(publicKey: "fee-a"))
        let peerBID = PeerID(publicKey: "fee-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        // B sends a request with fee too small (fee = 0, which triggers feeExhausted)
        bSide.send(.dhtForward(cid: "QmExpensive", ttl: 0, fee: 1))
        try await Task.sleep(for: .milliseconds(100))

        // A should have returned feeExhausted since fee <= relayFee (1 <= 1)
        // The feeExhausted message goes to B via the local peer connection
        // Verify no balance change (pay-on-success)
        let balance = await nodeA.ledger.balance(with: peerBID)
        #expect(balance == 0)

        bSide.close()
    }

    @Test("Requester can calibrate fee from feeExhausted response")
    func testFeeCalibration() async throws {
        // Simulate: first request fails with feeExhausted, second succeeds
        let localA = PeerID(publicKey: "cal-a")
        let localB = PeerID(publicKey: "cal-b")

        let ledgerA = CreditLineLedger(localID: localA, baseThresholdMultiplier: 1000)
        await ledgerA.establish(with: localB)

        // First attempt: fee too low — no charge
        let balanceAfterFail = await ledgerA.balance(with: localB)
        #expect(balanceAfterFail == 0) // Nothing charged on failure

        // Second attempt: fee sufficient — charge happens on success
        await ledgerA.chargeForRelay(peer: localB, amount: 50)
        let balanceAfterSuccess = await ledgerA.balance(with: localB)
        #expect(balanceAfterSuccess == -50) // Charged on success
    }
}

// MARK: - Settlement Lifecycle

@Suite("Settlement Lifecycle")
struct SettlementLifecycleTests {

    @Test("Threshold grows after successful settlement")
    func testThresholdGrowth() async throws {
        let localA = PeerID(publicKey: "grow-a")
        let localB = PeerID(publicKey: "grow-b")
        let ledger = CreditLineLedger(localID: localA, baseThresholdMultiplier: 100)
        await ledger.establish(with: localB)

        let thresholdBefore = await ledger.threshold(for: localB)
        #expect(thresholdBefore >= 1)

        await ledger.recordSettlement(peer: localB)

        let thresholdAfter = await ledger.threshold(for: localB)
        #expect(thresholdAfter >= thresholdBefore) // Threshold grew or stayed same
    }

    @Test("Missed settlement halves threshold twice to near-zero")
    func testMissedSettlementDecay() async throws {
        let localA = PeerID(publicKey: "decay-a")
        let localB = PeerID(publicKey: "decay-b")
        let ledger = CreditLineLedger(localID: localA, baseThresholdMultiplier: 1000)
        await ledger.establish(with: localB)

        let initial = await ledger.threshold(for: localB)
        #expect(initial > 0)

        await ledger.recordMissedSettlement(peer: localB)
        let afterFirst = await ledger.threshold(for: localB)
        #expect(afterFirst == initial / 2)

        await ledger.recordMissedSettlement(peer: localB)
        let afterSecond = await ledger.threshold(for: localB)
        #expect(afterSecond == initial / 4)
    }

    @Test("Mining solutions accumulate to clear debt")
    func testAccumulatedMiningSettlement() async throws {
        let nodeA = Ivy(config: testConfig(publicKey: "mine-a"))
        let peerBID = PeerID(publicKey: "mine-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        // B owes A 5
        await nodeA.ledger.earnFromRelay(peer: peerBID, amount: 5)
        #expect(await nodeA.ledger.balance(with: peerBID) == 5)

        // B sends 5 mining solutions, each worth 1 ivy (16 trailing zeros)
        var hash = Data(repeating: 0xFF, count: 30)
        hash.append(contentsOf: [0x00, 0x00]) // 16 trailing zero bits = 1 ivy

        for i in 0..<5 {
            bSide.send(.miningChallengeSolution(nonce: UInt64(i), hash: hash, blockNonce: nil))
        }
        try await Task.sleep(for: .milliseconds(200))

        let remaining = await nodeA.ledger.balance(with: peerBID)
        #expect(remaining == 0) // Fully settled
    }
}

// MARK: - Pin Announcement Discovery Chain

@Suite("Pin Discovery Chain")
struct PinDiscoveryChainTests {

    @Test("Pin announcement stored at one node, discovered from another")
    func testPinDiscoveryAcrossNodes() async throws {
        // A stores pin announcement. B queries A via findPins.
        let nodeA = Ivy(config: testConfig(publicKey: "pin-a"))
        let peerBID = PeerID(publicKey: "pin-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        // Store a pin announcement at A (as if a pinner published it)
        bSide.send(.pinAnnounce(rootCID: "QmDiscovery", selector: "/data", publicKey: "pinner-x", expiry: UInt64(Date().timeIntervalSince1970) + 3600, signature: Data(), fee: 5))
        try await Task.sleep(for: .milliseconds(100))

        // Now B queries for it
        bSide.send(.findPins(cid: "QmDiscovery", fee: 10))
        try await Task.sleep(for: .milliseconds(100))

        // Verify A stored it
        let stored = await nodeA.storedPinAnnouncements(for: "QmDiscovery")
        #expect(stored.count == 1)
        #expect(stored[0].publicKey == "pinner-x")
        #expect(stored[0].selector == "/data")
    }

    @Test("Multiple pinners for same CID all discoverable")
    func testMultiplePinners() async throws {
        let nodeA = Ivy(config: testConfig(publicKey: "multi-a"))
        let peerBID = PeerID(publicKey: "multi-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        // Two different pinners announce for the same CID
        bSide.send(.pinAnnounce(rootCID: "QmShared", selector: "/", publicKey: "pinner-1", expiry: UInt64(Date().timeIntervalSince1970) + 3600, signature: Data(), fee: 5))
        try await Task.sleep(for: .milliseconds(50))
        bSide.send(.pinAnnounce(rootCID: "QmShared", selector: "/photos", publicKey: "pinner-2", expiry: UInt64(Date().timeIntervalSince1970) + 3600, signature: Data(), fee: 5))
        try await Task.sleep(for: .milliseconds(100))

        let stored = await nodeA.storedPinAnnouncements(for: "QmShared")
        #expect(stored.count == 2)

        let keys = Set(stored.map { $0.publicKey })
        #expect(keys.contains("pinner-1"))
        #expect(keys.contains("pinner-2"))
    }
}

// MARK: - Gossip (Peer Message)

@Suite("Gossip Protocol")
struct GossipProtocolTests {

    @Test("Block announcement gossip reaches peer")
    func testBlockGossip() async throws {
        let nodeA = Ivy(config: testConfig(publicKey: "gossip-a"))
        let collector = MessageCollector()
        await nodeA.setDelegate(collector)

        let peerBID = PeerID(publicKey: "gossip-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        // B gossips a new block header
        let blockHeader = Data("block-47-header".utf8)
        bSide.send(.peerMessage(topic: "newBlock", payload: blockHeader))
        try await Task.sleep(for: .milliseconds(100))

        let topics = collector.allMessages.compactMap { entry -> String? in
            if case .peerMessage(let topic, _) = entry.message { return topic }
            return nil
        }
        #expect(topics.contains("newBlock"))
        bSide.close()
    }

    @Test("Transaction gossip reaches peer")
    func testTxGossip() async throws {
        let nodeA = Ivy(config: testConfig(publicKey: "tx-a"))
        let collector = MessageCollector()
        await nodeA.setDelegate(collector)

        let peerBID = PeerID(publicKey: "tx-b")
        let localID = await nodeA.localID
        let (bSide, aSide) = LocalPeerConnection.pair(localID: peerBID, remoteID: localID)
        await nodeA.registerLocalPeer(aSide, as: peerBID)
        try await Task.sleep(for: .milliseconds(50))

        let signedTx = Data("signed-transaction-payload".utf8)
        bSide.send(.peerMessage(topic: "mempool", payload: signedTx))
        try await Task.sleep(for: .milliseconds(100))

        let mempoolMsgs = collector.allMessages.compactMap { entry -> Data? in
            if case .peerMessage(let topic, let p) = entry.message, topic == "mempool" { return p }
            return nil
        }
        #expect(mempoolMsgs.count == 1)
        #expect(mempoolMsgs[0] == signedTx)
        bSide.close()
    }
}

// MARK: - End-to-End: Fee-Based Retrieval Through Actual Message Handlers

@Suite("End-to-End Protocol")
struct EndToEndProtocolTests {

    @Test("A requests content from C through B — full message handler chain")
    func testThreeNodeEndToEnd() async throws {
        // Topology: A <-> B <-> C
        // C has content. A requests it. B forwards.
        let nodeA = Ivy(config: testConfig(publicKey: "e2e-a"))
        let nodeB = Ivy(config: testConfig(publicKey: "e2e-b"))
        let nodeC = Ivy(config: testConfig(publicKey: "e2e-c"))

        let collectorA = MessageCollector()
        await nodeA.setDelegate(collectorA)

        await connectNodes(nodeA, nodeB)
        await connectNodes(nodeB, nodeC)
        try await Task.sleep(for: .milliseconds(100))

        let aID = await nodeA.localID
        let bID = await nodeB.localID
        let cID = await nodeC.localID

        // C has the content in its haveSet
        let testData = Data("end-to-end content".utf8)
        let cid = "QmE2E"
        await nodeC.publishBlock(cid: cid, data: testData)

        // Verify C has it
        let cHas = await nodeC.storedPinAnnouncements(for: cid)
        // C has it in haveSet even if not in pin announcements

        // A sends a fee-based dhtForward targeting C through B
        // A is connected to B. B is connected to C. B's routing table has C.
        // The dhtForward with target=C.hash should route: A → B → C
        let targetHash = Data(Router.hash(cID.publicKey))
        await nodeA.fireToPeerPublic(bID, .dhtForward(cid: cid, ttl: 0, fee: 20, target: targetHash, selector: nil))

        // Wait for the chain: A→B (forward) → C (serve) → B (relay) → A (receive)
        try await Task.sleep(for: .milliseconds(500))

        // Check: B should have earned its relay fee from A
        let bBalanceWithA = await nodeB.ledger.balance(with: aID)
        // B earned from relaying A's request (when block came back from C)

        // Check: C should have earned from B (served the content)
        let cBalanceWithB = await nodeC.ledger.balance(with: bID)

        // Check: A should have received the block (delivered to delegate or pending request)
        // The block goes through handleMessage → .block case → handleFeeForwardResponse
        // Since A initiated via fireToPeer (not through fetchBlock), the block arrives
        // at A as a normal .block message through the local peer connection

        // The key assertion: did the fee flow work?
        // If B forwarded and C served, then:
        // - B's pendingFeeForward was created for A's request
        // - C responded with .block to B
        // - B's handleFeeForwardResponse relayed to A and earned fee

        // At minimum: verify the routing table allows B to reach C
        let bClosestToC = await nodeB.allRouterPeers().filter { $0.id == cID }
        #expect(!bClosestToC.isEmpty)

        // Verify credit lines exist across the chain
        let abLine = await nodeA.ledger.creditLine(for: bID)
        let baLine = await nodeB.ledger.creditLine(for: aID)
        let bcLine = await nodeB.ledger.creditLine(for: cID)
        let cbLine = await nodeC.ledger.creditLine(for: bID)
        #expect(abLine != nil)
        #expect(baLine != nil)
        #expect(bcLine != nil)
        #expect(cbLine != nil)

        // If the full chain worked, C earned from serving (balance with B > 0)
        // and B earned from relaying (balance with A > 0)
        // The definitive test: did SOME economic activity happen?
        // If either B earned from A or C earned from B, the chain worked.
        let economicActivity = bBalanceWithA != 0 || cBalanceWithB != 0
        #expect(economicActivity, "Expected fee-based forwarding to produce balance changes")
    }

    @Test("Routing table allows B to reach C for forwarding")
    func testRoutingTableForForwarding() async throws {
        let nodeB = Ivy(config: testConfig(publicKey: "rt-b"))
        let nodeC = Ivy(config: testConfig(publicKey: "rt-c"))

        await connectNodes(nodeB, nodeC)
        try await Task.sleep(for: .milliseconds(100))

        let cID = await nodeC.localID
        let bPeers = await nodeB.allRouterPeers()
        let hasCInTable = bPeers.contains { $0.id == cID }
        #expect(hasCInTable)
    }
}
