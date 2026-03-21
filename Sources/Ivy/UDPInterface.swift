import Foundation
import NIOCore
import NIOPosix

public final class UDPInterface: NetworkInterface, @unchecked Sendable {
    public let name: String
    public let mode: InterfaceMode
    public let mtu: Int = 500
    public private(set) var isOnline: Bool = false
    public let bitrate: Int = 10_000_000

    private let host: String
    private let port: UInt16
    private let group: EventLoopGroup
    private var channel: Channel?

    private let _inbound: AsyncStream<(TransportPacket, PeerEndpoint?)>
    private let _inboundContinuation: AsyncStream<(TransportPacket, PeerEndpoint?)>.Continuation

    public var inboundPackets: AsyncStream<(TransportPacket, PeerEndpoint?)> { _inbound }

    public init(name: String = "udp0", host: String = "0.0.0.0", port: UInt16 = 4002, mode: InterfaceMode = .full, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
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
        let handler = UDPPacketHandler(continuation: _inboundContinuation)
        let bootstrap = DatagramBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        channel = try await bootstrap.bind(host: host, port: Int(port)).get()
        isOnline = true
    }

    public func stop() async {
        isOnline = false
        channel?.close(promise: nil)
        channel = nil
        _inboundContinuation.finish()
    }

    public func send(_ packet: TransportPacket, to destination: PeerEndpoint?) async throws {
        guard let ch = channel, let dest = destination else { return }
        let data = packet.serialize()
        guard data.count <= mtu else { return }

        let addr = try SocketAddress.makeAddressResolvingHost(dest.host, port: Int(dest.port))
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        let envelope = AddressedEnvelope(remoteAddress: addr, data: buf)
        try await ch.writeAndFlush(envelope).get()
    }
}

private final class UDPPacketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let continuation: AsyncStream<(TransportPacket, PeerEndpoint?)>.Continuation

    init(continuation: AsyncStream<(TransportPacket, PeerEndpoint?)>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buf = envelope.data
        guard let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        if let packet = TransportPacket.deserialize(Data(bytes)) {
            let endpoint = PeerEndpoint(
                publicKey: "",
                host: envelope.remoteAddress.ipAddress ?? "unknown",
                port: UInt16(envelope.remoteAddress.port ?? 0)
            )
            continuation.yield((packet, endpoint))
        }
    }
}
