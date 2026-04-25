import Foundation
import NIOCore
import NIOPosix
import Acorn
import Tally
import Crypto

public protocol IvyDataSource: AnyObject, Sendable {
    func data(for cid: String) async -> Data?
    func volumeData(for rootCID: String, cids: [String]) async -> [(cid: String, data: Data)]
}

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
    public weak var dataSource: IvyDataSource?

    private var connections: [PeerID: PeerConnection] = [:]
    private var pendingRequests: [String: [CheckedContinuation<Data?, Never>]] = [:]
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
    private var localPeers: [PeerID: LocalPeerConnection] = [:]
    private var _serviceBus: LocalServiceBus?

    private var pinAnnouncements: BoundedDictionary<String, [(publicKey: String, selector: String, expiry: UInt64)]> = BoundedDictionary(capacity: 10_000)

    // Volume tracking: root CID → provider peer(s) for DHT routing
    private var providerRecords: BoundedDictionary<String, [PeerID]> = BoundedDictionary(capacity: 10_000)
    private var pendingVolumeRequests: [String: [CheckedContinuation<[String: Data], Never>]] = [:]

    public init(config: IvyConfig, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config
        self.localID = PeerID(publicKey: config.publicKey)
        self.tally = Tally(config: config.tallyConfig)
        self.router = Router(localID: PeerID(publicKey: config.publicKey), k: config.kBucketSize)
        self.group = group
        self.stunClient = STUNClient(group: group, servers: config.stunServers)
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
    }

    public func stop() async {
        config.logger.info("Ivy node shutting down")
        running = false
        pexTask?.cancel()
        pexTask = nil
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

    /// Send a peer message (gossip) to a specific connected peer.
    public func sendMessage(to peer: PeerID, topic: String, payload: Data) {
        fireToPeer(peer, .peerMessage(topic: topic, payload: payload))
    }

    /// Send a peer message to all connected peers.
    public func broadcastMessage(topic: String, payload: Data) {
        let msg = Message.peerMessage(topic: topic, payload: payload)
        for (peer, _) in connections {
            fireToPeer(peer, msg)
        }
        for (peer, _) in localPeers {
            fireToPeer(peer, msg)
        }
    }

    func fireToPeer(_ peer: PeerID, _ message: Message, bypassBudget: Bool = false) {
        if let local = localPeers[peer] {
            local.send(message)
            return
        }
        guard let conn = connections[peer] else { return }
        if message.isKeepalive || bypassBudget {
            conn.fireAndForgetMessage(message)
            return
        }
        guard tally.shouldAllow(peer: peer) else { return }
        conn.fireAndForgetMessage(message)
    }

    func firePayloadToPeer(_ peer: PeerID, _ payload: Data) {
        if let local = localPeers[peer] {
            if let msg = Message.deserialize(payload) { local.send(msg) }
            return
        }
        guard let conn = connections[peer] else { return }
        // Pre-serialized payloads are typically block responses (consensus) — always send
        conn.fireAndForget(payload)
    }

    /// Broadcast a pre-serialized payload to all connected network peers except `excluding`.
    private func broadcastPayload(_ payload: Data, excluding: PeerID? = nil) {
        for (peer, conn) in connections {
            if let excluded = excluding, peer == excluded { continue }
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
    }

    // MARK: - Content Fetching

    func fetchBlock(cid: String) async -> Data? {
        if let existing = pendingRequests[cid] {
            guard existing.count < config.maxWaitersPerPendingCID else { return nil }
            return await withCheckedContinuation { continuation in
                pendingRequests[cid, default: []].append(continuation)
            }
        }

        guard pendingRequests.count < config.maxPendingRequests else { return nil }
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

        guard pendingRequests[cid] == nil, pendingRequests.count < config.maxPendingRequests else {
            return nil
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
        haveSet.insert(cid)
        let payload2 = Message.announceBlock(cid: cid).serialize()
        broadcastPayload(payload2)
        for (_, local) in localPeers {
            local.send(.announceBlock(cid: cid))
        }
    }

    public func publishBlock(cid: String, data: Data, referencedContent: [(String, Data)]) async {
        // Store referenced content as a volume — the block CID is the natural root
        let allItems = [(cid, data)] + referencedContent
        await publishVolume(rootCID: cid, items: allItems.map { (cid: $0.0, data: $0.1) })
    }

    public func announceBlock(cid: String) {
        haveSet.insert(cid)
        let payload = Message.announceBlock(cid: cid).serialize()
        broadcastPayload(payload)
    }

    public func sendBlock(cid: String, data: Data) {
        haveSet.insert(cid)
        let msg = Message.block(cid: cid, data: data)
        for (peer, conn) in connections {
            conn.fireAndForget(msg.serialize())
        }
        for (peer, _) in localPeers {
            fireToPeer(peer, msg, bypassBudget: true)
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

        let data = await getLocalBlock(cid: cid)

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

        case .block(let cid, let data):
            let cpl = Router.commonPrefixLength(router.localHash, Router.hash(cid))
            tally.recordReceived(peer: peer, bytes: data.count, cpl: cpl)
            tally.recordSuccess(peer: peer)

            if haveSet.contains(cid) {
                resolvePending(cid: cid, data: data)
                break
            }
            haveSet.insert(cid)
            resolvePending(cid: cid, data: data)
            resolveForwards(cid: cid, data: data, from: peer)

            delegate?.ivy(self, didReceiveBlock: cid, data: data, from: peer)

        case .dontHave:
            tally.recordFailure(peer: peer)

        case .findNode(let target, _):
            let closest = router.closestPeers(to: Array(target), count: config.kBucketSize)
            let endpoints = closest.map { $0.endpoint }
            fireToPeer(peer, .neighbors(endpoints))

        case .neighbors(let endpoints):
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
                broadcastPayload(payload, excluding: peer)
            }
            delegate?.ivy(self, didReceiveBlockAnnouncement: cid, from: peer)

        case .identify(let publicKey, let observedHost, let observedPort, let listenAddrs, let signature):
            handleIdentify(publicKey: publicKey, observedHost: observedHost, observedPort: observedPort, listenAddrs: listenAddrs, signature: signature, from: peer)

        case .dhtForward(let cid, let ttl, _, _, _):
            await handleDHTForward(cid: cid, ttl: ttl, from: peer)

        case .haveCIDs(let nonce, let cids):
            handleHaveCIDs(nonce: nonce, cids: cids, from: peer)

        case .pexRequest(let nonce):
            handlePEXRequest(nonce: nonce, from: peer)

        case .pexResponse(let nonce, let peers):
            handlePEXResponse(nonce: nonce, peers: peers, from: peer)

        case .findPins(let cid, _):
            await handleFindPins(cid: cid, from: peer)

        case .pins:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .pinAnnounce(let rootCID, let selector, let publicKey, let expiry, _, _):
            handlePinAnnounce(rootCID: rootCID, selector: selector, publicKey: publicKey, expiry: expiry, from: peer)

        case .pinStored:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .feeExhausted:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .directOffer:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .deliveryAck:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .balanceCheck:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .balanceLog:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .peerMessage:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .miningChallengeSolution:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .settlementProof:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .blocks(let rootCID, let items):
            for item in items {
                let cpl = Router.commonPrefixLength(router.localHash, Router.hash(item.cid))
                tally.recordReceived(peer: peer, bytes: item.data.count, cpl: cpl)
            }
            tally.recordSuccess(peer: peer)

            // Resolve pending volume requests
            let volumeKey = "\(rootCID)-\(peer.publicKey.prefix(8))"
            if pendingVolumeRequests[volumeKey] != nil {
                var result: [String: Data] = [:]
                for item in items {
                    result[item.cid] = item.data
                    haveSet.insert(item.cid)
                }
                recordVolumeProvider(rootCID: rootCID, peer: peer)
                resolveVolumeRequest(key: volumeKey, result: result)
            }

            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .getVolume(let rootCID, let cids):
            await handleGetVolume(rootCID: rootCID, cids: cids, from: peer)

        case .announceVolume(let rootCID, let childCIDs, let totalSize):
            await handleAnnounceVolume(rootCID: rootCID, childCIDs: childCIDs, totalSize: totalSize, from: peer)

        case .pushVolume(let rootCID, let items):
            await handlePushVolume(rootCID: rootCID, items: items, from: peer)

        case .wantBlocks:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .getZoneInventory:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .zoneInventory:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .haveCIDsResult:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        default:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)
        }
    }

    // MARK: - DHT Forwarding

    private func handleDHTForward(cid: String, ttl: UInt8, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else {
            fireToPeer(peer, .dontHave(cid: cid), bypassBudget: true)
            return
        }

        var data: Data?
        if haveSet.contains(cid) {
            data = await getLocalBlock(cid: cid)
        }

        if let data {
            fireToPeer(peer, .block(cid: cid, data: data), bypassBudget: true)
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
    }

    // MARK: - haveCIDs (passive responder only)

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

    func registerLocalPeer(_ conn: LocalPeerConnection, as peerID: PeerID) {
        localPeers[peerID] = conn
        Task {
            await handleLocalInbound(conn, from: peerID)
        }
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

    private func handleFindPins(cid: String, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        // Check if we store pin announcements for this CID
        let stored = pinAnnouncements[cid] ?? []
        let results = stored.map { (publicKey: $0.publicKey, selector: $0.selector) }
        fireToPeer(peer, .pins(announcements: results))
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
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, msg)
        }
    }

    public func storedPinAnnouncements(for cid: String) -> [(publicKey: String, selector: String)] {
        (pinAnnouncements[cid] ?? []).map { (publicKey: $0.publicKey, selector: $0.selector) }
    }

    // MARK: - Public API (Application-Facing)

    /// Retrieve content by CID. Checks dataSource, then DHT.
    public func get(cid: String) async -> Data? {
        // DataSource first
        if let data = await dataSource?.data(for: cid) { return data }

        // DHT forward toward the CID hash
        let cidHash = Router.hash(cid)
        let closest = router.closestPeers(to: cidHash, count: config.maxConcurrentRequests)
        var sent = 0
        for entry in closest {
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, .dhtForward(cid: cid, ttl: config.defaultTTL))
            sent += 1
        }
        if sent == 0 { return nil }

        guard canRegisterPending(cid: cid) else { return nil }
        return await withCheckedContinuation { continuation in
            pendingRequests[cid, default: []].append(continuation)
            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.resolvePending(cid: cid, data: nil)
            }
        }
    }

    /// Retrieve content from a directly-connected peer.
    /// Use this when the peer just offered the data to us (gossip follow-up):
    /// they're completing their own broadcast, so there's no round-trip
    /// to reward. Routes through handleDHTForward on the receiver.
    ///
    /// Records success/failure on `peer` in Tally: a peer that announced a
    /// rootCID (or claimed to hold data via gossip) and then fails to deliver
    /// takes a reputation hit, so repeated liars eventually fail shouldAllow
    /// and stop being routed to.
    public func getDirect(cid: String, from peer: PeerID) async -> Data? {
        if let data = await dataSource?.data(for: cid) { return data }

        if connections[peer] == nil && localPeers[peer] == nil { return nil }

        tally.recordRequest(peer: peer)
        guard canRegisterPending(cid: cid) else { return nil }
        fireToPeer(peer, .dhtForward(cid: cid, ttl: 0), bypassBudget: true)
        let data: Data? = await withCheckedContinuation { continuation in
            pendingRequests[cid, default: []].append(continuation)
            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.resolvePending(cid: cid, data: nil)
            }
        }
        if data != nil {
            tally.recordSuccess(peer: peer)
        } else {
            tally.recordFailure(peer: peer)
        }
        return data
    }

    /// Retrieve content by CID targeting a specific pinner (from findPins result).
    ///
    /// Records success/failure on `target` in Tally: a peer whose pin announce
    /// we trusted but which then fails to serve the CID is demoted so future
    /// pin-selection sorts it below honest pinners and shouldAllow rejects it
    /// once reputation drops enough.
    public func get(cid: String, target: PeerID) async -> Data? {
        if let data = await dataSource?.data(for: cid) { return data }

        tally.recordRequest(peer: target)

        let targetHash = Data(Router.hash(target.publicKey))
        let closest = router.closestPeers(to: Array(targetHash), count: config.maxConcurrentRequests)
        var sent = 0
        for entry in closest {
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, .dhtForward(cid: cid, ttl: 0))
            sent += 1
            break
        }
        if sent == 0 { return nil }

        guard canRegisterPending(cid: cid) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            pendingRequests[cid, default: []].append(continuation)
            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.resolvePending(cid: cid, data: nil)
            }
        }
        if data != nil {
            tally.recordSuccess(peer: target)
        } else {
            tally.recordFailure(peer: target)
        }
        return data
    }

    /// Discover pinners for a CID via findPins.
    public func discoverPinners(cid: String) async -> [(publicKey: String, selector: String)] {
        let cidHash = Router.hash(cid)
        let closest = router.closestPeers(to: cidHash, count: config.maxConcurrentRequests)
        for entry in closest {
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, .findPins(cid: cid, fee: 0))
        }
        // Return local knowledge; remote results arrive asynchronously via delegate
        return storedPinAnnouncements(for: cid)
    }

    /// Generate a Curve25519 key pair with target difficulty.
    public static func generateKey(targetDifficulty: Int, maxAttempts: Int = 100_000_000) -> (publicKey: String, privateKey: Data)? {
        for _ in 0..<maxAttempts {
            let privateKey = Crypto.Curve25519.Signing.PrivateKey()
            let publicKeyBytes = privateKey.publicKey.rawRepresentation
            let hex = publicKeyBytes.map { String(format: "%02x", $0) }.joined()
            let difficulty = KeyDifficulty.trailingZeroBits(of: hex)
            if difficulty >= targetDifficulty {
                return (publicKey: hex, privateKey: privateKey.rawRepresentation)
            }
        }
        return nil
    }

    // MARK: - Volume-Aware Fetching

    /// Handle a getVolume request: serve all requested CIDs in a single .blocks() response.
    private func handleGetVolume(rootCID: String, cids: [String], from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        let items = await dataSource?.volumeData(for: rootCID, cids: cids) ?? []

        if !items.isEmpty {
            fireToPeer(peer, .blocks(rootCID: rootCID, items: items))
            let totalBytes = items.reduce(0) { $0 + $1.data.count }
            let cpl = Router.commonPrefixLength(router.localHash, Router.hash(rootCID))
            tally.recordSent(peer: peer, bytes: totalBytes, cpl: cpl)
        }
    }

    /// Handle announceVolume: record provider, gossip to other peers.
    private func handleAnnounceVolume(rootCID: String, childCIDs: [String], totalSize: UInt64, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        // Dedup: don't process the same volume announcement twice
        let dedupKey = "vol-\(rootCID)"
        guard !haveSet.contains(dedupKey) else { return }
        haveSet.insert(dedupKey)

        recordVolumeProvider(rootCID: rootCID, peer: peer)

        // Gossip relay to other connected peers (like announceBlock)
        let payload = Message.announceVolume(rootCID: rootCID, childCIDs: childCIDs, totalSize: totalSize).serialize()
        broadcastPayload(payload, excluding: peer)

        delegate?.ivy(self, didReceiveVolumeAnnouncement: rootCID, childCIDs: childCIDs, totalSize: totalSize, from: peer)
    }

    private func handlePushVolume(rootCID: String, items: [(cid: String, data: Data)], from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        let dedupKey = "vol-\(rootCID)"
        guard !haveSet.contains(dedupKey) else { return }
        haveSet.insert(dedupKey)

        let childCIDs = items.map(\.cid)
        var totalSize: UInt64 = 0

        for (cid, data) in items {
            haveSet.insert(cid)
            totalSize += UInt64(data.count)
        }
        recordVolumeProvider(rootCID: rootCID, peer: peer)

        let totalBytes = items.reduce(0) { $0 + $1.data.count }
        let cpl = Router.commonPrefixLength(router.localHash, Router.hash(rootCID))
        tally.recordReceived(peer: peer, bytes: totalBytes, cpl: cpl)
        tally.recordSuccess(peer: peer)

        let announcePayload = Message.announceVolume(rootCID: rootCID, childCIDs: childCIDs, totalSize: totalSize).serialize()
        broadcastPayload(announcePayload, excluding: peer)

        delegate?.ivy(self, didReceiveVolumeAnnouncement: rootCID, childCIDs: childCIDs, totalSize: totalSize, from: peer)
    }

    /// Record that a peer served content belonging to a volume (provider memory).
    private func recordVolumeProvider(rootCID: String, peer: PeerID) {
        var providers = providerRecords[rootCID] ?? []
        if !providers.contains(peer) {
            providers.append(peer)
            if providers.count > 8 { providers = Array(providers.suffix(8)) }
            providerRecords[rootCID] = providers
        }
    }

    public func publishVolume(rootCID: String, items: [(cid: String, data: Data)]) async {
        let childCIDs = items.map(\.cid)
        let totalSize = UInt64(items.reduce(0) { $0 + $1.data.count })

        for (cid, _) in items {
            haveSet.insert(cid)
        }

        // High-bandwidth push: proactively send full volume data to top-reputation peers
        // (BIP 152 high-bandwidth mode — skip the announce→request round trip)
        let highBWPayload = Message.pushVolume(rootCID: rootCID, items: items).serialize()
        let highBWPeers = selectHighBandwidthPeers(count: config.highBandwidthPeers)
        var pushedPeers: Set<PeerID> = []
        for peer in highBWPeers {
            if let conn = connections[peer] {
                conn.fireAndForget(highBWPayload)
                pushedPeers.insert(peer)
            }
        }

        // Announce volume metadata to remaining peers
        let announcePayload = Message.announceVolume(rootCID: rootCID, childCIDs: childCIDs, totalSize: totalSize).serialize()
        for (peer, conn) in connections where !pushedPeers.contains(peer) {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(announcePayload)
        }
        for (_, local) in localPeers {
            local.send(.announceVolume(rootCID: rootCID, childCIDs: childCIDs, totalSize: totalSize))
        }
    }

    /// Select the top N peers by reputation for high-bandwidth proactive push.
    /// Analogous to Bitcoin's BIP 152 high-bandwidth peer selection.
    private func selectHighBandwidthPeers(count: Int) -> [PeerID] {
        guard count > 0 else { return [] }
        let candidates = Array(connections.keys)
        guard !candidates.isEmpty else { return [] }

        // Sort by reputation (highest first), take top N
        let sorted = candidates.sorted { a, b in
            tally.reputation(for: a) > tally.reputation(for: b)
        }
        return Array(sorted.prefix(count))
    }

    /// Fetch a volume's contents from the network.
    public func fetchVolume(rootCID: String) async -> [String: Data] {
        return await fetchVolume(rootCID: rootCID, childCIDs: [rootCID])
    }

    public func fetchVolume(rootCID: String, childCIDs: [String]) async -> [String: Data] {
        var result: [String: Data] = [:]
        var missing: [String] = []

        // Check dataSource first
        for cid in childCIDs {
            if let data = await getLocalBlock(cid: cid) {
                result[cid] = data
            } else {
                missing.append(cid)
            }
        }

        guard !missing.isEmpty else { return result }

        if let providers = providerRecords[rootCID] {
            for provider in providers {
                guard connections[provider] != nil || localPeers[provider] != nil else { continue }
                guard tally.shouldAllow(peer: provider) else { continue }

                let batchResult = await requestVolumeFromPeer(rootCID: rootCID, cids: missing, peer: provider)
                for (cid, data) in batchResult {
                    result[cid] = data
                    missing.removeAll { $0 == cid }
                }

                if !batchResult.isEmpty {
                    tally.recordSuccess(peer: provider)
                }
                if missing.isEmpty { break }
            }
        }

        if !missing.isEmpty {
            let rootHash = Router.hash(rootCID)
            let closest = router.closestPeers(to: rootHash, count: config.maxConcurrentRequests)
            for entry in closest {
                guard connections[entry.id] != nil || localPeers[entry.id] != nil else { continue }
                guard tally.shouldAllow(peer: entry.id) else { continue }

                let batchResult = await requestVolumeFromPeer(rootCID: rootCID, cids: missing, peer: entry.id)
                for (cid, data) in batchResult {
                    result[cid] = data
                    missing.removeAll { $0 == cid }
                    recordVolumeProvider(rootCID: rootCID, peer: entry.id)
                }
                if missing.isEmpty { break }
            }
        }

        for cid in missing {
            if let data = await get(cid: cid) {
                result[cid] = data
            }
        }

        return result
    }

    /// Send a getVolume request to a specific peer and wait for the .blocks() response.
    private func requestVolumeFromPeer(rootCID: String, cids: [String], peer: PeerID) async -> [String: Data] {
        let volumeKey = "\(rootCID)-\(peer.publicKey.prefix(8))"

        if let existing = pendingVolumeRequests[volumeKey] {
            guard existing.count < config.maxWaitersPerPendingCID else { return [:] }
        } else {
            guard pendingVolumeRequests.count < config.maxPendingRequests else { return [:] }
        }

        return await withCheckedContinuation { continuation in
            pendingVolumeRequests[volumeKey, default: []].append(continuation)
            fireToPeer(peer, .getVolume(rootCID: rootCID, cids: cids))

            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.resolveVolumeRequest(key: volumeKey, result: [:])
            }
        }
    }

    /// Returns true if a new continuation can be appended to `pendingRequests[cid]`.
    /// Rejects when either the per-CID waiter list or the global pending-map
    /// capacity would be exceeded.
    private func canRegisterPending(cid: String) -> Bool {
        if let existing = pendingRequests[cid] {
            return existing.count < config.maxWaitersPerPendingCID
        }
        return pendingRequests.count < config.maxPendingRequests
    }

    private func resolveVolumeRequest(key: String, result: [String: Data]) {
        guard let continuations = pendingVolumeRequests.removeValue(forKey: key) else { return }
        for cont in continuations {
            cont.resume(returning: result)
        }
    }

    /// Get known providers for a volume.
    public func providers(for rootCID: String) -> [PeerID] {
        providerRecords[rootCID] ?? []
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

        for (key, _) in pendingVolumeRequests {
            resolveVolumeRequest(key: key, result: [:])
        }

        pendingForwards.removeAll()
    }

    // MARK: - Private Helpers

    private func getLocalBlock(cid: String) async -> Data? {
        return await dataSource?.data(for: cid)
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
        // Reject if at connection capacity
        if let maxPeers = config.tallyConfig.maxPeers, connections.count >= maxPeers {
            channel.close(promise: nil)
            return
        }

        let unknownID = PeerID(publicKey: "inbound-\(UUID().uuidString)")
        let remoteAddr = channel.remoteAddress
        let host = remoteAddr?.ipAddress ?? "unknown"
        let port = UInt16(remoteAddr?.port ?? 0)
        let endpoint = PeerEndpoint(publicKey: unknownID.publicKey, host: host, port: port)
        let conn = PeerConnection(id: unknownID, endpoint: endpoint, channel: channel)
        let handler = PeerChannelHandler(connection: conn)
        _ = channel.pipeline.addHandler(handler)
        connections[unknownID] = conn
        delegate?.ivy(self, didConnect: unknownID)
        Task {
            sendIdentify(to: conn)
            await handleInbound(conn)
        }
        // Disconnect if peer doesn't identify within 30 seconds
        let peerToTimeout = unknownID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.timeoutUnidentifiedPeer(peerToTimeout)
        }
    }

    private func timeoutUnidentifiedPeer(_ peer: PeerID) {
        if connections[peer] != nil, peer.publicKey.hasPrefix("inbound-") {
            disconnect(peer)
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
