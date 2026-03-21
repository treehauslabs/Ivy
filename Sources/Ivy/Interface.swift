import Foundation
import NIOCore
import NIOPosix
import Tally
import Crypto

public enum InterfaceMode: UInt8, Sendable {
    case full = 0x01
    case pointToPoint = 0x02
    case accessPoint = 0x03
    case roaming = 0x04
    case boundary = 0x05
    case gateway = 0x06
}

public protocol NetworkInterface: AnyObject, Sendable {
    var name: String { get }
    var mode: InterfaceMode { get }
    var mtu: Int { get }
    var isOnline: Bool { get }
    var bitrate: Int { get }

    func start() async throws
    func stop() async
    func send(_ packet: TransportPacket, to destination: PeerEndpoint?) async throws
    var inboundPackets: AsyncStream<(TransportPacket, PeerEndpoint?)> { get }
}

public struct TransportPacket: Sendable {
    public enum HeaderType: UInt8, Sendable {
        case header1 = 0
        case header2 = 1
    }

    public enum PropagationType: UInt8, Sendable {
        case broadcast = 0
        case transport = 1
    }

    public enum DestinationType: UInt8, Sendable {
        case single = 0x00
        case group = 0x01
        case plain = 0x02
        case link = 0x03
    }

    public enum PacketType: UInt8, Sendable {
        case data = 0x00
        case announce = 0x01
        case linkRequest = 0x02
        case proof = 0x03
    }

    public var headerType: HeaderType
    public var propagationType: PropagationType
    public var destinationType: DestinationType
    public var packetType: PacketType
    public var contextFlag: Bool
    public var hops: UInt8
    public var destinationHash: Data
    public var transportID: Data?
    public var context: UInt8
    public var payload: Data

    public init(
        headerType: HeaderType = .header1,
        propagationType: PropagationType = .broadcast,
        destinationType: DestinationType = .single,
        packetType: PacketType = .data,
        contextFlag: Bool = false,
        hops: UInt8 = 0,
        destinationHash: Data,
        transportID: Data? = nil,
        context: UInt8 = 0x00,
        payload: Data
    ) {
        self.headerType = headerType
        self.propagationType = propagationType
        self.destinationType = destinationType
        self.packetType = packetType
        self.contextFlag = contextFlag
        self.hops = hops
        self.destinationHash = destinationHash
        self.transportID = transportID
        self.context = context
        self.payload = payload
    }

    public static let destinationLength = 16
    public static let maxHops: UInt8 = 128

    public func serialize() -> Data {
        var buf = Data()
        let flags: UInt8 = (headerType.rawValue << 6)
            | (contextFlag ? (1 << 5) : 0)
            | (propagationType.rawValue << 4)
            | (destinationType.rawValue << 2)
            | packetType.rawValue
        buf.append(flags)
        buf.append(hops)

        if headerType == .header2, let tid = transportID {
            buf.append(tid.prefix(Self.destinationLength))
        }
        buf.append(destinationHash.prefix(Self.destinationLength))

        if contextFlag {
            buf.append(context)
        }
        buf.append(payload)
        return buf
    }

    public static func deserialize(_ data: Data) -> TransportPacket? {
        guard data.count >= 2 + destinationLength else { return nil }
        let flags = data[data.startIndex]
        let hops = data[data.startIndex + 1]

        let htRaw = (flags >> 6) & 0x01
        let ctxFlag = (flags >> 5) & 0x01 == 1
        let propRaw = (flags >> 4) & 0x01
        let destRaw = (flags >> 2) & 0x03
        let pktRaw = flags & 0x03

        guard let ht = HeaderType(rawValue: htRaw),
              let prop = PropagationType(rawValue: propRaw),
              let dest = DestinationType(rawValue: destRaw),
              let pkt = PacketType(rawValue: pktRaw) else { return nil }

        var offset = 2
        var transportID: Data?

        if ht == .header2 {
            guard data.count >= offset + destinationLength * 2 else { return nil }
            transportID = data[data.startIndex + offset ..< data.startIndex + offset + destinationLength]
            offset += destinationLength
        }

        guard data.count >= offset + destinationLength else { return nil }
        let destHash = data[data.startIndex + offset ..< data.startIndex + offset + destinationLength]
        offset += destinationLength

        var context: UInt8 = 0x00
        if ctxFlag {
            guard data.count > offset else { return nil }
            context = data[data.startIndex + offset]
            offset += 1
        }

        let payloadStart = data.startIndex + offset
        let payload = data.count > offset ? Data(data[payloadStart..<data.endIndex]) : Data()

        return TransportPacket(
            headerType: ht,
            propagationType: prop,
            destinationType: dest,
            packetType: pkt,
            contextFlag: ctxFlag,
            hops: hops,
            destinationHash: Data(destHash),
            transportID: transportID.map { Data($0) },
            context: context,
            payload: payload
        )
    }

    public var packetHash: Data {
        let raw = serialize()
        let maskedFirst = raw[raw.startIndex] & 0x0F
        var hashable = Data([maskedFirst])
        if headerType == .header1 {
            hashable.append(contentsOf: raw[(raw.startIndex + 2)..<raw.endIndex])
        } else {
            hashable.append(contentsOf: raw[(raw.startIndex + 2 + Self.destinationLength)..<raw.endIndex])
        }
        return Data(Router.hash(hashable).prefix(Self.destinationLength))
    }
}

extension Router {
    public static func hash(_ data: Data) -> [UInt8] {
        Array(Crypto.SHA256.hash(data: data))
    }

    public static func truncatedHash(_ data: Data) -> Data {
        Data(hash(data).prefix(TransportPacket.destinationLength))
    }

    public static func destinationHash(name: String, identityHash: Data) -> Data {
        let nameHash = Data(hash(Data(name.utf8)).prefix(10))
        let material = nameHash + identityHash
        return truncatedHash(material)
    }
}
