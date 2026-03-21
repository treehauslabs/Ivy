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

    case identify(publicKey: String, observedHost: String, observedPort: UInt16, listenAddrs: [(String, UInt16)])
    case dialBack(nonce: UInt64, host: String, port: UInt16)
    case dialBackResult(nonce: UInt64, success: Bool)
    case relayConnect(srcKey: String, dstKey: String)
    case relayStatus(code: UInt8)
    case relayData(peerKey: String, data: Data)
    case holepunchConnect(addrs: [(String, UInt16)], nonce: UInt64)
    case holepunchSync(nonce: UInt64)
    case dhtForward(cid: String, ttl: UInt8)

    case announce(destinationHash: Data, hops: UInt8, payload: Data)
    case pathRequest(destinationHash: Data)
    case pathResponse(destinationHash: Data, hops: UInt8, announcePayload: Data)
    case transportPacket(data: Data)

    case chainAnnounce(destinationHash: Data, hops: UInt8, chainData: Data, announcePayload: Data)
    case compactBlock(chainHash: Data, headerCID: String, txCIDs: [String])
    case getBlockTxns(chainHash: Data, headerCID: String, missingTxCIDs: [String])
    case blockTxns(chainHash: Data, headerCID: String, transactions: [(String, Data)])

    case haveBlock(cid: String)
    case wantBlocks(cids: [String])

    case newTxHashes(chainHash: Data, txHashes: [String])
    case getTxns(chainHash: Data, txHashes: [String])
    case txns(chainHash: Data, transactions: [(String, Data)])

    case getBlockRange(chainHash: Data, startIndex: UInt64, count: UInt16)
    case blockRange(chainHash: Data, startIndex: UInt64, blocks: [(String, Data)])

    case blockManifest(blockCID: String, referencedCIDs: [String])
    case getCIDs(cids: [String])
    case cidData(items: [(String, Data)])

    private enum Tag: UInt8 {
        case ping = 0
        case pong = 1
        case wantBlock = 2
        case block = 3
        case dontHave = 4
        case findNode = 5
        case neighbors = 6
        case announceBlock = 7
        case identify = 8
        case dialBack = 9
        case dialBackResult = 10
        case relayConnect = 11
        case relayStatus = 12
        case relayData = 13
        case holepunchConnect = 14
        case holepunchSync = 15
        case dhtForward = 16
        case announce = 17
        case pathRequest = 18
        case pathResponse = 19
        case transportPacket = 20
        case chainAnnounce = 21
        case compactBlock = 22
        case getBlockTxns = 23
        case blockTxns = 24
        case haveBlock = 25
        case wantBlocks = 26
        case newTxHashes = 27
        case getTxns = 28
        case txns = 29
        case getBlockRange = 30
        case blockRange = 31
        case blockManifest = 32
        case getCIDs = 33
        case cidData = 34
    }

    public func estimatedSize() -> Int {
        switch self {
        case .ping, .pong: return 9
        case .wantBlock(let cid): return 3 + cid.utf8.count
        case .block(let cid, let data): return 7 + cid.utf8.count + data.count
        case .dontHave(let cid): return 3 + cid.utf8.count
        case .announceBlock(let cid): return 3 + cid.utf8.count
        case .dhtForward(let cid, _): return 4 + cid.utf8.count
        default: return 256
        }
    }

    public func serialize() -> Data {
        var buf = Data(capacity: estimatedSize())
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
        case .identify(let publicKey, let observedHost, let observedPort, let listenAddrs):
            buf.append(Tag.identify.rawValue)
            buf.appendLengthPrefixedString(publicKey)
            buf.appendLengthPrefixedString(observedHost)
            buf.appendUInt16(observedPort)
            buf.appendUInt16(UInt16(listenAddrs.count))
            for (host, port) in listenAddrs {
                buf.appendLengthPrefixedString(host)
                buf.appendUInt16(port)
            }
        case .dialBack(let nonce, let host, let port):
            buf.append(Tag.dialBack.rawValue)
            buf.appendUInt64(nonce)
            buf.appendLengthPrefixedString(host)
            buf.appendUInt16(port)
        case .dialBackResult(let nonce, let success):
            buf.append(Tag.dialBackResult.rawValue)
            buf.appendUInt64(nonce)
            buf.appendUInt8(success ? 1 : 0)
        case .relayConnect(let srcKey, let dstKey):
            buf.append(Tag.relayConnect.rawValue)
            buf.appendLengthPrefixedString(srcKey)
            buf.appendLengthPrefixedString(dstKey)
        case .relayStatus(let code):
            buf.append(Tag.relayStatus.rawValue)
            buf.appendUInt8(code)
        case .relayData(let peerKey, let data):
            buf.append(Tag.relayData.rawValue)
            buf.appendLengthPrefixedString(peerKey)
            buf.appendLengthPrefixedData(data)
        case .holepunchConnect(let addrs, let nonce):
            buf.append(Tag.holepunchConnect.rawValue)
            buf.appendUInt16(UInt16(addrs.count))
            for (host, port) in addrs {
                buf.appendLengthPrefixedString(host)
                buf.appendUInt16(port)
            }
            buf.appendUInt64(nonce)
        case .holepunchSync(let nonce):
            buf.append(Tag.holepunchSync.rawValue)
            buf.appendUInt64(nonce)
        case .dhtForward(let cid, let ttl):
            buf.append(Tag.dhtForward.rawValue)
            buf.appendLengthPrefixedString(cid)
            buf.appendUInt8(ttl)
        case .announce(let destinationHash, let hops, let payload):
            buf.append(Tag.announce.rawValue)
            buf.appendLengthPrefixedData(destinationHash)
            buf.appendUInt8(hops)
            buf.appendLengthPrefixedData(payload)
        case .pathRequest(let destinationHash):
            buf.append(Tag.pathRequest.rawValue)
            buf.appendLengthPrefixedData(destinationHash)
        case .pathResponse(let destinationHash, let hops, let announcePayload):
            buf.append(Tag.pathResponse.rawValue)
            buf.appendLengthPrefixedData(destinationHash)
            buf.appendUInt8(hops)
            buf.appendLengthPrefixedData(announcePayload)
        case .transportPacket(let data):
            buf.append(Tag.transportPacket.rawValue)
            buf.appendLengthPrefixedData(data)
        case .chainAnnounce(let destinationHash, let hops, let chainData, let announcePayload):
            buf.append(Tag.chainAnnounce.rawValue)
            buf.appendLengthPrefixedData(destinationHash)
            buf.appendUInt8(hops)
            buf.appendLengthPrefixedData(chainData)
            buf.appendLengthPrefixedData(announcePayload)
        case .compactBlock(let chainHash, let headerCID, let txCIDs):
            buf.append(Tag.compactBlock.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendLengthPrefixedString(headerCID)
            buf.appendUInt16(UInt16(txCIDs.count))
            for cid in txCIDs {
                buf.appendLengthPrefixedString(cid)
            }
        case .getBlockTxns(let chainHash, let headerCID, let missingTxCIDs):
            buf.append(Tag.getBlockTxns.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendLengthPrefixedString(headerCID)
            buf.appendUInt16(UInt16(missingTxCIDs.count))
            for cid in missingTxCIDs {
                buf.appendLengthPrefixedString(cid)
            }
        case .blockTxns(let chainHash, let headerCID, let transactions):
            buf.append(Tag.blockTxns.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendLengthPrefixedString(headerCID)
            buf.appendUInt16(UInt16(transactions.count))
            for (cid, data) in transactions {
                buf.appendLengthPrefixedString(cid)
                buf.appendLengthPrefixedData(data)
            }
        case .haveBlock(let cid):
            buf.append(Tag.haveBlock.rawValue)
            buf.appendLengthPrefixedString(cid)
        case .wantBlocks(let cids):
            buf.append(Tag.wantBlocks.rawValue)
            buf.appendUInt16(UInt16(cids.count))
            for cid in cids {
                buf.appendLengthPrefixedString(cid)
            }
        case .newTxHashes(let chainHash, let txHashes):
            buf.append(Tag.newTxHashes.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendUInt16(UInt16(txHashes.count))
            for h in txHashes { buf.appendLengthPrefixedString(h) }
        case .getTxns(let chainHash, let txHashes):
            buf.append(Tag.getTxns.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendUInt16(UInt16(txHashes.count))
            for h in txHashes { buf.appendLengthPrefixedString(h) }
        case .txns(let chainHash, let transactions):
            buf.append(Tag.txns.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendUInt16(UInt16(transactions.count))
            for (h, d) in transactions {
                buf.appendLengthPrefixedString(h)
                buf.appendLengthPrefixedData(d)
            }
        case .getBlockRange(let chainHash, let startIndex, let count):
            buf.append(Tag.getBlockRange.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendUInt64(startIndex)
            buf.appendUInt16(count)
        case .blockRange(let chainHash, let startIndex, let blocks):
            buf.append(Tag.blockRange.rawValue)
            buf.appendLengthPrefixedData(chainHash)
            buf.appendUInt64(startIndex)
            buf.appendUInt16(UInt16(blocks.count))
            for (cid, data) in blocks {
                buf.appendLengthPrefixedString(cid)
                buf.appendLengthPrefixedData(data)
            }
        case .blockManifest(let blockCID, let referencedCIDs):
            buf.append(Tag.blockManifest.rawValue)
            buf.appendLengthPrefixedString(blockCID)
            buf.appendUInt16(UInt16(referencedCIDs.count))
            for cid in referencedCIDs { buf.appendLengthPrefixedString(cid) }
        case .getCIDs(let cids):
            buf.append(Tag.getCIDs.rawValue)
            buf.appendUInt16(UInt16(cids.count))
            for cid in cids { buf.appendLengthPrefixedString(cid) }
        case .cidData(let items):
            buf.append(Tag.cidData.rawValue)
            buf.appendUInt16(UInt16(items.count))
            for (cid, data) in items {
                buf.appendLengthPrefixedString(cid)
                buf.appendLengthPrefixedData(data)
            }
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
            guard let count = reader.readUInt16(), count <= MessageLimits.maxNeighborCount else { return nil }
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
        case .identify:
            guard let publicKey = reader.readString(),
                  let observedHost = reader.readString(),
                  let observedPort = reader.readUInt16(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxListenAddrs else { return nil }
            var addrs = [(String, UInt16)]()
            for _ in 0..<count {
                guard let host = reader.readString(),
                      let port = reader.readUInt16() else { return nil }
                addrs.append((host, port))
            }
            return .identify(publicKey: publicKey, observedHost: observedHost, observedPort: observedPort, listenAddrs: addrs)
        case .dialBack:
            guard let nonce = reader.readUInt64(),
                  let host = reader.readString(),
                  let port = reader.readUInt16() else { return nil }
            return .dialBack(nonce: nonce, host: host, port: port)
        case .dialBackResult:
            guard let nonce = reader.readUInt64(),
                  let flag = reader.readUInt8() else { return nil }
            return .dialBackResult(nonce: nonce, success: flag != 0)
        case .relayConnect:
            guard let srcKey = reader.readString(),
                  let dstKey = reader.readString() else { return nil }
            return .relayConnect(srcKey: srcKey, dstKey: dstKey)
        case .relayStatus:
            guard let code = reader.readUInt8() else { return nil }
            return .relayStatus(code: code)
        case .relayData:
            guard let peerKey = reader.readString(),
                  let data = reader.readData() else { return nil }
            return .relayData(peerKey: peerKey, data: data)
        case .holepunchConnect:
            guard let count = reader.readUInt16(), count <= MessageLimits.maxHolepunchAddrs else { return nil }
            var addrs = [(String, UInt16)]()
            for _ in 0..<count {
                guard let host = reader.readString(),
                      let port = reader.readUInt16() else { return nil }
                addrs.append((host, port))
            }
            guard let nonce = reader.readUInt64() else { return nil }
            return .holepunchConnect(addrs: addrs, nonce: nonce)
        case .holepunchSync:
            guard let nonce = reader.readUInt64() else { return nil }
            return .holepunchSync(nonce: nonce)
        case .dhtForward:
            guard let cid = reader.readString(),
                  let ttl = reader.readUInt8() else { return nil }
            return .dhtForward(cid: cid, ttl: ttl)
        case .announce:
            guard let destHash = reader.readData(),
                  let hops = reader.readUInt8(),
                  let payload = reader.readData() else { return nil }
            return .announce(destinationHash: destHash, hops: hops, payload: payload)
        case .pathRequest:
            guard let destHash = reader.readData() else { return nil }
            return .pathRequest(destinationHash: destHash)
        case .pathResponse:
            guard let destHash = reader.readData(),
                  let hops = reader.readUInt8(),
                  let announcePayload = reader.readData() else { return nil }
            return .pathResponse(destinationHash: destHash, hops: hops, announcePayload: announcePayload)
        case .transportPacket:
            guard let data = reader.readData() else { return nil }
            return .transportPacket(data: data)
        case .chainAnnounce:
            guard let destHash = reader.readData(),
                  let hops = reader.readUInt8(),
                  let chainData = reader.readData(),
                  let announcePayload = reader.readData() else { return nil }
            return .chainAnnounce(destinationHash: destHash, hops: hops, chainData: chainData, announcePayload: announcePayload)
        case .compactBlock:
            guard let chainHash = reader.readData(),
                  let headerCID = reader.readString(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var txCIDs = [String]()
            txCIDs.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                txCIDs.append(cid)
            }
            return .compactBlock(chainHash: chainHash, headerCID: headerCID, txCIDs: txCIDs)
        case .getBlockTxns:
            guard let chainHash = reader.readData(),
                  let headerCID = reader.readString(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var cids = [String]()
            cids.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                cids.append(cid)
            }
            return .getBlockTxns(chainHash: chainHash, headerCID: headerCID, missingTxCIDs: cids)
        case .blockTxns:
            guard let chainHash = reader.readData(),
                  let headerCID = reader.readString(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTransactionCount else { return nil }
            var txns = [(String, Data)]()
            txns.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString(),
                      let data = reader.readData() else { return nil }
                txns.append((cid, data))
            }
            return .blockTxns(chainHash: chainHash, headerCID: headerCID, transactions: txns)
        case .haveBlock:
            guard let cid = reader.readString() else { return nil }
            return .haveBlock(cid: cid)
        case .wantBlocks:
            guard let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var cids = [String]()
            cids.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                cids.append(cid)
            }
            return .wantBlocks(cids: cids)
        case .newTxHashes:
            guard let chainHash = reader.readData(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var hashes = [String]()
            hashes.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let h = reader.readString() else { return nil }
                hashes.append(h)
            }
            return .newTxHashes(chainHash: chainHash, txHashes: hashes)
        case .getTxns:
            guard let chainHash = reader.readData(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var hashes = [String]()
            hashes.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let h = reader.readString() else { return nil }
                hashes.append(h)
            }
            return .getTxns(chainHash: chainHash, txHashes: hashes)
        case .txns:
            guard let chainHash = reader.readData(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTransactionCount else { return nil }
            var txs = [(String, Data)]()
            txs.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let h = reader.readString(), let d = reader.readData() else { return nil }
                txs.append((h, d))
            }
            return .txns(chainHash: chainHash, transactions: txs)
        case .getBlockRange:
            guard let chainHash = reader.readData(),
                  let startIndex = reader.readUInt64(),
                  let count = reader.readUInt16() else { return nil }
            return .getBlockRange(chainHash: chainHash, startIndex: startIndex, count: count)
        case .blockRange:
            guard let chainHash = reader.readData(),
                  let startIndex = reader.readUInt64(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTransactionCount else { return nil }
            var blocks = [(String, Data)]()
            blocks.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString(), let data = reader.readData() else { return nil }
                blocks.append((cid, data))
            }
            return .blockRange(chainHash: chainHash, startIndex: startIndex, blocks: blocks)
        case .blockManifest:
            guard let blockCID = reader.readString(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var cids = [String]()
            cids.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                cids.append(cid)
            }
            return .blockManifest(blockCID: blockCID, referencedCIDs: cids)
        case .getCIDs:
            guard let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var cids = [String]()
            cids.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                cids.append(cid)
            }
            return .getCIDs(cids: cids)
        case .cidData:
            guard let count = reader.readUInt16(), count <= MessageLimits.maxTransactionCount else { return nil }
            var items = [(String, Data)]()
            items.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString(), let data = reader.readData() else { return nil }
                items.append((cid, data))
            }
            return .cidData(items: items)
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

public struct PeerEndpoint: Sendable, Equatable, Hashable {
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
    @inline(__always)
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }
    @inline(__always)
    mutating func appendUInt16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    @inline(__always)
    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    @inline(__always)
    mutating func appendUInt64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    @inline(__always)
    mutating func appendLengthPrefixedString(_ string: String) {
        let utf8 = string.utf8
        appendUInt16(UInt16(utf8.count))
        append(contentsOf: utf8)
    }
    @inline(__always)
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
        guard let len = readUInt16(), len <= MessageLimits.maxStringLength else { return nil }
        guard remaining >= Int(len) else { return nil }
        defer { offset += Int(len) }
        let start = data.startIndex + offset
        return String(data: data[start..<start+Int(len)], encoding: .utf8)
    }

    mutating func readData() -> Data? {
        guard let len = readUInt32(), len <= MessageLimits.maxDataPayload else { return nil }
        guard remaining >= Int(len) else { return nil }
        defer { offset += Int(len) }
        let start = data.startIndex + offset
        return Data(data[start..<start+Int(len)])
    }
}
