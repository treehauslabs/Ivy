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
    public let enableRelay: Bool
    public let enableAutoNAT: Bool
    public let enableHolePunch: Bool
    public let stunServers: [(String, Int)]

    public let enableTransport: Bool
    public let enableAnnounce: Bool
    public let announceInterval: Duration
    public let announceAppName: String
    public let udpPort: UInt16
    public let enableUDP: Bool
    public let signingKey: Data
    public let defaultTTL: UInt8
    public let healthConfig: PeerHealthConfig
    public let enablePEX: Bool
    public let pexInterval: Duration
    public let pexMaxPeers: Int
    public let logger: any IvyLogger

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
        enableRelay: Bool = true,
        enableAutoNAT: Bool = true,
        enableHolePunch: Bool = true,
        stunServers: [(String, Int)] = STUNClient.defaultServers,
        enableTransport: Bool = false,
        enableAnnounce: Bool = true,
        announceInterval: Duration = .seconds(300),
        announceAppName: String = "ivy.default",
        udpPort: UInt16 = 4002,
        enableUDP: Bool = false,
        signingKey: Data = Data(),
        defaultTTL: UInt8 = 7,
        healthConfig: PeerHealthConfig = .default,
        enablePEX: Bool = true,
        pexInterval: Duration = .seconds(120),
        pexMaxPeers: Int = 16,
        logger: any IvyLogger = NullLogger()
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
        self.enableRelay = enableRelay
        self.enableAutoNAT = enableAutoNAT
        self.enableHolePunch = enableHolePunch
        self.stunServers = stunServers
        self.enableTransport = enableTransport
        self.enableAnnounce = enableAnnounce
        self.announceInterval = announceInterval
        self.announceAppName = announceAppName
        self.udpPort = udpPort
        self.enableUDP = enableUDP
        self.signingKey = signingKey
        self.defaultTTL = defaultTTL
        self.healthConfig = healthConfig
        self.enablePEX = enablePEX
        self.pexInterval = pexInterval
        self.pexMaxPeers = pexMaxPeers
        self.logger = logger
    }
}
