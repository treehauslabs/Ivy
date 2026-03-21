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
    public let healthConfig: PeerHealthConfig
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
        healthConfig: PeerHealthConfig = .default,
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
        self.healthConfig = healthConfig
        self.logger = logger
    }
}
