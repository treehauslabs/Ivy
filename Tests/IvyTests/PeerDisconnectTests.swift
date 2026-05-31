import Testing
import Foundation
@testable import Ivy
import Tally

@Suite("Peer disconnect cleanup")
struct PeerDisconnectTests {

    /// With content-addressed routing, pendingVolumeRequests is keyed by rootCID.
    /// Disconnecting one peer does not cancel the fetch — other peers may still
    /// serve the content. cleanupAllPending() handles full teardown.
    ///
    /// This test verifies that when the ONLY peer is disconnected and
    /// cleanupAllPending() is called, the fetch resolves immediately rather
    /// than waiting for requestTimeout.
    @Test("Pending volume fetch resolves immediately on full teardown")
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

        // Start a fetch — nodeA sends want to silentPeerID, which never
        // responds. The continuation is registered in pendingVolumeRequests.
        let fetchTask = Task {
            await nodeA.fetchVolumeFromAllPeers(rootCID: "cid-that-wont-be-served")
        }

        // Let the request register in the want-have phase.
        try await Task.sleep(for: .milliseconds(80))

        // With content-addressed routing, pendingVolumeRequests is keyed by
        // query shape, not peer. Disconnecting one peer doesn't cancel it
        // (other peers might serve the same content). cleanupAllPending()
        // handles full teardown.
        let start = ContinuousClock.now
        await nodeA.disconnect(silentPeerID)
        await nodeA.cleanupAllPending()

        let result = await fetchTask.value
        let elapsed = ContinuousClock.now - start

        #expect(result.isEmpty)
        #expect(
            elapsed < .milliseconds(500),
            "fetch must resolve within 500ms of cleanupAllPending — got \(elapsed)"
        )
    }

    /// Regression: onCancel used to resolve a single exact volume key. Volume
    /// fetches may now have multiple query shapes for the same root, so teardown
    /// must resolve every pending query under that root.
    @Test("resolveVolumeRequestsForRoot resolves continuations regardless of peer key suffix")
    func testResolveByRootCIDHandlesKeyMigration() async throws {
        let config = IvyConfig(
            publicKey: "root-resolve-a",
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
        )
        let node = Ivy(config: config)
        let silentPeerID = PeerID(publicKey: "silent-keymigrate0")
        let silentConn = LocalPeerConnection(id: await node.localID)
        await node.registerLocalPeer(silentConn, as: silentPeerID)
        await node.addToRouter(silentPeerID, endpoint: PeerEndpoint(publicKey: silentPeerID.publicKey, host: "local", port: 0))

        try await Task.sleep(for: .milliseconds(30))

        // Start a fetch — continuation stored under "test-root-cid-<8chars>"
        let fetchTask = Task {
            await node.fetchVolumeFromAllPeers(rootCID: "test-root-cid")
        }
        try await Task.sleep(for: .milliseconds(80))

        // Simulate what onCancel does after a key migration:
        // resolveVolumeRequestsForRoot matches by rootCID prefix, so the
        // continuation is found even if the peer's key suffix changed.
        let start = ContinuousClock.now
        await node.resolveVolumeRequestsForRoot(rootCID: "test-root-cid")

        let result = await fetchTask.value
        let elapsed = ContinuousClock.now - start

        #expect(result.isEmpty)
        #expect(elapsed < .milliseconds(500),
            "resolveVolumeRequestsForRoot must resolve immediately — got \(elapsed)")
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
