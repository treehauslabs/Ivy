import Foundation
import Acorn
import Tally

public actor NetworkCASWorker: AcornCASWorker {
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?
    public var timeout: Duration? { .seconds(30) }

    private weak var node: Ivy?

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
        return await node.fetchBlock(cid: cid.rawValue)
    }

    public func storeLocal(cid: ContentIdentifier, data: Data) async {}

    public func setNear(_ worker: any AcornCASWorker) {
        self.near = worker
    }
}
