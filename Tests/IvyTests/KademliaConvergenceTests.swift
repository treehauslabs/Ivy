import Testing
import Foundation
@testable import Ivy
import Acorn
import Tally

@Suite("Kademlia convergence", .serialized)
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

    @Test("findNode converges on near peers in a larger sparse topology")
    func findNodeConvergesInLargerSparseTopology() async throws {
        let nodeCount = 64
        let nodes = makeKademliaNodes(count: nodeCount)
        try await connectTransportMesh(nodes)

        let source = 0
        let target = 63
        await seedTargetConvergentRoutingTables(nodes, targetIndex: target, outDegree: 12)

        let targetKey = "kad-node-\(target)"
        let targetHash = Router.hash(targetKey)
        let expectedClosest = expectedClosestKeys(to: targetKey, count: 8, excluding: source, nodeCount: nodeCount)
        let initialKeys = await routedKeys(nodes[source])
        let initialBestDistance = bestDistance(from: initialKeys, to: targetKey)

        #expect(!initialKeys.contains(targetKey))

        let discovered = await nodes[source].findNode(target: targetKey)
        let discoveredKeys = discovered.map(\.publicKey)
        let sourceKeys = await routedKeys(nodes[source])
        let discoveredDistances = discoveredKeys.map { Router.xorDistance(Router.hash($0), targetHash) }
        let finalBestDistance = bestDistance(from: sourceKeys, to: targetKey)

        #expect(discoveredDistances == discoveredDistances.sorted())
        #expect(sourceKeys.count > initialKeys.count)
        #expect(finalBestDistance < initialBestDistance)
        #expect(Set(discoveredKeys).intersection(expectedClosest).count >= 1)
    }

    @Test("findNode returns exact top-k when queried peers expose the closest set")
    func findNodeReturnsExactTopKWhenReachable() async throws {
        let nodeCount = 64

        for target in [17, 33, 63] {
            let nodes = makeKademliaNodes(count: nodeCount, kBucketSize: 8)
            try await connectTransportMesh(nodes)

            let source = 0
            let targetKey = "kad-node-\(target)"
            let expectedClosest = expectedClosestKeys(to: targetKey, count: 8, excluding: source, nodeCount: nodeCount)
            let bootstrapIndexes = [1, 2, 3].filter { $0 != target }

            await seedRouter(nodes[source], with: bootstrapIndexes, nodes: nodes)
            for index in bootstrapIndexes {
                await seedRouter(nodes[index], with: indexes(for: expectedClosest), nodes: nodes)
            }

            let discovered = await nodes[source].findNode(target: targetKey)
            let discoveredKeys = Set(discovered.map(\.publicKey))

            #expect(discoveredKeys == expectedClosest)
        }
    }

    @Test("findNode still reaches exact top-k with noisy farther neighbors")
    func findNodeIgnoresFartherNoiseWhenExactPathExists() async throws {
        let nodeCount = 64
        let nodes = makeKademliaNodes(count: nodeCount, kBucketSize: 8)
        try await connectTransportMesh(nodes)

        let source = 0
        let honestBootstrap = 1
        let noisyBootstrap = 2
        let targetKey = "kad-node-63"
        let expectedClosest = expectedClosestKeys(to: targetKey, count: 8, excluding: source, nodeCount: nodeCount)
        let noisyFarIndexes = farthestIndexes(to: targetKey, count: 8, excluding: [source, honestBootstrap], nodeCount: nodeCount)

        await seedRouter(nodes[source], with: [honestBootstrap, noisyBootstrap], nodes: nodes)
        await seedRouter(nodes[honestBootstrap], with: indexes(for: expectedClosest), nodes: nodes)
        await seedRouter(nodes[noisyBootstrap], with: noisyFarIndexes, nodes: nodes)

        let discovered = await nodes[source].findNode(target: targetKey)
        let discoveredKeys = Set(discovered.map(\.publicKey))

        #expect(discoveredKeys == expectedClosest)
    }

    @Test("concurrent findNode lookups keep neighbor responses separated by nonce")
    func concurrentFindNodeLookupsKeepResponsesSeparated() async throws {
        let source = Ivy(config: IvyConfig(
            publicKey: "kad-concurrent-source",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            kBucketSize: 1,
            healthConfig: PeerHealthConfig(
                keepaliveInterval: .seconds(999),
                staleTimeout: .seconds(999),
                maxMissedPongs: 99,
                enabled: false
            ),
            enablePEX: false,
            replicationInterval: .seconds(999)
        ))
        let sourceID = await source.localID
        let peerID = PeerID(publicKey: "kad-concurrent-peer")
        let (sourceSide, peerSide) = LocalPeerConnection.pair(localID: sourceID, remoteID: peerID)
        await source.registerLocalPeer(sourceSide, as: peerID)
        await source.addToRouter(peerID, endpoint: PeerEndpoint(publicKey: peerID.publicKey, host: "local", port: 1))

        let targetA = "kad-target-a"
        let targetB = "kad-target-b"
        let lookupA = Task { await source.findNode(target: targetA) }
        let lookupB = Task { await source.findNode(target: targetB) }

        var iterator = peerSide.messages.makeAsyncIterator()
        let message1 = await iterator.next()
        let message2 = await iterator.next()
        let requests = [message1, message2].compactMap { message -> (target: Data, nonce: UInt64)? in
            guard case .findNode(let target, _, let nonce) = message else { return nil }
            return (target, nonce)
        }
        #expect(requests.count == 2)

        guard let requestA = requests.first(where: { $0.target == Data(Router.hash(targetA)) }),
              let requestB = requests.first(where: { $0.target == Data(Router.hash(targetB)) }) else {
            Issue.record("Expected both concurrent findNode requests")
            return
        }

        peerSide.send(.neighbors([PeerEndpoint(publicKey: targetB, host: "local", port: 2)], nonce: requestB.nonce))
        peerSide.send(.neighbors([PeerEndpoint(publicKey: targetA, host: "local", port: 3)], nonce: requestA.nonce))

        let resultA = await lookupA.value
        let resultB = await lookupB.value

        #expect(resultA.first?.publicKey == targetA)
        #expect(resultB.first?.publicKey == targetB)

        peerSide.close()
    }

    @Test("findNode uses later alpha responses when an earlier peer is silent")
    func findNodeUsesLaterAlphaResponsesAfterSilentPeer() async throws {
        let source = Ivy(config: IvyConfig(
            publicKey: "kad-alpha-source",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            kBucketSize: 8,
            healthConfig: PeerHealthConfig(
                keepaliveInterval: .seconds(999),
                staleTimeout: .seconds(999),
                maxMissedPongs: 99,
                enabled: false
            ),
            enablePEX: false,
            replicationInterval: .seconds(999)
        ))
        let sourceID = await source.localID
        let target = "kad-alpha-target"
        let peerIDs = [
            PeerID(publicKey: "kad-alpha-peer-1"),
            PeerID(publicKey: "kad-alpha-peer-2")
        ].sorted {
            Router.isCloser(Router.hash($0.publicKey), than: Router.hash($1.publicKey), to: Router.hash(target))
        }

        let (firstNodeSide, firstPeerSide) = LocalPeerConnection.pair(localID: sourceID, remoteID: peerIDs[0])
        let (secondNodeSide, secondPeerSide) = LocalPeerConnection.pair(localID: sourceID, remoteID: peerIDs[1])
        await source.registerLocalPeer(firstNodeSide, as: peerIDs[0])
        await source.registerLocalPeer(secondNodeSide, as: peerIDs[1])
        await source.addToRouter(peerIDs[0], endpoint: PeerEndpoint(publicKey: peerIDs[0].publicKey, host: "local", port: 1))
        await source.addToRouter(peerIDs[1], endpoint: PeerEndpoint(publicKey: peerIDs[1].publicKey, host: "local", port: 2))

        let lookup = Task { await source.findNode(target: target) }
        var secondIterator = secondPeerSide.messages.makeAsyncIterator()
        guard case .findNode(_, _, let secondNonce) = await secondIterator.next() else {
            Issue.record("Expected second alpha peer to receive findNode")
            return
        }
        secondPeerSide.send(.neighbors([PeerEndpoint(publicKey: target, host: "local", port: 3)], nonce: secondNonce))

        let result = await lookup.value
        #expect(result.contains { $0.publicKey == target })

        firstPeerSide.close()
        secondPeerSide.close()
    }

    @Test("findNode continues converging when some sparse-path peers churn out")
    func findNodeConvergesWithChurnedPeers() async throws {
        let nodeCount = 64
        let nodes = makeKademliaNodes(count: nodeCount)
        try await connectTransportMesh(nodes)
        await seedTargetConvergentRoutingTables(nodes, targetIndex: 63, outDegree: 12)

        let source = 0
        let churnedPeers = [3, 7, 15, 31].map { PeerID(publicKey: "kad-node-\($0)") }
        for peer in churnedPeers {
            await nodes[source].disconnect(peer)
        }

        let targetKey = "kad-node-63"
        let initialKeys = await routedKeys(nodes[source])
        let initialBestDistance = bestDistance(from: initialKeys, to: targetKey)
        let discovered = await nodes[source].findNode(target: targetKey)
        let discoveredKeys = Set(discovered.map(\.publicKey))
        let finalBestDistance = bestDistance(from: await routedKeys(nodes[source]), to: targetKey)

        #expect(!discoveredKeys.isEmpty)
        #expect(finalBestDistance < initialBestDistance)
    }
}

