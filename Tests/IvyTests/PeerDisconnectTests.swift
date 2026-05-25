import Testing
import Foundation
@testable import Ivy
import Tally

@Suite("Peer disconnect cleanup")
struct PeerDisconnectTests {

    /// requestVolumeFromPeer continuations must resolve immediately when the
    /// target peer disconnects — not block until the per-request timeout fires.
    ///
    /// Regression: cleanupPendingForPeer only cleared pendingForwards, leaving
    /// pendingVolumeRequests untouched. A fetch awaiting a volume response from
    /// a peer that disconnected would hang for the full requestTimeout (up to
    /// 45s in production), causing submitMinedBlock to time out and triggering
    /// SWIFT TASK CONTINUATION MISUSE warnings when Ivy was deallocated with
    /// pending continuations still registered.
    @Test("Pending volume fetch resolves immediately on peer disconnect")
    func testVolumeRequestResolvesOnDisconnect() async throws {
        // Use a long requestTimeout (10s) to clearly distinguish
        // "resolved immediately on disconnect" from "waited for timeout".
        let nodeA = Ivy(config: IvyConfig(
            publicKey: "disconnect-a",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            requestTimeout: .seconds(10),
            healthConfig: PeerHealthConfig(
                keepaliveInterval: .seconds(999),
                staleTimeout: .seconds(999),
                maxMissedPongs: 99,
                enabled: false
            ),
            enablePEX: false,
            replicationInterval: .seconds(999)
        ))

        // Create a silent peer: LocalPeerConnection without a paired remote end.
        // Messages nodeA sends to silentPeerID are dropped (remoteEnd is nil),
        // so requestVolumeFromPeer will never receive a response.
        let silentPeerID = PeerID(publicKey: "silent-peer-aabbccdd")
        let silentConn = LocalPeerConnection(id: await nodeA.localID)
        await nodeA.registerLocalPeer(silentConn, as: silentPeerID)

        let aID = await nodeA.localID
        await nodeA.addToRouter(silentPeerID, endpoint: PeerEndpoint(publicKey: silentPeerID.publicKey, host: "local", port: 0))
        _ = aID

        try await Task.sleep(for: .milliseconds(30))

        // Start a fetch — nodeA sends getVolume to silentPeerID, which never
        // responds. The continuation is registered in pendingVolumeRequests.
        let fetchTask = Task {
            await nodeA.fetchVolumeFromAllPeers(rootCID: "cid-that-wont-be-served")
        }

        // Let the request register.
        try await Task.sleep(for: .milliseconds(80))

        // Disconnect the silent peer. With the fix, cleanupPendingForPeer
        // immediately resolves the pending volume continuation.
        let start = ContinuousClock.now
        await nodeA.disconnect(silentPeerID)

        let result = await fetchTask.value
        let elapsed = ContinuousClock.now - start

        #expect(result.isEmpty)
        #expect(
            elapsed < .milliseconds(500),
            "fetch must resolve within 500ms of disconnect, not wait for 10s requestTimeout — got \(elapsed)"
        )
    }

    /// All pending volume requests resolve when cleanupAllPending is called,
    /// ensuring no continuations are leaked on Ivy teardown.
    @Test("cleanupAllPending resolves all pending volume requests")
    func testCleanupAllPendingResolvesVolumes() async throws {
        let nodeA = Ivy(config: IvyConfig(
            publicKey: "cleanup-a",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            requestTimeout: .seconds(10),
            healthConfig: PeerHealthConfig(
                keepaliveInterval: .seconds(999),
                staleTimeout: .seconds(999),
                maxMissedPongs: 99,
                enabled: false
            ),
            enablePEX: false,
            replicationInterval: .seconds(999)
        ))

        let silentPeerID = PeerID(publicKey: "silent-peer-cleanup00")
        let silentConn = LocalPeerConnection(id: await nodeA.localID)
        await nodeA.registerLocalPeer(silentConn, as: silentPeerID)
        await nodeA.addToRouter(silentPeerID, endpoint: PeerEndpoint(publicKey: silentPeerID.publicKey, host: "local", port: 0))

        try await Task.sleep(for: .milliseconds(30))

        let fetchTask = Task {
            await nodeA.fetchVolumeFromAllPeers(rootCID: "cid-cleanup-test")
        }

        try await Task.sleep(for: .milliseconds(80))

        let start = ContinuousClock.now
        await nodeA.cleanupAllPending()

        let result = await fetchTask.value
        let elapsed = ContinuousClock.now - start

        #expect(result.isEmpty)
        #expect(elapsed < .milliseconds(500), "cleanupAllPending must resolve immediately — got \(elapsed)")
    }
}
