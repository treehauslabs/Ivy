import Testing
import Foundation
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
}