private func makeKademliaNodes(count: Int, kBucketSize: Int = 20) -> [Ivy] {
    (0..<count).map { index in
        Ivy(config: IvyConfig(
            publicKey: "kad-node-\(index)",
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            kBucketSize: kBucketSize,
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

private func seedTargetConvergentRoutingTables(_ nodes: [Ivy], targetIndex: Int, outDegree: Int) async {
    let targetKey = "kad-node-\(targetIndex)"
    let targetHash = Router.hash(targetKey)
    let ranked = nodes.indices.sorted {
        Router.xorDistance(Router.hash("kad-node-\($0)"), targetHash) < Router.xorDistance(Router.hash("kad-node-\($1)"), targetHash)
    }
    let rankByIndex = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element, $0.offset) })

    for index in nodes.indices {
        let rank = rankByIndex[index]!
        let closer = ranked[..<rank].suffix(outDegree)
        var neighbors = Array(closer)
        if neighbors.count < outDegree {
            neighbors.append(contentsOf: sparseNeighborIndexes(for: index, nodeCount: nodes.count, outDegree: outDegree - neighbors.count))
        }
        await seedRouter(nodes[index], with: Array(neighbors.prefix(outDegree)), nodes: nodes)
    }
}

private func sparseNeighborIndexes(for index: Int, nodeCount: Int, outDegree: Int) -> [Int] {
    var neighbors: [Int] = []
    var step = 1
    while neighbors.count < outDegree && step < nodeCount {
        let forward = index + step
        if forward < nodeCount {
            neighbors.append(forward)
        }
        let backward = index - step
        if neighbors.count < outDegree, backward >= 0 {
            neighbors.append(backward)
        }
        step *= 2
    }
    return Array(neighbors.prefix(outDegree))
}

private func expectedClosestKeys(to targetKey: String, count: Int, excluding excludedIndex: Int, nodeCount: Int) -> Set<String> {
    expectedClosestKeys(to: targetKey, count: count, excluding: Set([excludedIndex]), nodeCount: nodeCount)
}

private func expectedClosestKeys(to targetKey: String, count: Int, excluding excludedIndexes: Set<Int>, nodeCount: Int) -> Set<String> {
    let targetHash = Router.hash(targetKey)
    return Set((0..<nodeCount)
        .filter { !excludedIndexes.contains($0) }
        .map { "kad-node-\($0)" }
        .sorted {
            Router.xorDistance(Router.hash($0), targetHash) < Router.xorDistance(Router.hash($1), targetHash)
        }
        .prefix(count))
}

private func farthestIndexes(to targetKey: String, count: Int, excluding excludedIndexes: Set<Int>, nodeCount: Int) -> [Int] {
    let targetHash = Router.hash(targetKey)
    return (0..<nodeCount)
        .filter { !excludedIndexes.contains($0) }
        .sorted {
            Router.xorDistance(Router.hash("kad-node-\($0)"), targetHash) > Router.xorDistance(Router.hash("kad-node-\($1)"), targetHash)
        }
        .prefix(count)
        .map { $0 }
}

private func indexes(for keys: Set<String>) -> [Int] {
    keys.compactMap { key in
        guard let suffix = key.split(separator: "-").last else { return nil }
        return Int(suffix)
    }
}

private func bestDistance(from keys: Set<String>, to targetKey: String) -> [UInt8] {
    let targetHash = Router.hash(targetKey)
    return keys
        .map { Router.xorDistance(Router.hash($0), targetHash) }
        .min() ?? Array(repeating: UInt8.max, count: targetHash.count)
}
