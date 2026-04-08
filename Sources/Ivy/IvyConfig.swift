import Foundation
import Tally

public struct IvyConfig: Sendable {
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
    public let zoneSyncLimit: UInt16
    public let zoneSyncInterval: Duration
    public let maxChainAnnounceHops: UInt8
    public let signingKey: Data
    public let logger: any IvyLogger
    public let relayFee: UInt64
    public let baseThresholdMultiplier: UInt64
    public let defaultRequestFee: UInt64

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
        zoneSyncLimit: UInt16 = 256,
        zoneSyncInterval: Duration = .seconds(1800),
        maxChainAnnounceHops: UInt8 = 10,
        signingKey: Data = Data(),
        logger: any IvyLogger = NullLogger(),
        relayFee: UInt64 = 1,
        baseThresholdMultiplier: UInt64 = 100,
        defaultRequestFee: UInt64 = 20
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
        self.zoneSyncLimit = zoneSyncLimit
        self.zoneSyncInterval = zoneSyncInterval
        self.maxChainAnnounceHops = maxChainAnnounceHops
        self.signingKey = signingKey
        self.logger = logger
        self.relayFee = relayFee
        self.baseThresholdMultiplier = baseThresholdMultiplier
        self.defaultRequestFee = defaultRequestFee
    }
}
