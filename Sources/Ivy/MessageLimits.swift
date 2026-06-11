import Foundation

public enum MessageLimits {
    public static let maxStringLength: UInt16 = 8192
    public static let maxNeighborCount: UInt16 = 256
    public static let maxListenAddrs: UInt16 = 16
    public static let maxTxCIDCount: UInt16 = 4096
    public static let maxTransactionCount: UInt16 = 4096
    public static let maxPexPeerCount: UInt16 = 64
    public static let maxChainPorts: UInt16 = 64
}
