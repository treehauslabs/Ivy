import Foundation
import VolumeBroker

public actor IvyBroker: VolumeBroker {
    public var near: (any VolumeBroker)?
    public var far: (any VolumeBroker)?

    private weak var node: Ivy?

    public init(node: Ivy) {
        self.node = node
    }

    public func hasVolume(root: String) -> Bool { false }

    public func fetchVolumeLocal(root: String) async -> VolumePayload? {
        guard let node else { return nil }
        return await node.fetchVolume(rootCID: root)
    }

    public func storeVolumeLocal(_ payload: VolumePayload) throws {}

    public func pin(root: String, owner: String, ttl: Duration?) async throws {
        guard let node else { return }
        let expiry: UInt64
        if let ttl {
            expiry = UInt64(Date().timeIntervalSince1970) + UInt64(ttl.components.seconds)
        } else {
            expiry = UInt64(Date().timeIntervalSince1970) + 86400
        }
        let fee = await node.config.relayFee * 2
        await node.publishPinAnnounce(rootCID: root, selector: "/", expiry: expiry, signature: Data(), fee: fee)
    }

    public func unpin(root: String, owner: String) throws {}
    public func owners(root: String) -> Set<String> { [] }
    public func evictUnpinned() throws -> Int { 0 }
}
