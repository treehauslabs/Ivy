import Foundation
import NIOCore
import NIOPosix
import NIOFoundationCompat
import Tally

public final class PeerConnection: @unchecked Sendable {
    public internal(set) var id: PeerID
    public let endpoint: PeerEndpoint
    let channel: Channel
    private let inbound: AsyncStream<Message>
    private let inboundContinuation: AsyncStream<Message>.Continuation

    init(id: PeerID, endpoint: PeerEndpoint, channel: Channel) {
        self.id = id
        self.endpoint = endpoint
        self.channel = channel
        let (stream, continuation) = AsyncStream<Message>.makeStream()
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    public static func dial(endpoint: PeerEndpoint, group: EventLoopGroup) async throws -> PeerConnection {
        let id = PeerID(publicKey: endpoint.publicKey)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                let handler = MessageFrameDecoder()
                return channel.pipeline.addHandler(handler)
            }

        let channel = try await bootstrap.connect(
            host: endpoint.host,
            port: Int(endpoint.port)
        ).get()

        let peerConn = PeerConnection(id: id, endpoint: endpoint, channel: channel)
        let peerHandler = PeerChannelHandler(connection: peerConn)
        try await channel.pipeline.addHandler(peerHandler).get()

        return peerConn
    }

    public func send(_ message: Message) async throws {
        let payload = message.serialize()
        var buf = channel.allocator.buffer(capacity: 4 + payload.count)
        buf.writeInteger(UInt32(payload.count), endianness: .big)
        buf.writeBytes(payload)
        try await channel.writeAndFlush(buf).get()
    }

    public func fireAndForget(_ payload: Data) {
        var buf = channel.allocator.buffer(capacity: 4 + payload.count)
        buf.writeInteger(UInt32(payload.count), endianness: .big)
        buf.writeBytes(payload)
        channel.writeAndFlush(buf, promise: nil)
    }

    public func fireAndForgetMessage(_ message: Message) {
        let payload = message.serialize()
        fireAndForget(payload)
    }

    public var messages: AsyncStream<Message> { inbound }

    func feedMessage(_ message: Message) {
        inboundContinuation.yield(message)
    }

    func connectionClosed() {
        inboundContinuation.finish()
    }

    public func cancel() {
        channel.close(promise: nil)
        inboundContinuation.finish()
    }
}

final class MessageFrameDecoder: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Message

    private var buffer: ByteBuffer = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        while buffer.readableBytes >= 4 {
            guard let length = buffer.getInteger(at: buffer.readerIndex, endianness: .big, as: UInt32.self) else { break }
            guard length > 0, length <= MessageLimits.maxFrameSize else {
                context.close(promise: nil)
                return
            }
            guard buffer.readableBytes >= 4 + Int(length) else { break }
            buffer.moveReaderIndex(forwardBy: 4)
            guard let data = buffer.readData(length: Int(length)) else { break }
            if let message = Message.deserialize(data) {
                context.fireChannelRead(wrapInboundOut(message))
            }
        }

        buffer.discardReadBytes()
    }
}

final class PeerChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Message

    let connection: PeerConnection

    init(connection: PeerConnection) {
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        connection.feedMessage(message)
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.connectionClosed()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

final class UnsafeMutableTransferBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class InboundConnectionAcceptor: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Message

    let ivy: Ivy
    private var registered = false

    init(ivy: Ivy) {
        self.ivy = ivy
    }

    func channelActive(context: ChannelHandlerContext) {
        if !registered {
            registered = true
            let channel = context.channel
            Task { await ivy.handleNewInboundChannel(channel) }
        }
        context.fireChannelActive()
    }
}
