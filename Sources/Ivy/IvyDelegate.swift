import Foundation
import Tally

public protocol IvyDelegate: AnyObject, Sendable {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID)
    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID)
    func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress)
    func ivy(_ ivy: Ivy, didReceiveMessage message: Message, from peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveVolumeAnnouncement rootCID: String, childCIDs: [String], totalSize: UInt64, from peer: PeerID)
}

public extension IvyDelegate {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress) {}
    func ivy(_ ivy: Ivy, didReceiveMessage message: Message, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveVolumeAnnouncement rootCID: String, childCIDs: [String], totalSize: UInt64, from peer: PeerID) {}
}
