import Foundation
import Acorn
import Tally

public actor ReticulumNetwork: AcornCASWorker {
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?
    public var timeout: Duration? { .seconds(30) }

    private let node: Ivy
    private let transport: Transport
    private let announceService: AnnounceService
    public let subscriptions: ChainSubscriptionRegistry

    private var chainDestination: ChainDestination?

    public init(node: Ivy, transport: Transport, announceService: AnnounceService) {
        self.node = node
        self.transport = transport
        self.announceService = announceService
        self.subscriptions = ChainSubscriptionRegistry(tally: node.tally)
    }

    public func bindToChain(_ chain: ChainDestination) async {
        self.chainDestination = chain
        await subscriptions.subscribe(to: chain)
    }

    public func has(cid: ContentIdentifier) async -> Bool {
        if let near, await near.has(cid: cid) { return true }
        return await fetchViaTransport(cid: cid) != nil
    }

    public func getLocal(cid: ContentIdentifier) async -> Data? {
        if let near, let data = await near.getLocal(cid: cid) {
            return data
        }
        return await fetchViaTransport(cid: cid)
    }

    public func storeLocal(cid: ContentIdentifier, data: Data) async {
        if let near {
            await near.storeLocal(cid: cid, data: data)
        }
    }

    private func fetchViaTransport(cid: ContentIdentifier) async -> Data? {
        var targetPeers: [PeerID] = []

        if let chain = chainDestination {
            let chainPeers = await subscriptions.bestPeersForChain(chain.destinationHash, count: 4)
            targetPeers.append(contentsOf: chainPeers.map(\.peerID))
        }

        let announced = await announceService.allKnownDestinations()
            .sorted { $0.reputation > $1.reputation }
            .prefix(3)
        for dest in announced {
            if let path = await transport.lookupPath(dest.destinationHash) {
                if !targetPeers.contains(path.receivedFrom) {
                    targetPeers.append(path.receivedFrom)
                }
            }
        }

        targetPeers = targetPeers.filter { node.tally.shouldAllow(peer: $0) }
        guard !targetPeers.isEmpty else {
            return await node.fetchBlock(cid: cid.rawValue)
        }

        for peer in targetPeers {
            try? await node.sendToPeer(peer, .wantBlock(cid: cid.rawValue))
        }

        return await node.fetchBlock(cid: cid.rawValue)
    }

    public func announceChain(
        chainDirectory: String,
        tipIndex: UInt64,
        tipCID: String,
        specCID: String,
        capabilities: ChainCapabilities = .default
    ) async {
        let chainData = ChainAnnounceData(
            chainDirectory: chainDirectory,
            tipIndex: tipIndex,
            tipCID: tipCID,
            specCID: specCID,
            capabilities: capabilities
        )

        let chain = ChainDestination(chainDirectory: chainDirectory, specCID: specCID)

        let publicKey = node.config.publicKey
        let signingKey = node.config.signingKey
        let announcePayload = await announceService.createAnnounce(
            publicKey: publicKey,
            name: "lattice.chain.\(chainDirectory)",
            signingKey: signingKey,
            appData: chainData.serialize()
        )

        await node.broadcastChainAnnounce(
            destinationHash: chain.destinationHash,
            hops: 0,
            chainData: chainData.serialize(),
            announcePayload: announcePayload.payload
        )
    }

    public func processChainAnnounce(
        destinationHash: Data,
        hops: UInt8,
        chainData: Data,
        announcePayload: Data,
        from peer: PeerID
    ) async {
        guard let announceData = ChainAnnounceData.deserialize(chainData) else { return }

        await subscriptions.registerPeer(
            peer,
            for: destinationHash,
            announceData: announceData
        )

        let tPacket = TransportPacket(
            packetType: .announce,
            hops: hops,
            destinationHash: destinationHash,
            payload: announcePayload
        )
        _ = await announceService.processAnnounce(tPacket, from: peer, hops: hops)

        await transport.recordPath(
            destinationHash: destinationHash,
            from: peer,
            onInterface: "tcp0",
            hops: hops
        )
    }

    public func sendCompactBlock(
        chainDirectory: String,
        headerCID: String,
        txCIDs: [String]
    ) async {
        let chain = ChainDestination(chainDirectory: chainDirectory)
        let chainHash = chain.destinationHash

        let peers = await subscriptions.bestPeersForChain(chainHash)
        let msg = Message.compactBlock(chainHash: chainHash, headerCID: headerCID, txCIDs: txCIDs)

        await withDiscardingTaskGroup { group in
            for chainPeer in peers {
                guard node.tally.shouldAllow(peer: chainPeer.peerID) else { continue }
                group.addTask { try? await self.node.sendToPeer(chainPeer.peerID, msg) }
            }
        }
    }

    public func requestCrossChainProof(
        fromChain: ChainDestination,
        proofRequest: Data
    ) async -> Data? {
        if let path = await transport.lookupPath(fromChain.destinationHash) {
            let packet = TransportPacket(
                destinationType: .single,
                packetType: .data,
                contextFlag: true,
                destinationHash: fromChain.destinationHash,
                context: 0x0B,
                payload: proofRequest
            )
            try? await node.sendTransportPacket(packet, via: path)
        }

        let peers = await subscriptions.peersWithCapability(.fullNode, for: fromChain.destinationHash)
        for peer in peers.prefix(3) {
            guard node.tally.shouldAllow(peer: peer.peerID) else { continue }
            try? await node.sendToPeer(peer.peerID, .transportPacket(data: proofRequest))
        }

        return nil
    }
}
