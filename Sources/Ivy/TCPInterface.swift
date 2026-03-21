import Foundation
import NIOCore
import NIOPosix

public final class TCPInterface: NetworkInterface, @unchecked Sendable {
    public let name: String
    public let mode: InterfaceMode
    public let mtu: Int = 524_288
    public private(set) var isOnline: Bool = false
    public let bitrate: Int = 1_000_000_000

    private let host: String
    private let port: UInt16
    private let group: EventLoopGroup
    private var serverChannel: Channel?

    private let _inbound: AsyncStream<(TransportPacket, PeerEndpoint?)>
    private let _inboundContinuation: AsyncStream<(TransportPacket, PeerEndpoint?)>.Continuation

    public var inboundPackets: AsyncStream<(TransportPacket, PeerEndpoint?)> { _inbound }

    public init(name: String = "tcp0", host: String = "0.0.0.0", port: UInt16 = 4001, mode: InterfaceMode = .full, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.name = name
        self.host = host
        self.port = port
        self.mode = mode
        self.group = group
        let (stream, continuation) = AsyncStream<(TransportPacket, PeerEndpoint?)>.makeStream()
        self._inbound = stream
        self._inboundContinuation = continuation
    }

    public func start() async throws {
        let cont = _inboundContinuation
        let handler = TCPPacketAcceptor(continuation: cont)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        serverChannel = try await bootstrap.bind(host: host, port: Int(port)).get()
        isOnline = true
    }

    public func stop() async {
        isOnline = false
        try? await serverChannel?.close().get()
        serverChannel = nil
        _inboundContinuation.finish()
    }

    public func send(_ packet: TransportPacket, to destination: PeerEndpoint?) async throws {
        guard let dest = destination else { return }
        let bootstrap = ClientBootstrap(group: group).connectTimeout(.seconds(5))
        let channel = try await bootstrap.connect(host: dest.host, port: Int(dest.port)).get()
        defer { channel.close(promise: nil) }

        let data = packet.serialize()
        var buf = channel.allocator.buffer(capacity: 4 + data.count)
        buf.writeInteger(UInt32(data.count), endianness: .big)
        buf.writeBytes(data)
        try await channel.writeAndFlush(buf).get()
    }
}

private final class TCPPacketAcceptor: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<(TransportPacket, PeerEndpoint?)>.Continuation
    private var buffer = ByteBuffer()

    init(continuation: AsyncStream<(TransportPacket, PeerEndpoint?)>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        while buffer.readableBytes >= 4 {
            guard let length = buffer.getInteger(at: buffer.readerIndex, endianness: .big, as: UInt32.self),
                  length > 0, length < 64 * 1024 * 1024,
                  buffer.readableBytes >= 4 + Int(length) else { break }
            buffer.moveReaderIndex(forwardBy: 4)
            guard let bytes = buffer.readBytes(length: Int(length)) else { break }
            if let packet = TransportPacket.deserialize(Data(bytes)) {
                let remote = context.channel.remoteAddress
                let endpoint = remote.map {
                    PeerEndpoint(publicKey: "", host: $0.ipAddress ?? "unknown", port: UInt16($0.port ?? 0))
                }
                continuation.yield((packet, endpoint))
            }
        }
        buffer.discardReadBytes()
    }
}
