import Foundation
import Tally

public struct IvyConfig: Sendable {
    public static let defaultMaxFrameSize: UInt32 = 4 * 1024 * 1024
    public static let defaultMaxInboundConnections: Int = 256

    public let publicKey: String
    public let listenPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
    public let enableLocalDiscovery: Bool
    public let tallyConfig: TallyConfig
    public let kBucketSize: Int
    public let maxConcurrentRequests: Int
    public let requestTimeout: Duration
    public let relayTimeout: Duration
    public let serviceType: String
    public let stunServers: [(String, Int)]
    public let defaultTTL: UInt8
    public let healthConfig: PeerHealthConfig
    public let enablePEX: Bool
    public let pexInterval: Duration
    public let pexMaxPeers: Int
    public let replicationInterval: Duration
    public let replicationMinCopies: Int
    public let replicationSampleSize: Int
    public let signingKey: Data
    public let logger: any IvyLogger
    public let relayFee: UInt64
    public let baseThresholdMultiplier: UInt64
    public let defaultRequestFee: UInt64
    public let highBandwidthPeers: Int
    public let sendBytesPerSecond: Int
    /// Maximum serialized Ivy wire-frame payload this node will send or accept.
    /// This is node policy, not a consensus rule; operators can raise it for
    /// chains or applications that need larger wire payloads.
    public let maxFrameSize: UInt32
    /// Upper bound on distinct in-flight CIDs/volume queries tracked in `pendingRequests` /
    /// `pendingVolumeRequests`. Prevents an attacker (or a runaway local
    /// caller) from allocating unbounded continuations by repeatedly asking
    /// for unique CIDs faster than `requestTimeout` drains them.
    public let maxPendingRequests: Int
    /// Per-CID/query cap on coalesced waiters. Many concurrent local callers for
    /// the same content legitimately fan-in to one pending request; this caps
    /// the fan-in so one hot request can't grow one continuation list forever.
    public let maxWaitersPerPendingCID: Int
    /// Maximum number of peers to broadcast a `want` request to when DHT provider
    /// records are empty. Caps the O(N) duplicate-work cost of the broadcast fallback.
    /// DHT providers are always preferred; this only applies to the fallback path.
    public let maxWantCandidates: Int
    /// Minimum trailing-zero bits of SHA256(publicKey) required to accept a
    /// peer's identify message. Each additional bit doubles the expected work
    /// to generate a valid peer key, making Sybil routing-table poisoning
    /// progressively more expensive. 0 = disabled (accept any key).
    public let minPeerKeyBits: Int

    public init(
        publicKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        enableLocalDiscovery: Bool = true,
        tallyConfig: TallyConfig = .default,
        kBucketSize: Int = 20,
        maxConcurrentRequests: Int = 6,
        requestTimeout: Duration = .seconds(15),
        relayTimeout: Duration = .seconds(5),
        serviceType: String = "_ivy._tcp",
        stunServers: [(String, Int)] = STUNClient.defaultServers,
        defaultTTL: UInt8 = 7,
        healthConfig: PeerHealthConfig = .default,
        enablePEX: Bool = true,
        pexInterval: Duration = .seconds(120),
        pexMaxPeers: Int = 16,
        replicationInterval: Duration = .seconds(300),
        replicationMinCopies: Int = 3,
        replicationSampleSize: Int = 32,
        signingKey: Data = Data(),
        logger: any IvyLogger = NullLogger(),
        relayFee: UInt64 = 0,
        baseThresholdMultiplier: UInt64 = 100,
        defaultRequestFee: UInt64 = 20,
        highBandwidthPeers: Int = 3,
        sendBytesPerSecond: Int = 1_048_576,
        maxFrameSize: UInt32 = IvyConfig.defaultMaxFrameSize,
        maxPendingRequests: Int = 4_096,
        maxWaitersPerPendingCID: Int = 64,
        minPeerKeyBits: Int = 0,
        maxWantCandidates: Int = 8
    ) {
        self.publicKey = publicKey
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.enableLocalDiscovery = enableLocalDiscovery
        self.tallyConfig = tallyConfig
        self.kBucketSize = kBucketSize
        self.maxConcurrentRequests = maxConcurrentRequests
        self.requestTimeout = requestTimeout
        self.relayTimeout = relayTimeout
        self.serviceType = serviceType
        self.stunServers = stunServers
        self.defaultTTL = defaultTTL
        self.healthConfig = healthConfig
        self.enablePEX = enablePEX
        self.pexInterval = pexInterval
        self.pexMaxPeers = pexMaxPeers
        self.replicationInterval = replicationInterval
        self.replicationMinCopies = replicationMinCopies
        self.replicationSampleSize = replicationSampleSize
        self.signingKey = signingKey
        self.logger = logger
        self.relayFee = relayFee
        self.baseThresholdMultiplier = baseThresholdMultiplier
        self.defaultRequestFee = defaultRequestFee
        self.highBandwidthPeers = highBandwidthPeers
        self.sendBytesPerSecond = sendBytesPerSecond
        self.maxFrameSize = maxFrameSize
        self.maxPendingRequests = maxPendingRequests
        self.maxWaitersPerPendingCID = maxWaitersPerPendingCID
        self.minPeerKeyBits = minPeerKeyBits
        self.maxWantCandidates = maxWantCandidates
    }
}
