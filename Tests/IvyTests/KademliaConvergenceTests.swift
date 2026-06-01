import Testing
import Foundation
@testable import Ivy
import Acorn
import Tally

@Suite("Kademlia convergence")
struct KademliaConvergenceTests {

    @Test("findNode converges across sparse routing tables")
    func findNodeConvergesAcrossSparseRoutingTables() async throws {
        let nodes = makeKademliaNodes(count: 8)
        try await connectTransportMesh(nodes)

        let targetKey = "kad-node-7"
        await seedRouter(nodes[0], with: [1], nodes: nodes)
        await seedRouter(nodes[1], with: [2, 3], nodes: nodes)
        await seedRouter(nodes[2], with: [4, 5], nodes: nodes)
        await seedRouter(nodes[3], with: [6], nodes: nodes)
        await seedRouter(nodes[4], with: [7], nodes: nodes)
        await seedRouter(nodes[5], with: [7], nodes: nodes)
        await seedRouter(nodes[6], with: [7], nodes: nodes)

        #expect(!(await routedKeys(nodes[0]).contains(targetKey)))

        let discovered = await nodes[0].findNode(target: targetKey)
        let discoveredKeys = Set(discovered.map(\.publicKey))
        let node0Keys = await routedKeys(nodes[0])

        #expect(discoveredKeys.contains(targetKey))
        #expect(node0Keys.contains(targetKey))
    }

    @Test("findNode preserves Kademlia distance ordering")
    func findNodePreservesDistanceOrdering() async throws {
        let nodes = makeKademliaNodes(count: 10)
        try await connectTransportMesh(nodes)

        let targetKey = "kad-node-9"
        await seedRouter(nodes[0], with: [1, 2, 3, 4, 5, 6, 7, 8, 9], nodes: nodes)

        let endpoints = await nodes[0].findNode(target: targetKey)
        let targetHash = Router.hash(targetKey)
        let distances = endpoints.map { Router.xorDistance(Router.hash($0.publicKey), targetHash) }

        #expect(!endpoints.isEmpty)
        #expect(distances == distances.sorted())
        #expect(endpoints.first?.publicKey == targetKey)
    }
}

private func makeKademliaNodes(count: Int) -> [Ivy] {
    (0..<count).map { index in
        Ivy(config: IvyConfig(
            publicKey: "kad-node-\(index)",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            healthConfig: PeerHealthConfig(
                keepaliveInterval: .seconds(999),
                staleTimeout: .seconds(999),
                maxMissedPongs: 99,
                enabled: false
            ),
            enablePEX: false,
            replicationInterval: .seconds(999)
        ))
    }
}

private func connectTransportMesh(_ nodes: [Ivy]) async throws {
    for i in nodes.indices {
        for j in nodes.indices where j > i {
            try Task.checkCancellation()
            let aID = await nodes[i].localID
            let bID = await nodes[j].localID
            let (aSide, bSide) = LocalPeerConnection.pair(localID: aID, remoteID: bID)
            await nodes[i].registerLocalPeer(aSide, as: bID)
            await nodes[j].registerLocalPeer(bSide, as: aID)
        }
    }
    try await Task.sleep(for: .milliseconds(50))
}

private func seedRouter(_ node: Ivy, with peerIndexes: [Int], nodes: [Ivy]) async {
    for index in peerIndexes {
        let key = "kad-node-\(index)"
        let peer = PeerID(publicKey: key)
        let endpoint = PeerEndpoint(publicKey: key, host: "local", port: UInt16(index))
        await node.addToRouter(peer, endpoint: endpoint)
    }
}

private func routedKeys(_ node: Ivy) async -> Set<String> {
    Set(await node.allRouterPeers().map { $0.id.publicKey })
}
