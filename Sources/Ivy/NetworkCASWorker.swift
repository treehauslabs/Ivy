import Foundation
import Acorn
import Tally

public actor NetworkCASWorker: AcornCASWorker {
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?
    public var timeout: Duration? { .seconds(30) }

    private weak var node: Ivy?

    // Volume provider hint: when set, fetches route through the volume's provider
    private var activeVolumeRootCID: String?

    init(node: Ivy) {
        self.node = node
    }

    public func has(cid: ContentIdentifier) async -> Bool {
        if let near, await near.has(cid: cid) { return true }
        guard let node else { return false }
        return await node.fetchBlock(cid: cid.rawValue) != nil
    }

    public func getLocal(cid: ContentIdentifier) async -> Data? {
        guard let node else { return nil }

        // Volume-hint-aware routing: if we're inside a volume resolution,
        // try the volume's known providers first before blind DHT lookup.
        // This is what turns N separate DHT lookups into N requests to 1 peer.
        if let rootCID = activeVolumeRootCID {
            let providers = await node.providers(for: rootCID)
            for provider in providers {
                // Request this specific CID from the known volume provider
                if let data = await node.get(cid: cid.rawValue, target: provider) {
                    return data
                }
            }
        }

        return await node.fetchBlock(cid: cid.rawValue)
    }

    public func storeLocal(cid: ContentIdentifier, data: Data) async {}

    public func setNear(_ worker: any AcornCASWorker) {
        self.near = worker
    }

    // MARK: - Volume Hints

    /// Signal that subsequent fetch calls belong to a volume rooted at rootCID.
    /// This is called by the application layer (e.g., Cashew's VolumeAwareFetcher)
    /// so that Ivy routes fetches to the volume's known provider.
    public func provideVolumeHint(rootCID: String) {
        self.activeVolumeRootCID = rootCID
    }

    /// Clear the active volume hint after resolution completes.
    public func clearVolumeHint() {
        self.activeVolumeRootCID = nil
    }

    /// Batch-fetch all CIDs belonging to the active volume.
    public func fetchVolume(rootCID: String, childCIDs: [String]) async -> [String: Data] {
        guard let node else { return [:] }
        return await node.fetchVolume(rootCID: rootCID, childCIDs: childCIDs)
    }
}
