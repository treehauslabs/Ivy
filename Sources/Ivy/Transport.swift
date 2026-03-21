import Foundation
import Crypto
import Tally

public actor Transport {
    public struct PathEntry: Sendable {
        public let destinationHash: Data
        public let receivedFrom: PeerID
        public let receivedOnInterface: String
        public var hops: UInt8
        public var timestamp: ContinuousClock.Instant
        public var announcePacketHash: Data?
        public var expiry: Duration

        public var isExpired: Bool {
            timestamp.duration(to: .now) > expiry
        }
    }

    public struct ReverseEntry: Sendable {
        public let receivedFrom: PeerID
        public let receivedOnInterface: String
        public let timestamp: ContinuousClock.Instant

        public static let timeout: Duration = .seconds(480)

        public var isExpired: Bool {
            timestamp.duration(to: .now) > Self.timeout
        }
    }

    public static let maxHops: UInt8 = 128
    public static let pathRequestTimeout: Duration = .seconds(15)
    public static let destinationTimeout: Duration = .seconds(604_800)
    public static let announceRateLimit: Duration = .seconds(2)

    private var pathTable: BoundedDictionary<Data, PathEntry>
    private var reverseTable: BoundedDictionary<Data, ReverseEntry>
    private var seenAnnounces: BoundedSet<Data>
    private var announceTimestamps: BoundedDictionary<Data, ContinuousClock.Instant>

    private let localID: PeerID
    private let tally: Tally
    private var interfaces: [String: any NetworkInterface] = [:]
    public private(set) var isTransportEnabled: Bool
    private var pruneTask: Task<Void, Never>?

    public static let defaultMaxPaths = 10_000
    public static let defaultMaxReverseEntries = 5_000
    public static let defaultMaxSeenAnnounces = 50_000
    public static let defaultPruneInterval: Duration = .seconds(60)

    public init(localID: PeerID, tally: Tally, enableTransport: Bool = false, maxPaths: Int = Transport.defaultMaxPaths) {
        self.localID = localID
        self.tally = tally
        self.isTransportEnabled = enableTransport
        self.pathTable = BoundedDictionary(capacity: maxPaths)
        self.reverseTable = BoundedDictionary(capacity: Self.defaultMaxReverseEntries)
        self.seenAnnounces = BoundedSet(capacity: Self.defaultMaxSeenAnnounces)
        self.announceTimestamps = BoundedDictionary(capacity: maxPaths)
    }

    public func startAutoPruning(interval: Duration = Transport.defaultPruneInterval) {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.pruneExpired()
            }
        }
    }

    public func stopAutoPruning() {
        pruneTask?.cancel()
        pruneTask = nil
    }

    public func enableTransport() {
        isTransportEnabled = true
    }

    public func registerInterface(_ iface: any NetworkInterface) {
        interfaces[iface.name] = iface
    }

    public func removeInterface(named name: String) {
        interfaces.removeValue(forKey: name)
    }

    public var registeredInterfaces: [String] {
        Array(interfaces.keys)
    }

    public func lookupPath(_ destinationHash: Data) -> PathEntry? {
        guard let entry = pathTable[destinationHash], !entry.isExpired else {
            return nil
        }
        return entry
    }

    public func recordPath(
        destinationHash: Data,
        from peer: PeerID,
        onInterface: String,
        hops: UInt8,
        announceHash: Data? = nil,
        expiry: Duration = Transport.destinationTimeout
    ) {
        guard tally.shouldAllow(peer: peer) else { return }

        if let existing = pathTable[destinationHash], !existing.isExpired {
            if existing.hops <= hops { return }
        }

        pathTable[destinationHash] = PathEntry(
            destinationHash: destinationHash,
            receivedFrom: peer,
            receivedOnInterface: onInterface,
            hops: hops,
            timestamp: .now,
            announcePacketHash: announceHash,
            expiry: expiry
        )
    }

    public func recordReverse(packetHash: Data, from peer: PeerID, onInterface: String) {
        reverseTable[packetHash] = ReverseEntry(
            receivedFrom: peer,
            receivedOnInterface: onInterface,
            timestamp: .now
        )
    }

    public func handleInboundPacket(
        _ packet: TransportPacket,
        from peer: PeerID,
        onInterface interfaceName: String
    ) async -> TransportAction {
        guard tally.shouldAllow(peer: peer) else {
            return .drop
        }

        tally.recordReceived(peer: peer, bytes: packet.payload.count, cpl: 0)

        switch packet.packetType {
        case .announce:
            return handleAnnounce(packet, from: peer, onInterface: interfaceName)

        case .data, .proof:
            return handleDataPacket(packet, from: peer, onInterface: interfaceName)

        case .linkRequest:
            return handleLinkRequest(packet, from: peer, onInterface: interfaceName)
        }
    }

    private func handleAnnounce(
        _ packet: TransportPacket,
        from peer: PeerID,
        onInterface interfaceName: String
    ) -> TransportAction {
        let announceHash = packet.packetHash
        guard !seenAnnounces.contains(announceHash) else { return .drop }
        guard packet.hops < Self.maxHops else { return .drop }

        if let lastTime = announceTimestamps[packet.destinationHash] {
            if lastTime.duration(to: .now) < Self.announceRateLimit {
                return .drop
            }
        }

        seenAnnounces.insert(announceHash)
        announceTimestamps[packet.destinationHash] = .now

        recordPath(
            destinationHash: packet.destinationHash,
            from: peer,
            onInterface: interfaceName,
            hops: packet.hops,
            announceHash: announceHash
        )

        if isTransportEnabled {
            var forwarded = packet
            forwarded.hops += 1
            return .forwardOnAllExcept(interfaceName, forwarded)
        }

        return .deliver(packet)
    }

    private func handleDataPacket(
        _ packet: TransportPacket,
        from peer: PeerID,
        onInterface interfaceName: String
    ) -> TransportAction {
        let localHash = Router.truncatedHash(Data(localID.publicKey.utf8))
        if packet.destinationHash == localHash {
            return .deliver(packet)
        }

        if packet.destinationType == .plain && packet.propagationType == .broadcast {
            return .deliver(packet)
        }

        guard isTransportEnabled else {
            return .deliver(packet)
        }

        if packet.propagationType == .transport, let tid = packet.transportID {
            if tid == localHash {
                if let path = lookupPath(packet.destinationHash) {
                    var forwarded = packet
                    forwarded.hops += 1

                    if path.hops == 0 {
                        forwarded.headerType = .header1
                        forwarded.propagationType = .broadcast
                        forwarded.transportID = nil
                    }

                    return .forwardTo(path.receivedFrom, path.receivedOnInterface, forwarded)
                }
            }
            return .drop
        }

        if let path = lookupPath(packet.destinationHash) {
            var forwarded = packet
            forwarded.hops += 1

            if packet.hops < Self.maxHops {
                recordReverse(packetHash: packet.packetHash, from: peer, onInterface: interfaceName)
                return .forwardTo(path.receivedFrom, path.receivedOnInterface, forwarded)
            }
        }

        return .deliver(packet)
    }

    private func handleLinkRequest(
        _ packet: TransportPacket,
        from peer: PeerID,
        onInterface interfaceName: String
    ) -> TransportAction {
        if let path = lookupPath(packet.destinationHash), isTransportEnabled {
            var forwarded = packet
            forwarded.hops += 1
            recordReverse(packetHash: packet.packetHash, from: peer, onInterface: interfaceName)
            return .forwardTo(path.receivedFrom, path.receivedOnInterface, forwarded)
        }

        return .deliver(packet)
    }

    public func pruneExpired() {
        pathTable.removeAll { _, entry in entry.isExpired }
        reverseTable.removeAll { _, entry in entry.isExpired }
    }

    public var pathCount: Int { pathTable.count }
    public var reverseCount: Int { reverseTable.count }

    public func allPaths() -> [PathEntry] {
        pathTable.values.filter { !$0.isExpired }
    }
}

public enum TransportAction: Sendable {
    case deliver(TransportPacket)
    case forwardTo(PeerID, String, TransportPacket)
    case forwardOnAllExcept(String, TransportPacket)
    case drop
}
