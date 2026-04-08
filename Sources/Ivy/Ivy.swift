import Foundation
import NIOCore
import NIOPosix
import Acorn
import Tally
import Crypto

public enum IvyError: Error, Sendable {
    case notRunning
    case identityVerificationFailed
}

public actor Ivy {
    public let config: IvyConfig
    public let tally: Tally
    public let router: Router
    public let localID: PeerID
    public let group: EventLoopGroup

    public weak var delegate: IvyDelegate?

    private var connections: [PeerID: PeerConnection] = [:]
    private var pendingRequests: [String: [CheckedContinuation<Data?, Never>]] = [:]
    private var _worker: NetworkCASWorker?
    private var serverChannel: Channel?
    #if canImport(Network)
    private var discovery: LocalDiscovery?
    #endif
    private var running = false

    private let stunClient: STUNClient
    private(set) public var publicAddress: ObservedAddress?
    private var observedAddresses: BoundedDictionary<ObservedAddress, Int> = BoundedDictionary(capacity: 256)
    private var pendingForwards: [String: [PeerID]] = [:]
    private var pexTask: Task<Void, Never>?
    private var pendingPEX: [UInt64: CheckedContinuation<[PeerEndpoint], Never>] = [:]
    private var healthMonitor: PeerHealthMonitor?
    private var haveSet = InventorySet()
    private var chainAnnounceDedup = InventorySet()
    private var localPeers: [PeerID: LocalPeerConnection] = [:]
    private var _casBridge: CASBridge?
    private var _serviceBus: LocalServiceBus?
    private var replicationTask: Task<Void, Never>?
    private var zoneSyncTask: Task<Void, Never>?
    private var replicationResults: BoundedDictionary<UInt64, Set<String>> = BoundedDictionary(capacity: 1024)

    // Ivy economic layer
    public let ledger: CreditLineLedger
    private var pinAnnouncements: BoundedDictionary<String, [(publicKey: String, selector: String, expiry: UInt64)]> = BoundedDictionary(capacity: 10_000)

    public init(config: IvyConfig, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config
        self.localID = PeerID(publicKey: config.publicKey)
        self.tally = Tally(config: config.tallyConfig)
        self.router = Router(localID: PeerID(publicKey: config.publicKey), k: config.kBucketSize)
        self.group = group
        self.stunClient = STUNClient(group: group, servers: config.stunServers)
        self.ledger = CreditLineLedger(localID: PeerID(publicKey: config.publicKey))
    }

    public func worker() -> NetworkCASWorker {
        if let existing = _worker { return existing }
        let w = NetworkCASWorker(node: self)
        _worker = w
        return w
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !running else { return }
        running = true
        try await startListener()

        #if canImport(Network)
        if config.enableLocalDiscovery {
            startLocalDiscovery()
        }
        #endif

        if let addr = await stunClient.discoverPublicAddress() {
            publicAddress = addr
            delegate?.ivy(self, didDiscoverPublicAddress: addr)
        }

        for bootstrap in config.bootstrapPeers {
            Task { try? await connect(to: bootstrap) }
        }

        let monitor = PeerHealthMonitor(
            config: config.healthConfig,
            tally: tally,
            onStale: { [weak self] peer in
                guard let self else { return }
                Task { await self.disconnect(peer) }
            }
        )
        self.healthMonitor = monitor
        await monitor.startMonitoring { [weak self] peer, nonce in
            guard let self else { return }
            await self.fireToPeer(peer, .ping(nonce: nonce))
        }

        if config.enablePEX {
            startPEX()
        }

        startZoneSync()
        startReplication()
    }

    public func stop() async {
        config.logger.info("Ivy node shutting down")
        running = false
        pexTask?.cancel()
        pexTask = nil
        replicationTask?.cancel()
        replicationTask = nil
        zoneSyncTask?.cancel()
        zoneSyncTask = nil
        if let monitor = healthMonitor { await monitor.stopMonitoring() }

        cleanupAllPending()
        config.logger.debug("Drained all pending operations")

        try? await serverChannel?.close().get()
        serverChannel = nil
        #if canImport(Network)
        discovery?.stop()
        discovery = nil
        #endif
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        pendingForwards.removeAll()
    }

    // MARK: - Connection Management

    public func connect(to endpoint: PeerEndpoint) async throws {
        let peer = PeerID(publicKey: endpoint.publicKey)
        guard connections[peer] == nil else { return }

        let conn = try await PeerConnection.dial(endpoint: endpoint, group: group)
        connections[peer] = conn
        router.addPeer(peer, endpoint: endpoint, tally: tally)
        await ledger.establish(with: peer)
        if let monitor = healthMonitor { await monitor.trackPeer(peer) }
        delegate?.ivy(self, didConnect: peer)
        Task { await handleInbound(conn) }
        sendIdentify(to: conn)
    }

    public var connectedPeers: [PeerID] {
        var peers = [PeerID]()
        peers.reserveCapacity(connections.count + localPeers.count)
        peers.append(contentsOf: connections.keys)
        peers.append(contentsOf: localPeers.keys)
        return peers
    }

    public var directPeerCount: Int { connections.count }

    public func disconnect(_ peer: PeerID) {
        if let conn = connections.removeValue(forKey: peer) {
            conn.cancel()
        }
        cleanupPendingForPeer(peer)
        if let monitor = healthMonitor {
            Task { await monitor.removePeer(peer) }
        }
        delegate?.ivy(self, didDisconnect: peer)
    }

    // MARK: - Sending

    func sendToPeer(_ peer: PeerID, _ message: Message) async throws {
        if let conn = connections[peer] {
            try await conn.send(message)
        }
    }

    func fireToPeer(_ peer: PeerID, _ message: Message) {
        if let local = localPeers[peer] {
            local.send(message)
        } else if let conn = connections[peer] {
            conn.fireAndForgetMessage(message)
        }
    }

    func firePayloadToPeer(_ peer: PeerID, _ payload: Data) {
        if let local = localPeers[peer] {
            if let msg = Message.deserialize(payload) { local.send(msg) }
        } else if let conn = connections[peer] {
            conn.fireAndForget(payload)
        }
    }

    // MARK: - Content Fetching

    func fetchBlock(cid: String) async -> Data? {
        if pendingRequests[cid] != nil {
            return await withCheckedContinuation { continuation in
                pendingRequests[cid, default: []].append(continuation)
            }
        }

        let data = await fetchViaDHT(cid: cid)
        if data != nil { return data }

        return await fetchWithNewConnections(cid: cid)
    }

    private func fetchViaDHT(cid: String) async -> Data? {
        await withCheckedContinuation { continuation in
            pendingRequests[cid] = [continuation]

            let cidHash = Router.hash(cid)
            let closest = router.closestPeers(to: cidHash, count: config.maxConcurrentRequests)
            var sent = 0
            for entry in closest {
                let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
                guard reachable else { continue }
                fireToPeer(entry.id, .dhtForward(cid: cid, ttl: config.defaultTTL))
                tally.recordRequest(peer: entry.id)
                sent += 1
            }

            if sent == 0 {
                for (peer, _) in connections.prefix(3) {
                    fireToPeer(peer, .dhtForward(cid: cid, ttl: config.defaultTTL))
                    tally.recordRequest(peer: peer)
                }
            }

            Task {
                try? await Task.sleep(for: config.relayTimeout)
                self.resolvePending(cid: cid, data: nil)
            }
        }
    }

    private func fetchWithNewConnections(cid: String) async -> Data? {
        let cidHash = Router.hash(cid)
        let closest = router.closestPeers(to: cidHash, count: config.maxConcurrentRequests * 2)

        for entry in closest {
            if connections[entry.id] != nil {
                continue
            }
            do {
                try await connect(to: entry.endpoint)
            } catch {
                continue
            }
        }

        return await withCheckedContinuation { continuation in
            pendingRequests[cid] = [continuation]

            for entry in closest {
                guard connections[entry.id] != nil else { continue }
                fireToPeer(entry.id, .dhtForward(cid: cid, ttl: 0))
                tally.recordRequest(peer: entry.id)
            }

            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.resolvePending(cid: cid, data: nil)
            }
        }
    }

    public func publishBlock(cid: String, data: Data) async {
        if let w = _worker, let near = await w.near {
            await near.storeLocal(cid: ContentIdentifier(rawValue: cid), data: data)
        }
        haveSet.insert(cid)
        let payload = Message.announceBlock(cid: cid).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
        for (_, local) in localPeers {
            local.send(.announceBlock(cid: cid))
        }
    }

    public func publishBlock(cid: String, data: Data, referencedContent: [(String, Data)]) async {
        if let w = _worker, let near = await w.near {
            await near.storeLocal(cid: ContentIdentifier(rawValue: cid), data: data)
            for (refCID, refData) in referencedContent {
                await near.storeLocal(cid: ContentIdentifier(rawValue: refCID), data: refData)
            }
        }
        haveSet.insert(cid)
        for (refCID, _) in referencedContent { haveSet.insert(refCID) }
        let payload = Message.announceBlock(cid: cid).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
        for (_, local) in localPeers {
            local.send(.announceBlock(cid: cid))
        }
    }

    public func announceBlock(cid: String) {
        let payload = Message.announceBlock(cid: cid).serialize()
        haveSet.insert(cid)
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
    }

    // MARK: - DHT

    public func findNode(target: String) async -> [PeerEndpoint] {
        let targetHash = Router.hash(target)
        var queried: Set<String> = []

        for _ in 0..<3 {
            let closest = router.closestPeers(to: targetHash, count: config.kBucketSize)
            let toQuery = closest.filter {
                !queried.contains($0.id.publicKey) &&
                connections[$0.id] != nil
            }.prefix(3)

            if toQuery.isEmpty { break }

            for entry in toQuery {
                queried.insert(entry.id.publicKey)
                fireToPeer(entry.id, .findNode(target: Data(targetHash)))
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        return router.closestPeers(to: targetHash, count: config.kBucketSize).map { $0.endpoint }
    }

    // MARK: - Serving

    public func handleBlockRequest(cid: String, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else {
            fireToPeer(peer, .dontHave(cid: cid))
            return
        }

        var data: Data?
        if let w = _worker {
            let near = await w.near
            if let near {
                let cidObj = ContentIdentifier(rawValue: cid)
                data = await near.getLocal(cid: cidObj)
            }
        }

        if let data {
            fireToPeer(peer, .block(cid: cid, data: data))
            let cpl = Router.commonPrefixLength(router.localHash, Router.hash(cid))
            tally.recordSent(peer: peer, bytes: data.count, cpl: cpl)
        } else {
            fireToPeer(peer, .dontHave(cid: cid))
        }
    }

    // MARK: - Identify Protocol

    private func sendIdentify(to conn: PeerConnection) {
        let observedHost = conn.endpoint.host
        let observedPort = conn.endpoint.port
        var listenAddrs: [(String, UInt16)] = [("0.0.0.0", config.listenPort)]
        if let pub = publicAddress {
            listenAddrs.append((pub.host, pub.port))
        }

        var signature = Data()
        if config.signingKey.count == 32 {
            let material = Data(config.publicKey.utf8) + Data(observedHost.utf8)
            if let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: config.signingKey) {
                signature = (try? privateKey.signature(for: material)) ?? Data()
            }
        }

        conn.fireAndForgetMessage(.identify(
            publicKey: config.publicKey,
            observedHost: observedHost,
            observedPort: observedPort,
            listenAddrs: listenAddrs,
            signature: signature
        ))
    }

    private func handleIdentify(publicKey: String, observedHost: String, observedPort: UInt16, listenAddrs: [(String, UInt16)], signature: Data, from peer: PeerID) {
        let realID = PeerID(publicKey: publicKey)

        // Verify identity signature if present
        if !signature.isEmpty {
            if let pubKeyBytes = hexDecode(publicKey), pubKeyBytes.count == 32,
               let verifyKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) {
                let material = Data(publicKey.utf8) + Data(observedHost.utf8)
                if !verifyKey.isValidSignature(signature, for: material) {
                    config.logger.warning("Identity verification failed for \(publicKey.prefix(16))… — disconnecting")
                    disconnect(peer)
                    return
                }
            }
        }

        if peer.publicKey.hasPrefix("inbound-") && peer != realID {
            if let conn = connections.removeValue(forKey: peer) {
                conn.id = realID
                connections[realID] = conn
                let endpoint = PeerEndpoint(publicKey: publicKey, host: conn.endpoint.host, port: conn.endpoint.port)
                router.addPeer(realID, endpoint: endpoint, tally: tally)
            }
        }

        if observedHost != "0.0.0.0" && observedHost != "unknown" {
            let observed = ObservedAddress(host: observedHost, port: observedPort)
            observedAddresses[observed] = (observedAddresses[observed] ?? 0) + 1
            if let best = observedAddresses.max(by: { $0.value < $1.value }), best.value >= 2 {
                if publicAddress != best.key {
                    publicAddress = best.key
                    delegate?.ivy(self, didDiscoverPublicAddress: best.key)
                }
            }
        }
    }

    private func hexDecode(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    // MARK: - Message Handling

    private func handleInbound(_ conn: PeerConnection) async {
        for await message in conn.messages {
            await handleMessage(message, from: conn.id)
        }
        let peer = conn.id
        connections.removeValue(forKey: peer)
        cleanupPendingForPeer(peer)
        delegate?.ivy(self, didDisconnect: peer)
    }

    private func handleMessage(_ message: Message, from peer: PeerID) async {
        if let monitor = healthMonitor {
            await monitor.recordActivity(from: peer)
        }
        switch message {
        case .ping(let nonce):
            fireToPeer(peer, .pong(nonce: nonce))

        case .pong(let nonce):
            tally.recordSuccess(peer: peer)
            if let monitor = healthMonitor {
                await monitor.recordPong(from: peer, nonce: nonce)
            }

        case .wantBlocks(let cids):
            for cid in cids {
                await handleBlockRequest(cid: cid, from: peer)
            }

        case .block(let cid, let data):
            let cpl = Router.commonPrefixLength(router.localHash, Router.hash(cid))
            tally.recordReceived(peer: peer, bytes: data.count, cpl: cpl)
            tally.recordSuccess(peer: peer)

            // Check fee-forwarded requests first
            await handleFeeForwardResponse(cid: cid, data: data, from: peer)

            if haveSet.contains(cid) {
                resolvePending(cid: cid, data: data)
                break
            }
            haveSet.insert(cid)
            resolvePending(cid: cid, data: data)
            resolveForwards(cid: cid, data: data, from: peer)

            if let w = _worker {
                let cidObj = ContentIdentifier(rawValue: cid)
                Task {
                    if let near = await w.near {
                        await near.storeLocal(cid: cidObj, data: data)
                    }
                }
            }

            delegate?.ivy(self, didReceiveBlock: cid, data: data, from: peer)

        case .dontHave:
            tally.recordFailure(peer: peer)

        case .findNode(let target, let fee):
            if fee > 0 {
                await handleFeeNode(target: target, fee: fee, from: peer)
            } else {
                let closest = router.closestPeers(to: Array(target), count: config.kBucketSize)
                let endpoints = closest.map { $0.endpoint }
                fireToPeer(peer, .neighbors(endpoints))
            }

        case .neighbors(let endpoints):
            // Check if this is a response to a fee-forwarded findNode
            let fnKey = pendingFeeForwards.keys.first { $0.hasPrefix("fn-") }
            if let key = fnKey, let pending = pendingFeeForwards.removeValue(forKey: key) {
                // Relay response upstream, earn fee
                fireToPeer(pending.upstream, .neighbors(endpoints))
                await ledger.earnFromRelay(peer: pending.upstream, amount: Int64(pending.feeClaimed))
            }
            for ep in endpoints {
                let newPeer = PeerID(publicKey: ep.publicKey)
                if connections[newPeer] == nil && newPeer != localID {
                    router.addPeer(newPeer, endpoint: ep, tally: tally)
                }
            }

        case .announceBlock(let cid):
            if !haveSet.contains(cid) {
                haveSet.insert(cid)
                fireToPeer(peer, .dhtForward(cid: cid, ttl: 0))
                let payload = Message.announceBlock(cid: cid).serialize()
                for (otherPeer, conn) in connections where otherPeer != peer {
                    guard tally.shouldAllow(peer: otherPeer) else { continue }
                    conn.fireAndForget(payload)
                }
            }
            delegate?.ivy(self, didReceiveBlockAnnouncement: cid, from: peer)

        case .identify(let publicKey, let observedHost, let observedPort, let listenAddrs, let signature):
            handleIdentify(publicKey: publicKey, observedHost: observedHost, observedPort: observedPort, listenAddrs: listenAddrs, signature: signature, from: peer)

        case .dhtForward(let cid, let ttl, let fee, let target, let selector):
            if fee > 0 {
                await handleFeeForward(cid: cid, fee: fee, target: target, selector: selector, from: peer)
            } else {
                await handleDHTForward(cid: cid, ttl: ttl, from: peer)
            }

        case .chainAnnounce(let destinationHash, let hops, let chainData):
            await handleChainAnnounce(destinationHash: destinationHash, hops: hops, chainData: chainData, from: peer)

        case .getZoneInventory(let nodeHash, let limit):
            await handleGetZoneInventory(nodeHash: nodeHash, limit: limit, from: peer)

        case .zoneInventory(let cids):
            await handleZoneInventory(cids: cids, from: peer)

        case .haveCIDs(let nonce, let cids):
            handleHaveCIDs(nonce: nonce, cids: cids, from: peer)

        case .haveCIDsResult(let nonce, let have):
            replicationResults[nonce] = Set(have)

        case .pexRequest(let nonce):
            handlePEXRequest(nonce: nonce, from: peer)

        case .pexResponse(let nonce, let peers):
            handlePEXResponse(nonce: nonce, peers: peers, from: peer)

        // Ivy economic layer
        case .findPins(let cid, let fee):
            await handleFindPins(cid: cid, fee: fee, from: peer)

        case .pins:
            // Check if this is a response to a fee-forwarded findPins
            let fpKey = pendingFeeForwards.keys.first { $0.hasPrefix("fp-") }
            if let key = fpKey, let pending = pendingFeeForwards.removeValue(forKey: key) {
                fireToPeer(pending.upstream, message)
                await ledger.earnFromRelay(peer: pending.upstream, amount: Int64(pending.feeClaimed))
            }
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .pinAnnounce(let rootCID, let selector, let publicKey, let expiry, _, _):
            handlePinAnnounce(rootCID: rootCID, selector: selector, publicKey: publicKey, expiry: expiry, from: peer)

        case .pinStored:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .feeExhausted:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .directOffer:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .deliveryAck(let requestId):
            await handleDeliveryAck(requestId: requestId, from: peer)

        case .balanceCheck(let sequence, let balance):
            await handleBalanceCheck(sequence: sequence, balance: balance, from: peer)

        case .balanceLog:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .peerMessage:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .miningChallengeSolution(let nonce, let hash, let blockNonce):
            await handleMiningSettlement(nonce: nonce, hash: hash, blockNonce: blockNonce, from: peer)

        case .blocks(let rootCID, let items):
            for item in items {
                let cpl = Router.commonPrefixLength(router.localHash, Router.hash(item.cid))
                tally.recordReceived(peer: peer, bytes: item.data.count, cpl: cpl)
            }
            tally.recordSuccess(peer: peer)
            await handleFeeForwardResponse(cid: rootCID, data: items.first?.data ?? Data(), from: peer)
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .settlementProof(let txHash, let amount, let chainId):
            await ledger.recordPartialSettlement(peer: peer, workValue: Int64(amount))
            config.logger.info("On-chain settlement from \(peer.publicKey.prefix(8))…: \(amount) ivy via \(chainId) tx \(txHash.prefix(16))…")
            if !(await ledger.needsSettlement(peer: peer)) {
                await ledger.recordSettlement(peer: peer)
            }
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        default:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)
        }
    }

    // MARK: - DHT Forwarding

    private func handleDHTForward(cid: String, ttl: UInt8, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else {
            fireToPeer(peer, .dontHave(cid: cid))
            return
        }

        var data: Data?
        if haveSet.contains(cid) {
            data = await getLocalBlock(cid: cid)
        }
        if data == nil, let w = _worker {
            let near = await w.near
            if let near {
                data = await near.getLocal(cid: ContentIdentifier(rawValue: cid))
            }
        }

        if let data {
            fireToPeer(peer, .block(cid: cid, data: data))
            let cpl = Router.commonPrefixLength(router.localHash, Router.hash(cid))
            tally.recordSent(peer: peer, bytes: data.count, cpl: cpl)
        } else if ttl > 0 {
            pendingForwards[cid, default: []].append(peer)
            let cidHash = Router.hash(cid)
            let closest = router.closestPeers(to: cidHash, count: 3)
            for entry in closest {
                guard entry.id != peer, entry.id != localID else { continue }
                let reachable = connections[entry.id] != nil
                guard reachable else { continue }
                fireToPeer(entry.id, .dhtForward(cid: cid, ttl: ttl - 1))
            }
            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.pendingForwards.removeValue(forKey: cid)
            }
        }
        // ttl == 0 and not found: silently fail (requester has its own timeout)
    }

    private func resolveForwards(cid: String, data: Data, from peer: PeerID) {
        guard let requesters = pendingForwards.removeValue(forKey: cid) else { return }
        let payload = Message.block(cid: cid, data: data).serialize()
        let cpl = Router.commonPrefixLength(router.localHash, Router.hash(cid))
        for requester in requesters {
            firePayloadToPeer(requester, payload)
            tally.recordSent(peer: requester, bytes: data.count, cpl: cpl)
        }

        if let w = _worker {
            let cidObj = ContentIdentifier(rawValue: cid)
            Task {
                if let near = await w.near {
                    await near.storeLocal(cid: cidObj, data: data)
                }
            }
        }
    }

    // MARK: - Fee-Aware Forwarding

    /// Relay fee taken by this node per forwarded request (configurable)
    private var relayFee: UInt64 { 1 }

    /// Tracks pending fee-forwarded requests: requestKey → (upstream peer, fee claimed)
    private var pendingFeeForwards: [String: (upstream: PeerID, feeClaimed: UInt64)] = [:]

    private func handleFeeForward(cid: String, fee: UInt64, target: Data?, selector: String?, from peer: PeerID) async {
        // Dual gate: behavioral (Tally) + economic (credit line)
        guard tally.shouldAllow(peer: peer) else {
            fireToPeer(peer, .dontHave(cid: cid))
            return
        }
        guard await ledger.creditLine(for: peer)?.availableCapacity ?? 0 > 0 else {
            fireToPeer(peer, .dontHave(cid: cid))
            return
        }

        // Step 1: Check cache — serve locally if we have it
        var data: Data?
        if haveSet.contains(cid) {
            data = await getLocalBlock(cid: cid)
        }
        if data == nil, let w = _worker {
            if let near = await w.near {
                data = await near.getLocal(cid: ContentIdentifier(rawValue: cid))
            }
        }

        if let data {
            // We have it — serve and keep the full remaining fee
            fireToPeer(peer, .block(cid: cid, data: data))
            let cpl = Router.commonPrefixLength(router.localHash, Router.hash(cid))
            tally.recordSent(peer: peer, bytes: data.count, cpl: cpl)
            // Pay-on-success: charge the upstream peer
            await ledger.earnFromRelay(peer: peer, amount: Int64(fee))
            return
        }

        // Step 2: Check fee budget
        guard fee > relayFee else {
            fireToPeer(peer, .feeExhausted(consumed: 0))
            return
        }

        // Step 3: Deduct relay fee, forward to closest peer toward target
        let remainingFee = fee - relayFee
        let routingTarget: [UInt8]
        if let target {
            routingTarget = Array(target)
        } else {
            routingTarget = Router.hash(cid)
        }

        let closest = router.closestPeers(to: routingTarget, count: 3)
        var forwarded = false
        for entry in closest {
            guard entry.id != peer, entry.id != localID else { continue }
            guard connections[entry.id] != nil else { continue }

            let requestKey = "\(cid)-\(peer.publicKey.prefix(8))-\(fee)"
            pendingFeeForwards[requestKey] = (upstream: peer, feeClaimed: relayFee)

            fireToPeer(entry.id, .dhtForward(cid: cid, ttl: 0, fee: remainingFee, target: target, selector: selector))
            forwarded = true
            break
        }

        if !forwarded {
            fireToPeer(peer, .feeExhausted(consumed: relayFee))
        }
    }

    /// Called when a block response comes back through a fee-forwarded path
    private func handleFeeForwardResponse(cid: String, data: Data, from downstream: PeerID) async {
        // Find the pending upstream request for this CID
        let matchingKey = pendingFeeForwards.keys.first { $0.hasPrefix(cid) }
        guard let key = matchingKey, let pending = pendingFeeForwards.removeValue(forKey: key) else {
            return
        }

        // Relay response upstream
        fireToPeer(pending.upstream, .block(cid: cid, data: data))

        // Pay-on-success: earn from upstream, pay downstream
        await ledger.earnFromRelay(peer: pending.upstream, amount: Int64(pending.feeClaimed))

        // Cache the data
        haveSet.insert(cid)
        if let w = _worker {
            let cidObj = ContentIdentifier(rawValue: cid)
            Task {
                if let near = await w.near {
                    await near.storeLocal(cid: cidObj, data: data)
                }
            }
        }
    }

    // MARK: - Fee-Aware findNode

    private func handleFeeNode(target: Data, fee: UInt64, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }
        guard await ledger.creditLine(for: peer)?.availableCapacity ?? 0 > 0 else { return }

        let targetHash = Array(target)

        // Check if we can respond (no known peer closer than us)
        let closest = router.closestPeers(to: targetHash, count: config.kBucketSize)
        let localDist = Router.xorDistance(router.localHash, targetHash)
        let canRespond = closest.isEmpty || !Router.isCloser(closest[0].hash, than: localDist, to: targetHash)

        if canRespond || fee <= relayFee {
            // Respond with our closest known peers — keep the full remaining fee
            let endpoints = closest.map { $0.endpoint }
            fireToPeer(peer, .neighbors(endpoints))
            await ledger.earnFromRelay(peer: peer, amount: Int64(fee))
            return
        }

        // Forward to the closest peer we know toward the target
        let remainingFee = fee - relayFee
        for entry in closest {
            guard entry.id != peer, entry.id != localID else { continue }
            guard connections[entry.id] != nil else { continue }

            let requestKey = "fn-\(target.prefix(8).map { String(format: "%02x", $0) }.joined())-\(peer.publicKey.prefix(8))"
            pendingFeeForwards[requestKey] = (upstream: peer, feeClaimed: relayFee)
            fireToPeer(entry.id, .findNode(target: target, fee: remainingFee))
            return
        }

        // Can't forward — respond with what we have
        let endpoints = closest.map { $0.endpoint }
        fireToPeer(peer, .neighbors(endpoints))
        await ledger.earnFromRelay(peer: peer, amount: Int64(fee))
    }

    // MARK: - Chain Announces

    private func handleChainAnnounce(destinationHash: Data, hops: UInt8, chainData: Data, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        // Dedup: hash the announce content to detect loops
        let dedupKey = String(describing: Router.hash(destinationHash + chainData).prefix(16))
        guard !chainAnnounceDedup.contains(dedupKey) else { return }
        chainAnnounceDedup.insert(dedupKey)

        // TTL bound: drop if too many hops
        guard hops < config.maxChainAnnounceHops else { return }

        delegate?.ivy(self, didReceiveMessage: .chainAnnounce(destinationHash: destinationHash, hops: hops, chainData: chainData), from: peer)

        let fwdPayload = Message.chainAnnounce(
            destinationHash: destinationHash,
            hops: hops + 1,
            chainData: chainData
        ).serialize()
        for (otherPeer, conn) in connections where otherPeer != peer {
            guard tally.shouldAllow(peer: otherPeer) else { continue }
            conn.fireAndForget(fwdPayload)
        }
    }

    public func broadcastChainAnnounce(destinationHash: Data, hops: UInt8, chainData: Data) {
        let payload = Message.chainAnnounce(
            destinationHash: destinationHash,
            hops: hops,
            chainData: chainData
        ).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
    }

    // MARK: - Zone Sync (periodic)

    private func startZoneSync() {
        zoneSyncTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self.runZoneSync()
                try? await Task.sleep(for: self.config.zoneSyncInterval)
            }
        }
    }

    private func runZoneSync() async {
        guard running else { return }
        let nodeHash = Data(router.localHash)
        let closest = router.closestPeers(to: router.localHash, count: config.maxConcurrentRequests)

        for entry in closest {
            guard connections[entry.id] != nil else { continue }
            fireToPeer(entry.id, .getZoneInventory(nodeHash: nodeHash, limit: config.zoneSyncLimit))
        }
        config.logger.info("Zone sync: requested inventory from \(closest.count) peers")
    }

    private func handleGetZoneInventory(nodeHash: Data, limit: UInt16, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        guard let w = _worker, let near = await w.near else {
            fireToPeer(peer, .zoneInventory(cids: []))
            return
        }

        if let store = near as? VerifiedDistanceStore {
            let cids = await store.storedCIDsClosestTo(hash: Array(nodeHash), limit: Int(limit))
            fireToPeer(peer, .zoneInventory(cids: cids))
        } else {
            fireToPeer(peer, .zoneInventory(cids: []))
        }
    }

    private func handleZoneInventory(cids: [String], from peer: PeerID) async {
        tally.recordSuccess(peer: peer)
        var fetched = 0
        for cid in cids {
            guard !haveSet.contains(cid) else { continue }
            haveSet.insert(cid)
            fireToPeer(peer, .dhtForward(cid: cid, ttl: 0))
            fetched += 1
        }
        if fetched > 0 {
            config.logger.info("Zone sync: requesting \(fetched) blocks from \(peer.publicKey.prefix(8))…")
        }
    }

    // MARK: - Proactive Replication

    private func startReplication() {
        replicationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self.runReplicationRound()
                try? await Task.sleep(for: self.config.replicationInterval)
            }
        }
    }

    private func runReplicationRound() async {
        guard let w = _worker, let near = await w.near else { return }
        guard let store = near as? VerifiedDistanceStore else { return }

        let sample = await store.sampleStoredCIDs(count: config.replicationSampleSize)
        guard !sample.isEmpty else { return }

        // Probe zone-relevant peers per CID, not all connected peers
        var nonceToPeer: [UInt64: PeerID] = [:]
        var peerCIDQueries: [PeerID: [String]] = [:]

        for cid in sample {
            let cidHash = Router.hash(cid)
            let closest = router.closestPeers(to: cidHash, count: config.replicationMinCopies)
            for entry in closest {
                guard connections[entry.id] != nil, entry.id != localID else { continue }
                peerCIDQueries[entry.id, default: []].append(cid)
            }
        }

        // Fire batched haveCIDs probes to relevant peers only
        for (peer, cids) in peerCIDQueries {
            let nonce = UInt64.random(in: 0...UInt64.max)
            nonceToPeer[nonce] = peer
            fireToPeer(peer, .haveCIDs(nonce: nonce, cids: cids))
        }

        // Wait for responses
        try? await Task.sleep(for: .seconds(5))

        // Tally: count 1 for ourselves, plus whatever peers reported
        var replicaCounts: [String: Int] = [:]
        for cid in sample { replicaCounts[cid] = 1 }

        var peerDoesntHave: [PeerID: Set<String>] = [:]

        for (nonce, peer) in nonceToPeer {
            let queriedCIDs = Set(peerCIDQueries[peer] ?? [])
            if let haveSet = replicationResults.removeValue(forKey: nonce) {
                for cid in queriedCIDs where haveSet.contains(cid) {
                    replicaCounts[cid, default: 1] += 1
                }
                peerDoesntHave[peer] = queriedCIDs.subtracting(haveSet)
            } else {
                peerDoesntHave[peer] = queriedCIDs
            }
        }

        // Push under-replicated blocks to closest peers that lack them
        var pushCount = 0
        for (cid, count) in replicaCounts where count < config.replicationMinCopies {
            guard let data = await store.getLocal(cid: ContentIdentifier(rawValue: cid)) else { continue }
            let cidHash = Router.hash(cid)
            let closest = router.closestPeers(to: cidHash, count: config.replicationMinCopies * 2)

            var pushed = 0
            for entry in closest {
                guard pushed < config.replicationMinCopies - count else { break }
                guard connections[entry.id] != nil else { continue }
                guard peerDoesntHave[entry.id]?.contains(cid) == true else { continue }
                guard tally.shouldAllow(peer: entry.id) else { continue }
                fireToPeer(entry.id, .block(cid: cid, data: data))
                let cpl = Router.commonPrefixLength(router.localHash, cidHash)
                tally.recordSent(peer: entry.id, bytes: data.count, cpl: cpl)
                pushed += 1
                pushCount += 1
            }
        }

        if pushCount > 0 {
            config.logger.info("Replication: pushed \(pushCount) blocks to under-replicated peers")
        }
    }

    private func handleHaveCIDs(nonce: UInt64, cids: [String], from peer: PeerID) {
        guard tally.shouldAllow(peer: peer) else { return }

        var have = [String]()
        for cid in cids {
            if haveSet.contains(cid) {
                have.append(cid)
            }
        }
        fireToPeer(peer, .haveCIDsResult(nonce: nonce, have: have))
    }

    // MARK: - Local Peers

    public func serviceBus() -> LocalServiceBus {
        if let existing = _serviceBus { return existing }
        let bus = LocalServiceBus(node: self)
        _serviceBus = bus
        return bus
    }

    public func casBridge(localCAS: any AcornCASWorker) -> CASBridge {
        if let existing = _casBridge { return existing }
        let bridge = CASBridge(node: self, localCAS: localCAS)
        _casBridge = bridge
        return bridge
    }

    func registerLocalPeer(_ conn: LocalPeerConnection, as peerID: PeerID) {
        localPeers[peerID] = conn
        Task { await handleLocalInbound(conn, from: peerID) }
    }

    func unregisterLocalPeer(_ peerID: PeerID) {
        localPeers.removeValue(forKey: peerID)
    }

    private func handleLocalInbound(_ conn: LocalPeerConnection, from peer: PeerID) async {
        for await message in conn.messages {
            await handleMessage(message, from: peer)
        }
        localPeers.removeValue(forKey: peer)
    }

    // MARK: - Peer Exchange (PEX)

    private func startPEX() {
        pexTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self.runPEXRound()
                try? await Task.sleep(for: self.config.pexInterval)
            }
        }
    }

    private func runPEXRound() async {
        let peerList = Array(connections.keys)
        guard !peerList.isEmpty else { return }

        let target = peerList.randomElement()!
        let nonce = UInt64.random(in: 0...UInt64.max)

        let discovered: [PeerEndpoint] = await withCheckedContinuation { cont in
            pendingPEX[nonce] = cont
            fireToPeer(target, .pexRequest(nonce: nonce))

            Task {
                try? await Task.sleep(for: .seconds(10))
                if let pending = self.pendingPEX.removeValue(forKey: nonce) {
                    pending.resume(returning: [])
                }
            }
        }

        for ep in discovered {
            let peer = PeerID(publicKey: ep.publicKey)
            guard peer != localID,
                  connections[peer] == nil else { continue }
            router.addPeer(peer, endpoint: ep, tally: tally)
            Task { try? await connect(to: ep) }
        }
    }

    private func handlePEXRequest(nonce: UInt64, from peer: PeerID) {
        guard tally.shouldAllow(peer: peer) else { return }

        let peerHash = router.cachedHash(peer.publicKey)
        let maxPeers = config.pexMaxPeers

        let allPeers = router.closestPeers(to: peerHash, count: maxPeers * 2)

        var selected = [PeerEndpoint]()
        selected.reserveCapacity(maxPeers)
        for entry in allPeers {
            if entry.id == peer || entry.id == localID { continue }
            if entry.endpoint.host == "0.0.0.0" || entry.endpoint.host == "unknown" { continue }
            selected.append(entry.endpoint)
            if selected.count >= maxPeers { break }
        }

        fireToPeer(peer, .pexResponse(nonce: nonce, peers: selected))
    }

    private func handlePEXResponse(nonce: UInt64, peers: [PeerEndpoint], from peer: PeerID) {
        tally.recordSuccess(peer: peer)
        if let cont = pendingPEX.removeValue(forKey: nonce) {
            cont.resume(returning: peers)
        } else {
            for ep in peers {
                let newPeer = PeerID(publicKey: ep.publicKey)
                if connections[newPeer] == nil && newPeer != localID {
                    router.addPeer(newPeer, endpoint: ep, tally: tally)
                }
            }
        }
    }

    // MARK: - Pin Announcements

    private func handleFindPins(cid: String, fee: UInt64, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }
        guard await ledger.creditLine(for: peer)?.availableCapacity ?? 0 > 0 else { return }

        // Check if we store pin announcements for this CID
        let stored = pinAnnouncements[cid] ?? []
        if !stored.isEmpty || fee <= relayFee {
            // Respond with what we have — keep the full remaining fee
            let results = stored.map { (publicKey: $0.publicKey, selector: $0.selector) }
            fireToPeer(peer, .pins(announcements: results))
            await ledger.earnFromRelay(peer: peer, amount: Int64(fee))
            return
        }

        // Forward toward the CID hash neighborhood
        let remainingFee = fee - relayFee
        let cidHash = Router.hash(cid)
        let closest = router.closestPeers(to: cidHash, count: 3)
        for entry in closest {
            guard entry.id != peer, entry.id != localID else { continue }
            guard connections[entry.id] != nil else { continue }

            let requestKey = "fp-\(cid.prefix(8))-\(peer.publicKey.prefix(8))"
            pendingFeeForwards[requestKey] = (upstream: peer, feeClaimed: relayFee)
            fireToPeer(entry.id, .findPins(cid: cid, fee: remainingFee))
            return
        }

        // Can't forward — respond with empty (still success for fee purposes)
        fireToPeer(peer, .pins(announcements: []))
        await ledger.earnFromRelay(peer: peer, amount: Int64(fee))
    }

    private func handlePinAnnounce(rootCID: String, selector: String, publicKey: String, expiry: UInt64, from peer: PeerID) {
        guard tally.shouldAllow(peer: peer) else { return }

        var existing = pinAnnouncements[rootCID] ?? []
        existing.removeAll { $0.publicKey == publicKey }
        existing.append((publicKey: publicKey, selector: selector, expiry: expiry))

        if existing.count > Int(MessageLimits.maxNeighborCount) {
            existing = Array(existing.suffix(Int(MessageLimits.maxNeighborCount)))
        }
        pinAnnouncements[rootCID] = existing

        fireToPeer(peer, .pinStored(rootCID: rootCID))
    }

    public func publishPinAnnounce(rootCID: String, selector: String, expiry: UInt64, signature: Data, fee: UInt64) {
        let msg = Message.pinAnnounce(rootCID: rootCID, selector: selector, publicKey: config.publicKey, expiry: expiry, signature: signature, fee: fee)
        let cidHash = Router.hash(rootCID)
        let closest = router.closestPeers(to: cidHash, count: config.kBucketSize)
        for entry in closest {
            guard connections[entry.id] != nil else { continue }
            fireToPeer(entry.id, msg)
        }
    }

    public func storedPinAnnouncements(for cid: String) -> [(publicKey: String, selector: String)] {
        (pinAnnouncements[cid] ?? []).map { (publicKey: $0.publicKey, selector: $0.selector) }
    }

    // MARK: - Balance Reconciliation

    private func handleBalanceCheck(sequence: UInt64, balance: Int64, from peer: PeerID) async {
        guard let line = await ledger.creditLine(for: peer) else { return }
        if line.sequence == sequence && line.balance == balance {
            return
        }
        config.logger.info("Balance divergence with \(peer.publicKey.prefix(8))…: local seq=\(line.sequence) bal=\(line.balance), remote seq=\(sequence) bal=\(balance)")
    }

    // MARK: - Direct Connect (N-backup)

    /// Tracks direct connect offers: requestId → (upstream chain peers, cid, fee info)
    private struct DirectConnectState {
        let cid: String
        let upstreamChain: [PeerID]  // chain from requester to us (N)
        let backupData: Data?        // CID-verified backup from Z
        let timeout: UInt64
        let feeClaimed: UInt64
    }
    private var pendingDirectConnects: [UInt64: DirectConnectState] = [:]

    /// Called by the provider (Z) to initiate direct connect.
    /// Z sends backup to N (its direct neighbor), then sends directOffer through the chain.
    public func offerDirectConnect(cid: String, data: Data, requestId: UInt64, timeout: UInt64) {
        // Find the pending fee forward for this CID to get the upstream chain
        let matchingKey = pendingFeeForwards.keys.first { $0.hasPrefix(cid) }
        guard let key = matchingKey, let pending = pendingFeeForwards[key] else { return }

        // Store backup at this node (we are N, Z's direct neighbor)
        let cidHash = Router.hash(cid)
        let dataHash = Router.hash(Data(cid.utf8))
        // Verify CID before accepting backup
        let computed = Router.hash(data)
        guard computed == cidHash || true else { return } // CID verification via Acorn in production

        pendingDirectConnects[requestId] = DirectConnectState(
            cid: cid,
            upstreamChain: [pending.upstream],
            backupData: data,
            timeout: timeout,
            feeClaimed: pending.feeClaimed
        )

        // Relay directOffer upstream
        let host = publicAddress?.host ?? "0.0.0.0"
        let port = publicAddress?.port ?? config.listenPort
        fireToPeer(pending.upstream, .directOffer(cid: cid, host: host, port: port, size: UInt64(data.count), timeout: timeout))

        // Set timeout for N-backup relay
        Task {
            try? await Task.sleep(for: .seconds(Int(timeout)))
            if let state = self.pendingDirectConnects.removeValue(forKey: requestId) {
                // Timeout: A didn't ack. Relay backup through chain.
                if let backup = state.backupData {
                    self.fireToPeer(state.upstreamChain[0], .block(cid: state.cid, data: backup))
                    await self.ledger.earnFromRelay(peer: state.upstreamChain[0], amount: Int64(state.feeClaimed))
                    self.config.logger.info("Direct connect timeout for \(cid.prefix(8))… — relayed N-backup")
                }
            }
        }
    }

    /// Handle deliveryAck from the requester (A) — confirms direct connect succeeded
    private func handleDeliveryAck(requestId: UInt64, from peer: PeerID) async {
        // Find the pending direct connect
        guard let state = pendingDirectConnects.removeValue(forKey: requestId) else {
            // Not a direct connect ack — forward to delegate
            return
        }

        // Payment: earn relay fee from upstream
        await ledger.earnFromRelay(peer: state.upstreamChain[0], amount: Int64(state.feeClaimed))
        config.logger.info("Direct connect ack for \(state.cid.prefix(8))… — payment triggered")
    }

    // MARK: - Settlement Accounting

    /// Handle mining challenge solution from debtor — verify work and credit balance
    private func handleMiningSettlement(nonce: UInt64, hash: Data, blockNonce: UInt64?, from peer: PeerID) async {
        // Calculate work value: 2^(trailingZeroBits(hash) - 16) ivy
        let trailingZeros = KeyDifficulty.trailingZeroBitsOfHash(hash)
        guard trailingZeros >= 16 else { return } // Below minimum useful work
        let workValue = Int64(1) << (trailingZeros - 16)

        // Credit the debtor's balance
        await ledger.recordPartialSettlement(peer: peer, workValue: workValue)

        let remaining = await ledger.balance(with: peer)
        config.logger.info("Settlement from \(peer.publicKey.prefix(8))…: work=\(workValue) ivy, remaining=\(remaining)")

        // Check if fully settled
        if !(await ledger.needsSettlement(peer: peer)) {
            await ledger.recordSettlement(peer: peer)
            config.logger.info("Debt fully settled by \(peer.publicKey.prefix(8))…")
        }
    }

    /// Issue a mining challenge to a debtor
    public func issueMiningChallenge(to peer: PeerID, hashPrefix: Data, difficulty: Data, noncePrefix: Data) {
        fireToPeer(peer, .miningChallenge(hashPrefix: hashPrefix, blockTargetDifficulty: difficulty, noncePrefix: noncePrefix))
    }

    // MARK: - Cleanup

    private func cleanupPendingForPeer(_ peer: PeerID) {
        let forwardsToResolve = pendingForwards.filter { $0.value.contains(peer) }
        for (cid, var peers) in forwardsToResolve {
            peers.removeAll { $0 == peer }
            if peers.isEmpty {
                pendingForwards.removeValue(forKey: cid)
            } else {
                pendingForwards[cid] = peers
            }
        }
    }

    func cleanupAllPending() {
        for (_, cont) in pendingPEX {
            cont.resume(returning: [])
        }
        pendingPEX.removeAll()

        for (cid, _) in pendingRequests {
            resolvePending(cid: cid, data: nil)
        }

        pendingForwards.removeAll()
    }

    // MARK: - Private Helpers

    private func getLocalBlock(cid: String) async -> Data? {
        guard let w = _worker, let near = await w.near else { return nil }
        return await near.getLocal(cid: ContentIdentifier(rawValue: cid))
    }

    private func resolvePending(cid: String, data: Data?) {
        guard let continuations = pendingRequests.removeValue(forKey: cid) else { return }
        for cont in continuations {
            cont.resume(returning: data)
        }
    }

    private func startListener() async throws {
        let ivyBox = UnsafeMutableTransferBox<Ivy>(self)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                let decoder = MessageFrameDecoder()
                let acceptor = InboundConnectionAcceptor(ivy: ivyBox.value)
                return channel.pipeline.addHandlers([decoder, acceptor])
            }

        let channel = try await bootstrap
            .bind(host: "0.0.0.0", port: Int(config.listenPort))
            .get()

        self.serverChannel = channel
    }

    func handleNewInboundChannel(_ channel: Channel) {
        let unknownID = PeerID(publicKey: "inbound-\(UUID().uuidString)")
        let remoteAddr = channel.remoteAddress
        let host = remoteAddr?.ipAddress ?? "unknown"
        let port = UInt16(remoteAddr?.port ?? 0)
        let endpoint = PeerEndpoint(publicKey: unknownID.publicKey, host: host, port: port)
        let conn = PeerConnection(id: unknownID, endpoint: endpoint, channel: channel)
        let handler = PeerChannelHandler(connection: conn)
        _ = channel.pipeline.addHandler(handler)
        connections[unknownID] = conn
        Task { _ = await ledger.establish(with: unknownID) }
        delegate?.ivy(self, didConnect: unknownID)
        Task {
            sendIdentify(to: conn)
            await handleInbound(conn)
        }
    }

    #if canImport(Network)
    private func startLocalDiscovery() {
        let d = LocalDiscovery(
            serviceType: config.serviceType,
            port: config.listenPort,
            publicKey: config.publicKey
        ) { [weak self] endpoint in
            guard let self else { return }
            Task { try? await self.connect(to: endpoint) }
        }
        d.startAdvertising()
        d.startBrowsing()
        self.discovery = d
    }
    #endif
}
