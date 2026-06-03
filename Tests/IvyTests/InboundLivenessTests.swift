import Testing
import Foundation
import Crypto
import NIOCore
import NIOEmbedded
@testable import Ivy
@testable import Tally

private func inboundLivenessConfig(publicKey: String) -> IvyConfig {
    IvyConfig(
        publicKey: publicKey,
        listenPort: 0,
        bootstrapPeers: [],
        enableLocalDiscovery: false,
        healthConfig: PeerHealthConfig(
            keepaliveInterval: .seconds(999),
            staleTimeout: .seconds(999),
            maxMissedPongs: 99,
            enabled: true
        ),
        enablePEX: false,
        replicationInterval: .seconds(999)
    )
}

@Suite("Inbound liveness monitoring")
struct InboundLivenessTests {

    @Test("Inbound peers can be tracked by the health monitor")
    func inboundPeerIsTracked() async {
        let node = Ivy(config: inboundLivenessConfig(publicKey: "inbound-health-node"))
        await node.installHealthMonitorForTesting()

        let inbound = PeerID(publicKey: "inbound-temp")
        await node.trackHealthPeerForTesting(inbound)

        #expect(await node.healthMonitorTracksPeerForTesting(inbound))
        #expect(await node.trackedHealthPeerCountForTesting() == 1)
    }

    @Test("Identify re-key moves health tracking from temporary inbound ID to real peer")
    func identifyRekeyMovesHealthTracking() async {
        let node = Ivy(config: inboundLivenessConfig(publicKey: "inbound-rekey-node"))
        await node.installHealthMonitorForTesting()

        let temporary = PeerID(publicKey: "inbound-temp")
        let real = PeerID(publicKey: "real-peer")
        await node.trackHealthPeerForTesting(temporary)
        await node.moveHealthPeerForTesting(from: temporary, to: real)

        #expect(!(await node.healthMonitorTracksPeerForTesting(temporary)))
        #expect(await node.healthMonitorTracksPeerForTesting(real))
        #expect(await node.trackedHealthPeerCountForTesting() == 1)
    }

    // MARK: - Real ingress paths (TRE-10)
    //
    // The two tests above poke trackPeer/movePeer directly. The two below drive
    // the ACTUAL code paths: the inbound-accept ingress and a real signed
    // identify re-key over the live connection's message stream.

    private func generateKeyPair() -> (publicKey: String, privateKey: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return (pubHex, privateKey.rawRepresentation)
    }

    private func signIdentify(publicKey: String, observedHost: String, privateKey: Data) -> Data {
        let material = Data(publicKey.utf8) + Data(observedHost.utf8)
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try! key.signature(for: material)
    }

    @Test("Inbound accept ingress health-tracks the new peer")
    func inboundAcceptIngressTracksPeer() async throws {
        let node = Ivy(config: inboundLivenessConfig(publicKey: "inbound-accept-node"))
        await node.installHealthMonitorForTesting()

        // Drive the REAL accept path: handleNewInboundChannel is exactly what the
        // server bootstrap invokes for each accepted socket. A testing channel
        // stands in for the accepted NIO channel.
        let channel = NIOAsyncTestingChannel()
        await node.handleNewInboundChannel(channel)

        // The accept path registers an "inbound-<uuid>" connection and schedules
        // health tracking on it asynchronously.
        try await Task.sleep(for: .milliseconds(50))

        let inboundPeers = await node.connectionPeersForTesting()
            .filter { $0.publicKey.hasPrefix("inbound-") }
        #expect(inboundPeers.count == 1)
        guard let inbound = inboundPeers.first else { return }
        #expect(await node.healthMonitorTracksPeerForTesting(inbound))
        #expect(await node.trackedHealthPeerCountForTesting() == 1)

        _ = try? await channel.finish()
    }

    @Test("Real identify re-key over the live connection moves health tracking")
    func realIdentifyRekeyMovesTracking() async throws {
        let node = Ivy(config: inboundLivenessConfig(publicKey: "inbound-real-rekey-node"))
        await node.installHealthMonitorForTesting()

        // Register an inbound peer through the real accept ingress.
        let channel = NIOAsyncTestingChannel()
        await node.handleNewInboundChannel(channel)
        try await Task.sleep(for: .milliseconds(50))

        let inboundPeers = await node.connectionPeersForTesting()
            .filter { $0.publicKey.hasPrefix("inbound-") }
        guard let inbound = inboundPeers.first else {
            Issue.record("inbound peer was not registered")
            return
        }
        #expect(await node.healthMonitorTracksPeerForTesting(inbound))

        // Deliver a real, signature-valid identify over the connection's message
        // pipeline (handleMessage is what handleInbound calls per inbound frame).
        // This drives handleIdentify → the re-key branch → movePeerHealthTracking.
        let (realKey, realPriv) = generateKeyPair()
        let observedHost = "203.0.113.200"
        let signature = signIdentify(publicKey: realKey, observedHost: observedHost, privateKey: realPriv)
        await node.handleMessage(
            .identify(
                publicKey: realKey,
                observedHost: observedHost,
                observedPort: 4001,
                listenAddrs: [],
                chainPorts: [:],
                signature: signature
            ),
            from: inbound
        )

        let realPeer = PeerID(publicKey: realKey)
        #expect(!(await node.healthMonitorTracksPeerForTesting(inbound)),
                "tracking must move off the temporary inbound ID")
        #expect(await node.healthMonitorTracksPeerForTesting(realPeer),
                "the real peer must become health-tracked")
        #expect(await node.trackedHealthPeerCountForTesting() == 1)

        _ = try? await channel.finish()
    }
}
