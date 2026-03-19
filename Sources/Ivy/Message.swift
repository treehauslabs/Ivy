import Foundation

public enum Message: Sendable {
    case ping(nonce: UInt64)
    case pong(nonce: UInt64)
    case wantBlock(cid: String)
    case block(cid: String, data: Data)
    case dontHave(cid: String)
    case findNode(target: Data)
    case neighbors([PeerEndpoint])
    case announceBlock(cid: String)

    private enum Tag: UInt8 {
        case ping = 0
        case pong = 1
        case wantBlock = 2
        case block = 3
        case dontHave = 4
        case findNode = 5
        case neighbors = 6
        case announceBlock = 7
    }

    public func serialize() -> Data {
        var buf = Data()
        switch self {
        case .ping(let nonce):
            buf.append(Tag.ping.rawValue)
            buf.appendUInt64(nonce)
        case .pong(let nonce):
            buf.append(Tag.pong.rawValue)
            buf.appendUInt64(nonce)
        case .wantBlock(let cid):
            buf.append(Tag.wantBlock.rawValue)
            buf.appendLengthPrefixedString(cid)
        case .block(let cid, let data):
            buf.append(Tag.block.rawValue)
            buf.appendLengthPrefixedString(cid)
            buf.appendLengthPrefixedData(data)
        case .dontHave(let cid):
            buf.append(Tag.dontHave.rawValue)
            buf.appendLengthPrefixedString(cid)
        case .findNode(let target):
            buf.append(Tag.findNode.rawValue)
            buf.appendLengthPrefixedData(target)
        case .neighbors(let peers):
            buf.append(Tag.neighbors.rawValue)
            buf.appendUInt16(UInt16(peers.count))
            for peer in peers {
                buf.appendLengthPrefixedString(peer.publicKey)
                buf.appendLengthPrefixedString(peer.host)
                buf.appendUInt16(peer.port)
            }
        case .announceBlock(let cid):
            buf.append(Tag.announceBlock.rawValue)
            buf.appendLengthPrefixedString(cid)
        }
        return buf
    }

    public static func deserialize(_ data: Data) -> Message? {
        var reader = DataReader(data)
        guard let rawTag = reader.readUInt8(),
              let tag = Tag(rawValue: rawTag) else { return nil }
        switch tag {
        case .ping:
            guard let nonce = reader.readUInt64() else { return nil }
            return .ping(nonce: nonce)
        case .pong:
            guard let nonce = reader.readUInt64() else { return nil }
            return .pong(nonce: nonce)
        case .wantBlock:
            guard let cid = reader.readString() else { return nil }
            return .wantBlock(cid: cid)
        case .block:
            guard let cid = reader.readString(),
                  let payload = reader.readData() else { return nil }
            return .block(cid: cid, data: payload)
        case .dontHave:
            guard let cid = reader.readString() else { return nil }
            return .dontHave(cid: cid)
        case .findNode:
            guard let target = reader.readData() else { return nil }
            return .findNode(target: target)
        case .neighbors:
            guard let count = reader.readUInt16() else { return nil }
            var peers = [PeerEndpoint]()
            peers.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let key = reader.readString(),
                      let host = reader.readString(),
                      let port = reader.readUInt16() else { return nil }
                peers.append(PeerEndpoint(publicKey: key, host: host, port: port))
            }
            return .neighbors(peers)
        case .announceBlock:
            guard let cid = reader.readString() else { return nil }
            return .announceBlock(cid: cid)
        }
    }

    public static func frame(_ message: Message) -> Data {
        let payload = message.serialize()
        var frame = Data(capacity: 4 + payload.count)
        frame.appendUInt32(UInt32(payload.count))
        frame.append(payload)
        return frame
    }
}

public struct PeerEndpoint: Sendable, Equatable {
    public let publicKey: String
    public let host: String
    public let port: UInt16

    public init(publicKey: String, host: String, port: UInt16) {
        self.publicKey = publicKey
        self.host = host
        self.port = port
    }
}

extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendUInt32(_ value: UInt32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }
    mutating func appendUInt64(_ value: UInt64) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 8))
    }
    mutating func appendLengthPrefixedString(_ string: String) {
        let bytes = Data(string.utf8)
        appendUInt16(UInt16(bytes.count))
        append(bytes)
    }
    mutating func appendLengthPrefixedData(_ data: Data) {
        appendUInt32(UInt32(data.count))
        append(data)
    }
}

struct DataReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        let start = data.startIndex + offset
        var v: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: start..<start+2) }
        return v.bigEndian
    }

    mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        let start = data.startIndex + offset
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: start..<start+4) }
        return v.bigEndian
    }

    mutating func readUInt64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { offset += 8 }
        let start = data.startIndex + offset
        var v: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: start..<start+8) }
        return v.bigEndian
    }

    mutating func readString() -> String? {
        guard let len = readUInt16() else { return nil }
        guard remaining >= Int(len) else { return nil }
        defer { offset += Int(len) }
        let start = data.startIndex + offset
        return String(data: data[start..<start+Int(len)], encoding: .utf8)
    }

    mutating func readData() -> Data? {
        guard let len = readUInt32() else { return nil }
        guard remaining >= Int(len) else { return nil }
        defer { offset += Int(len) }
        let start = data.startIndex + offset
        return Data(data[start..<start+Int(len)])
    }
}
