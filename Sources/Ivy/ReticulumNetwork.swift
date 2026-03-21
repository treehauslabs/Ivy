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

    public init(node: Ivy, transport: Transport, announceService: AnnounceService) {
        self.node = node
        self.transport = transport
        self.announceService = announceService
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

        let announced = await announceService.allKnownDestinations()
            .sorted { $0.reputation > $1.reputation }
            .prefix(4)
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
            await node.fireToPeer(peer, .wantBlock(cid: cid.rawValue))
        }

        return await node.fetchBlock(cid: cid.rawValue)
    }
}
