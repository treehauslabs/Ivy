import Foundation
import Tally

public protocol IvyDelegate: AnyObject, Sendable {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID)
    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID)
    func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID)
}

public extension IvyDelegate {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {}
    func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {}
}
