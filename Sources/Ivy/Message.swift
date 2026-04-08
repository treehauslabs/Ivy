import Foundation

public enum Message: Sendable {
    case ping(nonce: UInt64)
    case pong(nonce: UInt64)
    case block(cid: String, data: Data)
    case dontHave(cid: String)
    case findNode(target: Data, fee: UInt64 = 0)
    case neighbors([PeerEndpoint])
    case announceBlock(cid: String)

    case identify(publicKey: String, observedHost: String, observedPort: UInt16, listenAddrs: [(String, UInt16)], signature: Data)
    case dhtForward(cid: String, ttl: UInt8, fee: UInt64 = 0, target: Data? = nil, selector: String? = nil)

    case chainAnnounce(destinationHash: Data, hops: UInt8, chainData: Data)
    case compactBlock(chainHash: Data, headerCID: String, txCIDs: [String])
    case getBlockTxns(chainHash: Data, headerCID: String, missingTxCIDs: [String])
    case blockTxns(chainHash: Data, headerCID: String, transactions: [(String, Data)])

    case wantBlocks(cids: [String])

    case newTxHashes(chainHash: Data, txHashes: [String])
    case getTxns(chainHash: Data, txHashes: [String])
    case txns(chainHash: Data, transactions: [(String, Data)])

    case getBlockRange(chainHash: Data, startIndex: UInt64, count: UInt16)
    case blockRange(chainHash: Data, startIndex: UInt64, blocks: [(String, Data)])

    case miningChallenge(hashPrefix: Data, blockTargetDifficulty: Data, noncePrefix: Data)
    case miningChallengeSolution(nonce: UInt64, hash: Data, blockNonce: UInt64?)

    case pexRequest(nonce: UInt64)
    case pexResponse(nonce: UInt64, peers: [PeerEndpoint])

    case getZoneInventory(nodeHash: Data, limit: UInt16)
    case zoneInventory(cids: [String])
    case haveCIDs(nonce: UInt64, cids: [String])
    case haveCIDsResult(nonce: UInt64, have: [String])

    // Ivy economic layer
    case findPins(cid: String, fee: UInt64)
    case pins(announcements: [(publicKey: String, selector: String)])
    case pinAnnounce(rootCID: String, selector: String, publicKey: String, expiry: UInt64, signature: Data, fee: UInt64)
    case pinStored(rootCID: String)
    case feeExhausted(consumed: UInt64)
    case directOffer(cid: String, host: String, port: UInt16, size: UInt64, timeout: UInt64)
    case deliveryAck(requestId: UInt64)
    case balanceCheck(sequence: UInt64, balance: Int64)
    case balanceLog(fromSequence: UInt64, operations: [(sequence: UInt64, amount: Int64, requestId: UInt64)])
    case peerMessage(topic: String, payload: Data)
    case blocks(rootCID: String, items: [(cid: String, data: Data)])
    case settlementProof(txHash: String, amount: UInt64, chainId: String)

    private enum Tag: UInt8 {
        case ping = 0
        case pong = 1
        // tag 2 removed (wantBlock → use dhtForward with ttl:0)
        case block = 3
        case dontHave = 4
        case findNode = 5
        case neighbors = 6
        case announceBlock = 7
        case identify = 8
        // tags 9-10 removed (dialBack, dialBackResult — AutoNAT removed)
        case getZoneInventory = 11
        case zoneInventory = 12
        case haveCIDs = 13
        case haveCIDsResult = 14
        case dhtForward = 16
        case chainAnnounce = 21
        case compactBlock = 22
        case getBlockTxns = 23
        case blockTxns = 24
        case wantBlocks = 26
        case newTxHashes = 27
        case getTxns = 28
        case txns = 29
        case getBlockRange = 30
        case blockRange = 31
        // tags 32-34 removed (blockManifest, getCIDs, cidData)
        case miningChallenge = 35
        case miningChallengeSolution = 36
        case pexRequest = 37
        case pexResponse = 38
        // Ivy economic layer (tags 40-55)
        case findPins = 40
        case pins = 41
        case pinAnnounce = 42
        case pinStored = 43
        case feeExhausted = 44
        case directOffer = 45
        case deliveryAck = 46
        case balanceCheck = 47
        case balanceLog = 48
        case peerMessage = 49
        case blocks = 50
        case settlementProof = 51
    }

