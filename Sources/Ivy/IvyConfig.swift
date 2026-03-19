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

    public init(
        publicKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        enableLocalDiscovery: Bool = true,
        tallyConfig: TallyConfig = .default,
        kBucketSize: Int = 20,
        maxConcurrentRequests: Int = 6,
        requestTimeout: Duration = .seconds(15),
        serviceType: String = "_ivy._tcp"
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
    }
}
