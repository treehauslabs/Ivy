import Testing
import Foundation
@testable import Ivy
@testable import Tally
import Acorn

/// S5: a peer that advertises pin ownership but fails to serve the CID must
/// be demoted in Tally. Without this wiring, repeated liars stay in the
/// fetch pool forever — their reputation is only written by PeerHealthMonitor
/// pings, not by fetch-outcome.
///
/// These tests cover the two fetch paths that trust a specific peer:
///   - `getDirect(cid:from:)` — one-hop direct fetch (gossip follow-up / pinner).
///   - `get(cid:target:)`    — pinner-targeted DHT walk (selected via findPins).
private func makeNode(publicKey: String, requestTimeout: Duration = .milliseconds(200)) -> Ivy {
    let config = IvyConfig(
        publicKey: publicKey,
        listenPort: 0,
        bootstrapPeers: [],
        enableLocalDiscovery: false,
        requestTimeout: requestTimeout,
        healthConfig: PeerHealthConfig(keepaliveInterval: .seconds(999), staleTimeout: .seconds(999), maxMissedPongs: 99, enabled: false),
        enablePEX: false,
        replicationInterval: .seconds(999),
        zoneSyncInterval: .seconds(999)
    )
    return Ivy(config: config)
}

@Suite("Pin announce demotion")
struct PinAnnounceDemotionTests {

    @Test("getDirect records failure when the peer times out")
    func testGetDirectTimeoutDemotesPeer() async throws {
        let a = makeNode(publicKey: "demote-a")
        let b = makeNode(publicKey: "demote-b")
        await connectNodes(a, b)
        try await Task.sleep(for: .milliseconds(50))

        let bID = await b.localID

        // Pre-condition: A has never interacted with B at a reputation level,
        // so the ledger may or may not exist. Either way, after a failed
        // direct fetch failureCount must be >= 1.
        let beforeFailures = await a.tally.peerLedger(for: bID)?.failureCount ?? 0

        // B has no record of this CID, so the request will time out.
        let data = await a.getDirect(cid: "cid-that-does-not-exist", from: bID)
        #expect(data == nil)

        let afterFailures = await a.tally.peerLedger(for: bID)?.failureCount ?? 0
        #expect(afterFailures == beforeFailures + 1, "direct-fetch timeout must demote the trusted peer")
    }

    @Test("getDirect records success when the peer delivers")
    func testGetDirectSuccessRewardsPeer() async throws {
        let a = makeNode(publicKey: "reward-a")
        let b = makeNode(publicKey: "reward-b")
        await connectNodes(a, b)
        try await Task.sleep(for: .milliseconds(50))

        let bID = await b.localID

        // Stash data on B via dataSource + publishBlock so haveSet is populated
        // and handleDHTForward on B can serve the follow-up request.
        let cid = "cid-served-by-b"
        let payload = Data("hello".utf8)
        let ds = DictDataSource()
        ds[cid] = payload
        await b.setDataSource(ds)
        await b.publishBlock(cid: cid, data: payload)

        let beforeSuccesses = await a.tally.peerLedger(for: bID)?.successCount ?? 0

        let data = await a.getDirect(cid: cid, from: bID)
        #expect(data == payload, "successful direct fetch must return the payload")

        let afterSuccesses = await a.tally.peerLedger(for: bID)?.successCount ?? 0
        #expect(afterSuccesses >= beforeSuccesses + 1, "successful direct fetch must reward the serving peer")
    }

    @Test("get(cid:target:) records failure when the pinner lies")
    func testTargetedGetTimeoutDemotesPinner() async throws {
        let a = makeNode(publicKey: "target-a")
        let b = makeNode(publicKey: "target-b")
        await connectNodes(a, b)
        try await Task.sleep(for: .milliseconds(50))

        let bID = await b.localID

        let beforeFailures = await a.tally.peerLedger(for: bID)?.failureCount ?? 0

        // B never stored this CID — classic "lied in a pin announce" scenario.
        let data = await a.get(cid: "cid-announced-but-not-held", target: bID)
        #expect(data == nil)

        let afterFailures = await a.tally.peerLedger(for: bID)?.failureCount ?? 0
        #expect(afterFailures == beforeFailures + 1, "targeted-get timeout must demote the announcing peer")
    }
}