    public func estimatedSize() -> Int {
        switch self {
        case .ping, .pong: return 9
        case .block(let cid, let data): return 7 + cid.utf8.count + data.count
        case .dontHave(let cid): return 3 + cid.utf8.count
        case .announceBlock(let cid): return 3 + cid.utf8.count
        case .dhtForward(let cid, _, _, _, _): return 4 + cid.utf8.count
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
        case .block(let cid, let data):
            buf.append(Tag.block.rawValue)
            buf.appendLengthPrefixedString(cid)
            buf.appendLengthPrefixedData(data)
        case .dontHave(let cid):
            buf.append(Tag.dontHave.rawValue)
            buf.appendLengthPrefixedString(cid)
        case .findNode(let target, let fee):
            buf.append(Tag.findNode.rawValue)
            buf.appendLengthPrefixedData(target)
            buf.appendUInt64(fee)
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
        case .identify(let publicKey, let observedHost, let observedPort, let listenAddrs, let signature):
            buf.append(Tag.identify.rawValue)
            buf.appendLengthPrefixedString(publicKey)
            buf.appendLengthPrefixedString(observedHost)
            buf.appendUInt16(observedPort)
            buf.appendUInt16(UInt16(listenAddrs.count))
            for (host, port) in listenAddrs {
                buf.appendLengthPrefixedString(host)
                buf.appendUInt16(port)
            }
            buf.appendLengthPrefixedData(signature)
        case .dhtForward(let cid, let ttl, let fee, let target, let selector):
            buf.append(Tag.dhtForward.rawValue)
            buf.appendLengthPrefixedString(cid)
            buf.appendUInt8(ttl)
            buf.appendUInt64(fee)
            buf.appendUInt8(target != nil ? 1 : 0)
            if let target { buf.appendLengthPrefixedData(target) }
            buf.appendUInt8(selector != nil ? 1 : 0)
            if let selector { buf.appendLengthPrefixedString(selector) }
        case .chainAnnounce(let destinationHash, let hops, let chainData):
            buf.append(Tag.chainAnnounce.rawValue)
            buf.appendLengthPrefixedData(destinationHash)
            buf.appendUInt8(hops)
            buf.appendLengthPrefixedData(chainData)
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
        case .miningChallenge(let hashPrefix, let blockTarget, let noncePrefix):
            buf.append(Tag.miningChallenge.rawValue)
            buf.appendLengthPrefixedData(hashPrefix)
            buf.appendLengthPrefixedData(blockTarget)
            buf.appendLengthPrefixedData(noncePrefix)
        case .miningChallengeSolution(let nonce, let hash, let blockNonce):
            buf.append(Tag.miningChallengeSolution.rawValue)
            buf.appendUInt64(nonce)
            buf.appendLengthPrefixedData(hash)
            buf.appendUInt8(blockNonce != nil ? 1 : 0)
            if let bn = blockNonce { buf.appendUInt64(bn) }
        case .pexRequest(let nonce):
            buf.append(Tag.pexRequest.rawValue)
            buf.appendUInt64(nonce)
        case .pexResponse(let nonce, let peers):
            buf.append(Tag.pexResponse.rawValue)
            buf.appendUInt64(nonce)
            buf.appendUInt16(UInt16(peers.count))
            for peer in peers {
                buf.appendLengthPrefixedString(peer.publicKey)
                buf.appendLengthPrefixedString(peer.host)
                buf.appendUInt16(peer.port)
            }
        case .getZoneInventory(let nodeHash, let limit):
            buf.append(Tag.getZoneInventory.rawValue)
            buf.appendLengthPrefixedData(nodeHash)
            buf.appendUInt16(limit)
        case .zoneInventory(let cids):
            buf.append(Tag.zoneInventory.rawValue)
            buf.appendUInt16(UInt16(cids.count))
            for cid in cids { buf.appendLengthPrefixedString(cid) }
        case .haveCIDs(let nonce, let cids):
            buf.append(Tag.haveCIDs.rawValue)
            buf.appendUInt64(nonce)
            buf.appendUInt16(UInt16(cids.count))
            for cid in cids { buf.appendLengthPrefixedString(cid) }
        case .haveCIDsResult(let nonce, let have):
            buf.append(Tag.haveCIDsResult.rawValue)
            buf.appendUInt64(nonce)
            buf.appendUInt16(UInt16(have.count))
            for cid in have { buf.appendLengthPrefixedString(cid) }
        case .findPins(let cid, let fee):
            buf.append(Tag.findPins.rawValue)
            buf.appendLengthPrefixedString(cid)
            buf.appendUInt64(fee)
        case .pins(let announcements):
            buf.append(Tag.pins.rawValue)
            buf.appendUInt16(UInt16(announcements.count))
            for a in announcements {
                buf.appendLengthPrefixedString(a.publicKey)
                buf.appendLengthPrefixedString(a.selector)
            }
        case .pinAnnounce(let rootCID, let selector, let publicKey, let expiry, let signature, let fee):
            buf.append(Tag.pinAnnounce.rawValue)
            buf.appendLengthPrefixedString(rootCID)
            buf.appendLengthPrefixedString(selector)
            buf.appendLengthPrefixedString(publicKey)
            buf.appendUInt64(expiry)
            buf.appendLengthPrefixedData(signature)
            buf.appendUInt64(fee)
        case .pinStored(let rootCID):
            buf.append(Tag.pinStored.rawValue)
            buf.appendLengthPrefixedString(rootCID)
        case .feeExhausted(let consumed):
            buf.append(Tag.feeExhausted.rawValue)
            buf.appendUInt64(consumed)
        case .directOffer(let cid, let host, let port, let size, let timeout):
            buf.append(Tag.directOffer.rawValue)
            buf.appendLengthPrefixedString(cid)
            buf.appendLengthPrefixedString(host)
            buf.appendUInt16(port)
            buf.appendUInt64(size)
            buf.appendUInt64(timeout)
        case .deliveryAck(let requestId):
            buf.append(Tag.deliveryAck.rawValue)
            buf.appendUInt64(requestId)
        case .balanceCheck(let sequence, let balance):
            buf.append(Tag.balanceCheck.rawValue)
            buf.appendUInt64(sequence)
            buf.appendUInt64(UInt64(bitPattern: balance))
        case .balanceLog(let fromSequence, let operations):
            buf.append(Tag.balanceLog.rawValue)
            buf.appendUInt64(fromSequence)
            buf.appendUInt16(UInt16(operations.count))
            for op in operations {
                buf.appendUInt64(op.sequence)
                buf.appendUInt64(UInt64(bitPattern: op.amount))
                buf.appendUInt64(op.requestId)
            }
        case .peerMessage(let topic, let payload):
            buf.append(Tag.peerMessage.rawValue)
            buf.appendLengthPrefixedString(topic)
            buf.appendLengthPrefixedData(payload)
        case .blocks(let rootCID, let items):
            buf.append(Tag.blocks.rawValue)
            buf.appendLengthPrefixedString(rootCID)
            buf.appendUInt16(UInt16(items.count))
            for item in items {
                buf.appendLengthPrefixedString(item.cid)
                buf.appendLengthPrefixedData(item.data)
            }
        case .settlementProof(let txHash, let amount, let chainId):
            buf.append(Tag.settlementProof.rawValue)
            buf.appendLengthPrefixedString(txHash)
            buf.appendUInt64(amount)
            buf.appendLengthPrefixedString(chainId)
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
        case .block:
            guard let cid = reader.readString(),
                  let payload = reader.readData() else { return nil }
            return .block(cid: cid, data: payload)
        case .dontHave:
            guard let cid = reader.readString() else { return nil }
            return .dontHave(cid: cid)
        case .findNode:
            guard let target = reader.readData() else { return nil }
            let fee = reader.readUInt64() ?? 0
            return .findNode(target: target, fee: fee)
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
            guard let signature = reader.readData() else { return nil }
            return .identify(publicKey: publicKey, observedHost: observedHost, observedPort: observedPort, listenAddrs: addrs, signature: signature)
        case .dhtForward:
            guard let cid = reader.readString(),
                  let ttl = reader.readUInt8() else { return nil }
            let fee = reader.readUInt64() ?? 0
            var target: Data? = nil
            if let hasTarget = reader.readUInt8(), hasTarget == 1 { target = reader.readData() }
            var selector: String? = nil
            if let hasSel = reader.readUInt8(), hasSel == 1 { selector = reader.readString() }
            return .dhtForward(cid: cid, ttl: ttl, fee: fee, target: target, selector: selector)
        case .chainAnnounce:
            guard let destHash = reader.readData(),
                  let hops = reader.readUInt8(),
                  let chainData = reader.readData() else { return nil }
            return .chainAnnounce(destinationHash: destHash, hops: hops, chainData: chainData)
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
        case .miningChallenge:
            guard let hashPrefix = reader.readData(),
                  let blockTarget = reader.readData(),
                  let noncePrefix = reader.readData() else { return nil }
            return .miningChallenge(hashPrefix: hashPrefix, blockTargetDifficulty: blockTarget, noncePrefix: noncePrefix)
        case .miningChallengeSolution:
            guard let nonce = reader.readUInt64(),
                  let hash = reader.readData(),
                  let hasBlockNonce = reader.readUInt8() else { return nil }
            let blockNonce: UInt64? = hasBlockNonce == 1 ? reader.readUInt64() : nil
            return .miningChallengeSolution(nonce: nonce, hash: hash, blockNonce: blockNonce)
        case .pexRequest:
            guard let nonce = reader.readUInt64() else { return nil }
            return .pexRequest(nonce: nonce)
        case .pexResponse:
            guard let nonce = reader.readUInt64(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxPexPeerCount else { return nil }
            var peers = [PeerEndpoint]()
            peers.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let key = reader.readString(),
                      let host = reader.readString(),
                      let port = reader.readUInt16() else { return nil }
                peers.append(PeerEndpoint(publicKey: key, host: host, port: port))
            }
            return .pexResponse(nonce: nonce, peers: peers)
        case .getZoneInventory:
            guard let nodeHash = reader.readData(),
                  let limit = reader.readUInt16() else { return nil }
            return .getZoneInventory(nodeHash: nodeHash, limit: limit)
        case .zoneInventory:
            guard let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var cids = [String]()
            cids.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                cids.append(cid)
            }
            return .zoneInventory(cids: cids)
        case .haveCIDs:
            guard let nonce = reader.readUInt64(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var cids = [String]()
            cids.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                cids.append(cid)
            }
            return .haveCIDs(nonce: nonce, cids: cids)
        case .haveCIDsResult:
            guard let nonce = reader.readUInt64(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTxCIDCount else { return nil }
            var have = [String]()
            have.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString() else { return nil }
                have.append(cid)
            }
            return .haveCIDsResult(nonce: nonce, have: have)
        case .findPins:
            guard let cid = reader.readString(),
                  let fee = reader.readUInt64() else { return nil }
            return .findPins(cid: cid, fee: fee)
        case .pins:
            guard let count = reader.readUInt16(), count <= MessageLimits.maxNeighborCount else { return nil }
            var announcements = [(publicKey: String, selector: String)]()
            for _ in 0..<count {
                guard let pk = reader.readString(), let sel = reader.readString() else { return nil }
                announcements.append((publicKey: pk, selector: sel))
            }
            return .pins(announcements: announcements)
        case .pinAnnounce:
            guard let rootCID = reader.readString(),
                  let selector = reader.readString(),
                  let publicKey = reader.readString(),
                  let expiry = reader.readUInt64(),
                  let signature = reader.readData(),
                  let fee = reader.readUInt64() else { return nil }
            return .pinAnnounce(rootCID: rootCID, selector: selector, publicKey: publicKey, expiry: expiry, signature: signature, fee: fee)
        case .pinStored:
            guard let rootCID = reader.readString() else { return nil }
            return .pinStored(rootCID: rootCID)
        case .feeExhausted:
            guard let consumed = reader.readUInt64() else { return nil }
            return .feeExhausted(consumed: consumed)
        case .directOffer:
            guard let cid = reader.readString(),
                  let host = reader.readString(),
                  let port = reader.readUInt16(),
                  let size = reader.readUInt64(),
                  let timeout = reader.readUInt64() else { return nil }
            return .directOffer(cid: cid, host: host, port: port, size: size, timeout: timeout)
        case .deliveryAck:
            guard let requestId = reader.readUInt64() else { return nil }
            return .deliveryAck(requestId: requestId)
        case .balanceCheck:
            guard let sequence = reader.readUInt64(),
                  let rawBalance = reader.readUInt64() else { return nil }
            return .balanceCheck(sequence: sequence, balance: Int64(bitPattern: rawBalance))
        case .balanceLog:
            guard let fromSequence = reader.readUInt64(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTransactionCount else { return nil }
            var ops = [(sequence: UInt64, amount: Int64, requestId: UInt64)]()
            for _ in 0..<count {
                guard let seq = reader.readUInt64(),
                      let rawAmt = reader.readUInt64(),
                      let rid = reader.readUInt64() else { return nil }
                ops.append((sequence: seq, amount: Int64(bitPattern: rawAmt), requestId: rid))
            }
            return .balanceLog(fromSequence: fromSequence, operations: ops)
        case .peerMessage:
            guard let topic = reader.readString(),
                  let payload = reader.readData() else { return nil }
            return .peerMessage(topic: topic, payload: payload)
        case .blocks:
            guard let rootCID = reader.readString(),
                  let count = reader.readUInt16(), count <= MessageLimits.maxTransactionCount else { return nil }
            var items = [(cid: String, data: Data)]()
            items.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let cid = reader.readString(),
                      let data = reader.readData() else { return nil }
                items.append((cid: cid, data: data))
            }
            return .blocks(rootCID: rootCID, items: items)
        case .settlementProof:
            guard let txHash = reader.readString(),
                  let amount = reader.readUInt64(),
                  let chainId = reader.readString() else { return nil }
            return .settlementProof(txHash: txHash, amount: amount, chainId: chainId)
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
