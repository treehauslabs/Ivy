import Foundation
import Crypto
import Tally

public struct ChainDestination: Sendable, Hashable {
    public let chainDirectory: String
    public let destinationHash: Data

    public init(chainDirectory: String) {
        self.chainDirectory = chainDirectory
        self.destinationHash = Router.truncatedHash(Data("lattice.chain.\(chainDirectory)".utf8))
    }

    public init(chainDirectory: String, specCID: String) {
        self.chainDirectory = chainDirectory
        let material = Data("lattice.chain.\(chainDirectory).\(specCID)".utf8)
        self.destinationHash = Router.truncatedHash(material)
    }

    public static func nexus() -> ChainDestination {
        ChainDestination(chainDirectory: "Nexus")
    }
}

public struct ChainAnnounceData: Sendable, Equatable {
    public let chainDirectory: String
    public let tipIndex: UInt64
    public let tipCID: String
    public let specCID: String
    public let capabilities: ChainCapabilities

    public init(chainDirectory: String, tipIndex: UInt64, tipCID: String, specCID: String, capabilities: ChainCapabilities = .default) {
        self.chainDirectory = chainDirectory
        self.tipIndex = tipIndex
        self.tipCID = tipCID
        self.specCID = specCID
        self.capabilities = capabilities
    }

    public func serialize() -> Data {
        var buf = Data()
        buf.appendLengthPrefixedString(chainDirectory)
        buf.appendUInt64(tipIndex)
        buf.appendLengthPrefixedString(tipCID)
        buf.appendLengthPrefixedString(specCID)
        buf.appendUInt8(capabilities.rawValue)
        return buf
    }

    public static func deserialize(_ data: Data) -> ChainAnnounceData? {
        var reader = DataReader(data)
        guard let dir = reader.readString(),
              let tipIdx = reader.readUInt64(),
              let tipCID = reader.readString(),
              let specCID = reader.readString(),
              let capRaw = reader.readUInt8() else { return nil }
        return ChainAnnounceData(
            chainDirectory: dir,
            tipIndex: tipIdx,
            tipCID: tipCID,
            specCID: specCID,
            capabilities: ChainCapabilities(rawValue: capRaw)
        )
    }
}

public struct ChainCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let fullNode = ChainCapabilities(rawValue: 1 << 0)
    public static let miner = ChainCapabilities(rawValue: 1 << 1)
    public static let archiveNode = ChainCapabilities(rawValue: 1 << 2)
    public static let lightClient = ChainCapabilities(rawValue: 1 << 3)
    public static let transportServer = ChainCapabilities(rawValue: 1 << 4)

    public static let `default`: ChainCapabilities = [.fullNode]
}

public actor ChainSubscriptionRegistry {
    public struct ChainPeer: Sendable {
        public let peerID: PeerID
        public let chainDirectory: String
        public let tipIndex: UInt64
        public let tipCID: String
        public let capabilities: ChainCapabilities
        public var lastSeen: ContinuousClock.Instant
        public var reputation: Double
    }

    private var subscriptions: Set<Data> = []
    private var chainPeers: [Data: [PeerID: ChainPeer]] = [:]
    private var callbacks: [Data: [@Sendable (ChainPeer) -> Void]] = [:]
    private let tally: Tally

    public init(tally: Tally) {
        self.tally = tally
    }

    public func subscribe(to chain: ChainDestination) {
        subscriptions.insert(chain.destinationHash)
    }

    public func unsubscribe(from chain: ChainDestination) {
        subscriptions.remove(chain.destinationHash)
        chainPeers.removeValue(forKey: chain.destinationHash)
    }

    public func isSubscribed(to destinationHash: Data) -> Bool {
        subscriptions.contains(destinationHash)
    }

    public var subscribedChains: Set<Data> {
        subscriptions
    }

    public func registerPeer(
        _ peer: PeerID,
        for destinationHash: Data,
        announceData: ChainAnnounceData
    ) {
        let rep = tally.reputation(for: peer)
        let chainPeer = ChainPeer(
            peerID: peer,
            chainDirectory: announceData.chainDirectory,
            tipIndex: announceData.tipIndex,
            tipCID: announceData.tipCID,
            capabilities: announceData.capabilities,
            lastSeen: .now,
            reputation: rep
        )

        chainPeers[destinationHash, default: [:]][peer] = chainPeer

        if let cbs = callbacks[destinationHash] {
            for cb in cbs { cb(chainPeer) }
        }
    }

    public func peersForChain(_ destinationHash: Data) -> [ChainPeer] {
        guard let peers = chainPeers[destinationHash] else { return [] }
        return peers.values
            .sorted { $0.reputation > $1.reputation }
    }

    public func bestPeersForChain(_ destinationHash: Data, count: Int = 6) -> [ChainPeer] {
        Array(peersForChain(destinationHash).prefix(count))
    }

    public func peersWithCapability(_ cap: ChainCapabilities, for destinationHash: Data) -> [ChainPeer] {
        peersForChain(destinationHash).filter { $0.capabilities.contains(cap) }
    }

    public func onChainPeerDiscovered(for destinationHash: Data, callback: @escaping @Sendable (ChainPeer) -> Void) {
        callbacks[destinationHash, default: []].append(callback)
    }

    public func peerCount(for destinationHash: Data) -> Int {
        chainPeers[destinationHash]?.count ?? 0
    }

    public func removePeer(_ peer: PeerID, from destinationHash: Data) {
        chainPeers[destinationHash]?.removeValue(forKey: peer)
    }

    public func pruneStale(olderThan duration: Duration = .seconds(3600)) {
        let cutoff = ContinuousClock.now.advanced(by: .zero - duration)
        for (hash, var peers) in chainPeers {
            peers = peers.filter { $0.value.lastSeen > cutoff }
            chainPeers[hash] = peers.isEmpty ? nil : peers
        }
    }
}
