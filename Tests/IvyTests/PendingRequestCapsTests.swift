import Testing
import Foundation
@testable import Ivy
/// UNSTOPPABLE_LATTICE I11: `pendingRequests` and `pendingVolumeRequests` must
/// not grow unbounded. A runaway local caller (or peer echoing distinct CIDs
/// faster than requestTimeout drains) would otherwise allocate continuations
/// forever. Caps force over-budget callers to receive nil immediately instead
/// of enqueueing one more waiter.
@Suite("Pending-request capacity caps")
struct PendingRequestCapsTests {

    private func cappedConfig(
        maxPending: Int,
        maxWaiters: Int
    ) -> IvyConfig {
        IvyConfig(
            publicKey: "capped-node",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            // Timeouts long enough that the first waves are definitely still
            // in flight when we probe the cap, but short enough that the
            // leftover tasks drain quickly at teardown. Nil returns from the
            // cap-probe must be immediate (<100ms), never from these timeouts.
            requestTimeout: .seconds(1),
            relayTimeout: .seconds(1),
            healthConfig: PeerHealthConfig(
                keepaliveInterval: .seconds(999),
                staleTimeout: .seconds(999),
                maxMissedPongs: 99,
                enabled: false
            ),
            enablePEX: false,
            replicationInterval: .seconds(999),
            zoneSyncInterval: .seconds(999),
            maxPendingRequests: maxPending,
            maxWaitersPerPendingCID: maxWaiters
        )
    }

    @Test("fetchBlock returns nil immediately when the pending dict is full")
    func testGlobalPendingCap() async throws {
        let node = Ivy(config: cappedConfig(maxPending: 2, maxWaiters: 64))

        // Launch two fetches for distinct CIDs. With no peers they register,
        // fire to zero targets, and block on relayTimeout.
        let a = Task { await node.fetchBlock(cid: "cid-a") }
        let b = Task { await node.fetchBlock(cid: "cid-b") }

        // Give the two fetches time to register before we probe the cap.
        try await Task.sleep(for: .milliseconds(50))

        // Third distinct CID must bounce off the cap; measure wall time to
        // prove it didn't block on the (30s) request timeout.
        let start = ContinuousClock.now
        let c = await node.fetchBlock(cid: "cid-c")
        let elapsed = ContinuousClock.now - start

        #expect(c == nil, "third distinct CID should be rejected")
        #expect(elapsed < .milliseconds(100),
                "rejection must be immediate, not wait on requestTimeout — got \(elapsed)")

        // Drain the two still-pending entries so the task doesn't leak.
        await node.cleanupAllPending()
        _ = await a.value
        _ = await b.value
    }

    @Test("fetchBlock returns nil immediately when per-CID waiter list is full")
    func testPerCIDWaiterCap() async throws {
        let node = Ivy(config: cappedConfig(maxPending: 128, maxWaiters: 2))

        // Two concurrent calls for the same CID; the second coalesces onto
        // the first's waiter list.
        let a = Task { await node.fetchBlock(cid: "shared-cid") }
        try await Task.sleep(for: .milliseconds(20))
        let b = Task { await node.fetchBlock(cid: "shared-cid") }
        try await Task.sleep(for: .milliseconds(30))

        // Third call onto the same CID is over the waiter cap.
        let start = ContinuousClock.now
        let c = await node.fetchBlock(cid: "shared-cid")
        let elapsed = ContinuousClock.now - start

        #expect(c == nil, "third waiter on the same CID should be rejected")
        #expect(elapsed < .milliseconds(100),
                "rejection must be immediate — got \(elapsed)")

        await node.cleanupAllPending()
        _ = await a.value
        _ = await b.value
    }
}
