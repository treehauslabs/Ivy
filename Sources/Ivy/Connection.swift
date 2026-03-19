@preconcurrency import Network
import Foundation
import Tally

public final class PeerConnection: Sendable {
    public let id: PeerID
    public let endpoint: PeerEndpoint
    public let connection: NWConnection
    private let queue: DispatchQueue
    private let inbound: AsyncStream<Message>
    private let inboundContinuation: AsyncStream<Message>.Continuation

    public init(id: PeerID, endpoint: PeerEndpoint, connection: NWConnection) {
        self.id = id
        self.endpoint = endpoint
        self.connection = connection
        self.queue = DispatchQueue(label: "ivy.conn.\(id.publicKey.prefix(8))")
        let (stream, continuation) = AsyncStream<Message>.makeStream()
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    public static func dial(endpoint: PeerEndpoint) -> PeerConnection {
        let nw = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!,
            using: .tcp
        )
        let id = PeerID(publicKey: endpoint.publicKey)
        return PeerConnection(id: id, endpoint: endpoint, connection: nw)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop()
            case .failed, .cancelled:
                self?.inboundContinuation.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: Message) async throws {
        let frame = Message.frame(message)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    public var messages: AsyncStream<Message> { inbound }

    public func cancel() {
        connection.cancel()
        inboundContinuation.finish()
    }

    private func receiveLoop() {
        readFrame { [weak self] message in
            guard let self, let message else {
                self?.inboundContinuation.finish()
                return
            }
            self.inboundContinuation.yield(message)
            self.receiveLoop()
        }
    }

    private func readFrame(completion: @escaping @Sendable (Message?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, let header, error == nil, header.count == 4 else {
                completion(nil)
                return
            }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length < 64 * 1024 * 1024 else {
                completion(nil)
                return
            }
            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, error in
                guard let body, error == nil else {
                    completion(nil)
                    return
                }
                completion(Message.deserialize(body))
            }
        }
    }
}
