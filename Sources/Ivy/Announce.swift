import Foundation
import Crypto
import Tally

public struct AnnouncePayload: Sendable, Equatable {
    public let publicKey: String
    public let nameHash: Data
    public let randomHash: Data
    public let signature: Data
    public let appData: Data?

    public init(publicKey: String, nameHash: Data, randomHash: Data, signature: Data, appData: Data? = nil) {
        self.publicKey = publicKey
        self.nameHash = nameHash
        self.randomHash = randomHash
        self.signature = signature
        self.appData = appData
    }

    public var destinationHash: Data {
        let pkHash = Router.truncatedHash(Data(publicKey.utf8))
        let material = nameHash + pkHash
        return Router.truncatedHash(material)
    }

    public func serialize() -> Data {
        var buf = Data()
        buf.appendLengthPrefixedString(publicKey)
        buf.appendLengthPrefixedData(nameHash)
        buf.appendLengthPrefixedData(randomHash)
        buf.appendLengthPrefixedData(signature)
        let hasAppData: UInt8 = appData != nil ? 1 : 0
        buf.appendUInt8(hasAppData)
        if let appData {
            buf.appendLengthPrefixedData(appData)
        }
        return buf
    }

    public static func deserialize(_ data: Data) -> AnnouncePayload? {
        var reader = DataReader(data)
        guard let publicKey = reader.readString(),
              let nameHash = reader.readData(),
              let randomHash = reader.readData(),
              let signature = reader.readData(),
              let hasAppData = reader.readUInt8() else { return nil }

        var appData: Data?
        if hasAppData == 1 {
            appData = reader.readData()
        }

        return AnnouncePayload(
            publicKey: publicKey,
            nameHash: nameHash,
            randomHash: randomHash,
            signature: signature,
            appData: appData
        )
    }

    public static func makeRandomHash() -> Data {
        var random = Data(count: 5)
        for i in 0..<5 { random[i] = UInt8.random(in: 0...255) }
        let timestamp = UInt64(Date().timeIntervalSince1970)
        var ts = timestamp.bigEndian
        let tsData = Data(bytes: &ts, count: 8)
        return random + tsData.suffix(5)
    }
}

public actor AnnounceService {
    public struct KnownDestination: Sendable {
        public let destinationHash: Data
        public let publicKey: String
        public var hops: UInt8
        public var lastAnnounce: ContinuousClock.Instant
        public var appData: Data?
        public var reputation: Double
    }

    private var knownDestinations: BoundedDictionary<Data, KnownDestination>
    private var seenRandomHashes: BoundedSet<Data>
    private var pendingPathRequests: [Data: [CheckedContinuation<KnownDestination?, Never>]] = [:]
    private var announceCallbacks: [@Sendable (KnownDestination) -> Void] = []

    private let localID: PeerID
    private let tally: Tally

    public static let maxLocalRebroadcasts = 2
    public static let announceExpiry: Duration = .seconds(604_800)
    public static let minReputation: Double = -0.5
    public static let defaultMaxDestinations = 10_000
    public static let defaultMaxSeenHashes = 50_000

    public init(localID: PeerID, tally: Tally, maxDestinations: Int = AnnounceService.defaultMaxDestinations) {
        self.localID = localID
        self.tally = tally
        self.knownDestinations = BoundedDictionary(capacity: maxDestinations)
        self.seenRandomHashes = BoundedSet(capacity: Self.defaultMaxSeenHashes)
    }

    public func createAnnounce(
        publicKey: String,
        name: String,
        signingKey: Data,
        appData: Data? = nil
    ) -> TransportPacket {
        let nameHash = Data(Router.hash(Data(name.utf8)).prefix(10))
        let randomHash = AnnouncePayload.makeRandomHash()
        let destHash = Router.destinationHash(name: name, identityHash: Router.truncatedHash(Data(publicKey.utf8)))

        let signedData = destHash + Data(publicKey.utf8) + nameHash + randomHash + (appData ?? Data())
        let signature = Data(Router.hash(signedData + signingKey))

        let payload = AnnouncePayload(
            publicKey: publicKey,
            nameHash: nameHash,
            randomHash: randomHash,
            signature: signature,
            appData: appData
        )

        return TransportPacket(
            headerType: .header1,
            propagationType: .broadcast,
            destinationType: .single,
            packetType: .announce,
            hops: 0,
            destinationHash: destHash,
            payload: payload.serialize()
        )
    }

    public func processAnnounce(
        _ packet: TransportPacket,
        from peer: PeerID,
        hops: UInt8
    ) -> Bool {
        guard packet.packetType == .announce else { return false }
        guard let payload = AnnouncePayload.deserialize(packet.payload) else { return false }

        guard !seenRandomHashes.contains(payload.randomHash) else { return false }

        let reputation = tally.reputation(for: peer)
        guard reputation >= Self.minReputation else { return false }

        seenRandomHashes.insert(payload.randomHash)

        let dest = KnownDestination(
            destinationHash: packet.destinationHash,
            publicKey: payload.publicKey,
            hops: hops,
            lastAnnounce: .now,
            appData: payload.appData,
            reputation: reputation
        )

        if let existing = knownDestinations[packet.destinationHash] {
            if existing.hops <= hops && existing.lastAnnounce.duration(to: .now) < Self.announceExpiry {
                return false
            }
        }

        knownDestinations[packet.destinationHash] = dest

        for callback in announceCallbacks {
            callback(dest)
        }

        if let pending = pendingPathRequests.removeValue(forKey: packet.destinationHash) {
            for cont in pending {
                cont.resume(returning: dest)
            }
        }

        return true
    }

    public func resolve(destinationHash: Data, timeout: Duration = .seconds(15)) async -> KnownDestination? {
        if let known = knownDestinations[destinationHash], !isExpired(known) {
            return known
        }

        return await withCheckedContinuation { cont in
            pendingPathRequests[destinationHash, default: []].append(cont)
            Task {
                try? await Task.sleep(for: timeout)
                if let pending = self.pendingPathRequests[destinationHash] {
                    for p in pending { p.resume(returning: nil) }
                    self.pendingPathRequests.removeValue(forKey: destinationHash)
                }
            }
        }
    }

    public func knownDestination(for hash: Data) -> KnownDestination? {
        guard let dest = knownDestinations[hash], !isExpired(dest) else { return nil }
        return dest
    }

    public func allKnownDestinations() -> [KnownDestination] {
        knownDestinations.values.filter { !isExpired($0) }
    }

    public func onAnnounce(_ callback: @escaping @Sendable (KnownDestination) -> Void) {
        announceCallbacks.append(callback)
    }

    public func pruneExpired() {
        knownDestinations.removeAll { _, dest in isExpired(dest) }
    }

    public var destinationCount: Int { knownDestinations.count }

    private func isExpired(_ dest: KnownDestination) -> Bool {
        dest.lastAnnounce.duration(to: .now) > Self.announceExpiry
    }
}
