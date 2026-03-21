import Foundation
import Tally

public protocol IvyDelegate: AnyObject, Sendable {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID)
    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID)
    func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress)
    func ivy(_ ivy: Ivy, didUpdateNATStatus status: NATStatus)
    func ivy(_ ivy: Ivy, didUpgradeToDirectConnection peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveAnnounce publicKey: String, destinationHash: Data, hops: UInt8, appData: Data?)
    func ivy(_ ivy: Ivy, didDiscoverPath destinationHash: Data, hops: UInt8, via peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveTransportPacket packet: TransportPacket, from peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveChainAnnounce chainData: ChainAnnounceData, destinationHash: Data, hops: UInt8, from peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveCompactBlock headerCID: String, txCIDs: [String], chainHash: Data, from peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveBlockTxns headerCID: String, transactions: [(String, Data)], chainHash: Data, from peer: PeerID)
    func ivy(_ ivy: Ivy, didRequestBlockTxns headerCID: String, missingTxCIDs: [String], chainHash: Data, from peer: PeerID)
}

public extension IvyDelegate {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress) {}
    func ivy(_ ivy: Ivy, didUpdateNATStatus status: NATStatus) {}
    func ivy(_ ivy: Ivy, didUpgradeToDirectConnection peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveAnnounce publicKey: String, destinationHash: Data, hops: UInt8, appData: Data?) {}
    func ivy(_ ivy: Ivy, didDiscoverPath destinationHash: Data, hops: UInt8, via peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveTransportPacket packet: TransportPacket, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveChainAnnounce chainData: ChainAnnounceData, destinationHash: Data, hops: UInt8, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveCompactBlock headerCID: String, txCIDs: [String], chainHash: Data, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveBlockTxns headerCID: String, transactions: [(String, Data)], chainHash: Data, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didRequestBlockTxns headerCID: String, missingTxCIDs: [String], chainHash: Data, from peer: PeerID) {}
}
