import Foundation
import NIOCore
import NIOPosix
import Acorn
import Tally
import Crypto

public protocol IvyDataSource: AnyObject, Sendable {
    func data(for cid: String) async -> Data?
    func volumeData(for rootCID: String, cids: [String]) async -> [(cid: String, data: Data)]
    /// Returns true if this node holds a complete-enough copy of the volume rooted
    /// at rootCID to serve a want request. Checks MemoryBroker first, then DiskBroker.
    func hasVolume(rootCID: String) async -> Bool
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
    public func setDataSource(_ ds: IvyDataSource?) { dataSource = ds }
    public var chainPorts: [String: UInt16] = [:]
    private var peerChainPorts: [PeerID: [String: UInt16]] = [:]

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
    private static let maxPendingForwards = 4_096
    /// Per-peer token bucket for announceBlock gossip. Prevents a single peer
    /// from driving unbounded outbound broadcast amplification.
    private var announceBuckets: [PeerID: TokenBucket] = [:]
    private static let announceGossipCapacity: Double = 200
    private static let announceGossipRefillPerSec: Double = 50
    private var pexTask: Task<Void, Never>?
    private var pendingPEX: [UInt64: CheckedContinuation<[PeerEndpoint], Never>] = [:]
    private var healthMonitor: PeerHealthMonitor?
    private var haveSet = InventorySet()
    private var localPeers: [PeerID: LocalPeerConnection] = [:]
    private var _serviceBus: LocalServiceBus?
    private var connectingPeers: Set<PeerID> = []
    private var connectingEndpoints: [PeerID: PeerEndpoint] = [:]
    private var reconnectAttempts: [PeerID: Int] = [:]
    private var reconnectTasks: [PeerID: Task<Void, Never>] = [:]
    private var intentionallyDisconnectedPeers: Set<PeerID> = []
    private static let reconnectBaseDelayMs: UInt64 = 500
    private static let reconnectMaxDelayMs: UInt64 = 30_000
    private static let reconnectJitterMs: UInt64 = 250

    private var pinAnnouncements: BoundedDictionary<String, [(publicKey: String, expiry: UInt64)]> = BoundedDictionary(capacity: 10_000)

    private var nodeRecordCache: BoundedDictionary<String, NodeRecord> = BoundedDictionary(capacity: 5_000)
    private var localNodeRecord: NodeRecord?
    private var localRecordSeq: UInt64 = 0

    // Volume tracking: root CID → provider peer(s) for DHT routing
    private var providerRecords: BoundedDictionary<String, [PeerID]> = BoundedDictionary(capacity: 10_000)

    // CONTENT-ADDRESSING INVARIANT
    // ─────────────────────────────────────────────────────────────────────────
    // All data in this network is content-addressed: a CID is the cryptographic
    // hash of its content. Pending Volume fetches are keyed by root CID, not by
    // peer. Ivy treats Volumes as opaque serialized data: any peer can satisfy a
    // root request by returning bytes for that root with matching CIDs. Schema-
    // aware path resolution belongs above Ivy.
    //
    // Peer identity is tracked only for tally/reputation and DHT routing
    // (who to ask), never for demultiplexing responses (what was asked).
    // ─────────────────────────────────────────────────────────────────────────
    private struct PendingVolumeRequest {
        var continuations: [CheckedContinuation<[String: Data], Never>]
        var candidates: Set<PeerID>
    }

    private var pendingVolumeRequests: [String: PendingVolumeRequest] = [:]
    private var pendingFindPins: [String: [CheckedContinuation<[PeerID], Never>]] = [:]

    public let creditLedger: CreditLineLedger

    public init(config: IvyConfig, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton, tally: Tally? = nil) {
        self.config = config
        self.localID = PeerID(publicKey: config.publicKey)
        self.tally = tally ?? Tally(config: config.tallyConfig)
        self.router = Router(localID: PeerID(publicKey: config.publicKey), k: config.kBucketSize)
        self.group = group
        self.stunClient = STUNClient(group: group, servers: config.stunServers)
        self.creditLedger = CreditLineLedger(
            localID: PeerID(publicKey: config.publicKey),
            baseThresholdMultiplier: config.baseThresholdMultiplier
        )
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
        connectingPeers.removeAll()
        connectingEndpoints.removeAll()
        for (_, task) in reconnectTasks {
            task.cancel()
        }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        intentionallyDisconnectedPeers.removeAll()
        pendingForwards.removeAll()
    }

    // MARK: - Connection Management

    public func connect(to endpoint: PeerEndpoint) async throws {
        let peer = PeerID(publicKey: endpoint.publicKey)
        guard reserveOutgoingDial(to: endpoint) else { return }

        let conn: PeerConnection
        do {
            conn = try await PeerConnection.dial(endpoint: endpoint, group: group)
        } catch {
            finishOutgoingDial(to: peer, connected: false)
            throw error
        }

        if intentionallyDisconnectedPeers.remove(peer) != nil {
            conn.cancel()
            finishOutgoingDial(to: peer, connected: false)
            return
        }

        connections[peer] = conn
        finishOutgoingDial(to: peer, connected: true)
        router.addPeer(peer, endpoint: endpoint, tally: tally)
        await creditLedger.establish(with: peer)
        if let monitor = healthMonitor { await monitor.trackPeer(peer) }
        delegate?.ivy(self, didConnect: peer)
        Task { await handleInbound(conn) }
        sendIdentify(to: conn)
    }

    private func reserveOutgoingDial(to endpoint: PeerEndpoint) -> Bool {
        let peer = PeerID(publicKey: endpoint.publicKey)
        guard connections[peer] == nil, !connectingPeers.contains(peer) else { return false }

        // Enforce /16-subnet diversity on every outbound dial, not just during
        // periodic refresh. Without this, an attacker can occupy all outbound
        // slots in the 60-second window between refresh cycles [Heilman 2015].
        // Limit: 2 connections per /16 subnet (first two octets of host IP).
        let targetSubnet = Self.ipSubnet(endpoint.host)
        let sameSubnetCount = connections.values.filter {
            Self.ipSubnet($0.endpoint.host) == targetSubnet
        }.count + connectingEndpoints.values.filter {
            Self.ipSubnet($0.host) == targetSubnet
        }.count
        guard sameSubnetCount < 2 else { return false }

        connectingPeers.insert(peer)
        connectingEndpoints[peer] = endpoint
        intentionallyDisconnectedPeers.remove(peer)
        return true
    }

    private func finishOutgoingDial(to peer: PeerID, connected: Bool) {
        connectingPeers.remove(peer)
        connectingEndpoints.removeValue(forKey: peer)
        if connected {
            reconnectAttempts.removeValue(forKey: peer)
            reconnectTasks.removeValue(forKey: peer)?.cancel()
        }
    }

#if DEBUG
    func reserveOutgoingDialForTesting(to endpoint: PeerEndpoint) -> Bool {
        reserveOutgoingDial(to: endpoint)
    }

    func finishOutgoingDialForTesting(to peer: PeerID, connected: Bool) {
        finishOutgoingDial(to: peer, connected: connected)
    }

    func reconnectDelayForTesting(peer: PeerID) -> Duration {
        reconnectDelay(for: peer)
    }
#endif

    public var connectedPeers: [PeerID] {
        var peers = [PeerID]()
        peers.reserveCapacity(connections.count + localPeers.count)
        peers.append(contentsOf: connections.keys)
        peers.append(contentsOf: localPeers.keys)
        return peers
    }

    public var connectedPeerEndpoints: [PeerEndpoint] {
        connections.values.map { $0.endpoint }
    }

    /// Chain ports advertised by each connected peer via identify messages.
    /// Keyed by peer ID, value is [directory: port].
    public var connectedPeerChainPorts: [PeerID: [String: UInt16]] {
        peerChainPorts.filter { connections[$0.key] != nil }
    }

    public var directPeerCount: Int { connections.count }

    /// Register a child chain's listen port so it is included in future
    /// identify messages. Remote peers use this to discover the exact port
    /// for a given chain directory without deterministic calculation.
    public func setChainPort(directory: String, port: UInt16) {
        chainPorts[directory] = port
    }

    public func disconnect(_ peer: PeerID) {
        intentionallyDisconnectedPeers.insert(peer)
        reconnectTasks.removeValue(forKey: peer)?.cancel()
        reconnectAttempts.removeValue(forKey: peer)
        if let conn = connections.removeValue(forKey: peer) {
            conn.cancel()
        }
        peerChainPorts.removeValue(forKey: peer)
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
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                    pendingRequests[cid, default: []].append(continuation)
                }
            } onCancel: {
                Task { await self.resolvePending(cid: cid, data: nil) }
            }
        }

        guard pendingRequests.count < config.maxPendingRequests else { return nil }
        let data = await fetchViaDHT(cid: cid)
        if data != nil { return data }

        return await fetchWithNewConnections(cid: cid)
    }

    private func fetchViaDHT(cid: String) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
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
        } onCancel: {
            Task { await self.resolvePending(cid: cid, data: nil) }
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
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
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
        } onCancel: {
            Task { await self.resolvePending(cid: cid, data: nil) }
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

    /// Mark CIDs as locally available for DHT-forward serving without
    /// broadcasting any announcement. Used after recursive Volume storage
    /// so peers' DHT lookups for any subtree root we hold are answered by
    /// `handleDHTForward` instead of being silently dropped.
    public func markAvailable(cids: [String]) {
        for cid in cids where !cid.isEmpty {
            haveSet.insert(cid)
        }
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
            chainPorts: chainPorts,
            signature: signature
        ))
        if let record = localNodeRecord {
            conn.fireAndForgetMessage(.nodeRecord(record: record))
        }
    }

    private func handleIdentify(publicKey: String, observedHost: String, observedPort: UInt16, listenAddrs: [(String, UInt16)], chainPorts: [String: UInt16], signature: Data, from peer: PeerID) async {
        let realID = PeerID(publicKey: publicKey)

        // Require a valid identity signature. An empty or missing signature allows
        // any peer to claim any public key — reject it outright.
        // Strip the 2-byte Multikey ed25519 prefix (ed01) if present so that
        // both raw 32-byte hex keys and Multikey-encoded keys are accepted.
        let rawPublicKey: String
        if publicKey.hasPrefix("ed01") && publicKey.count == 68 {
            rawPublicKey = String(publicKey.dropFirst(4))
        } else {
            rawPublicKey = publicKey
        }
        guard !signature.isEmpty,
              let pubKeyBytes = hexDecode(rawPublicKey), pubKeyBytes.count == 32,
              let verifyKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            config.logger.warning("Identify rejected from \(peer.publicKey.prefix(16))…: missing or invalid pubkey/signature")
            disconnect(peer)
            return
        }
        let material = Data(publicKey.utf8) + Data(observedHost.utf8)
        guard verifyKey.isValidSignature(signature, for: material) else {
            config.logger.warning("Identity verification failed for \(publicKey.prefix(16))… — disconnecting")
            disconnect(peer)
            return
        }
        // Enforce minimum key PoW to raise the cost of Sybil routing-table
        // poisoning. Each bit doubles the expected key-generation work, making
        // it progressively harder to generate keys that XOR-cluster near a
        // target CID for DHT capture.
        if config.minPeerKeyBits > 0 {
            let bits = KeyDifficulty.trailingZeroBits(of: publicKey)
            guard bits >= config.minPeerKeyBits else {
                config.logger.warning("Peer \(publicKey.prefix(16))… has \(bits) key PoW bits, need \(config.minPeerKeyBits) — disconnecting")
                disconnect(peer)
                return
            }
        }

        if peer != realID {
            if let conn = connections.removeValue(forKey: peer) {
                conn.id = realID
                connections[realID] = conn
                let endpoint = PeerEndpoint(publicKey: publicKey, host: conn.endpoint.host, port: conn.endpoint.port)
                router.addPeer(realID, endpoint: endpoint, tally: tally)
                Task { await self.creditLedger.establish(with: realID) }
            }
            await movePeerHealthTracking(from: peer, to: realID)
            // Migrate chainPorts from old key to real key.
            peerChainPorts.removeValue(forKey: peer)
        }

        if !chainPorts.isEmpty {
            peerChainPorts[realID] = chainPorts
        }

        if observedHost != "0.0.0.0" && observedHost != "unknown" {
            let observed = ObservedAddress(host: observedHost, port: observedPort)
            observedAddresses[observed] = (observedAddresses[observed] ?? 0) + 1
            if let best = observedAddresses.max(by: { $0.value < $1.value }), best.value >= 2 {
                if publicAddress != best.key {
                    publicAddress = best.key
                    updateNodeRecord()
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
        let endpoint = conn.endpoint
        connections.removeValue(forKey: peer)
        connectingPeers.remove(peer)
        connectingEndpoints.removeValue(forKey: peer)
        cleanupPendingForPeer(peer)
        delegate?.ivy(self, didDisconnect: peer)

        let wasIntentionalDisconnect = intentionallyDisconnectedPeers.remove(peer) != nil
        if !peer.publicKey.hasPrefix("inbound-"),
           running,
           !wasIntentionalDisconnect {
            scheduleReconnect(to: endpoint, peer: peer)
        }
    }

    private func scheduleReconnect(to endpoint: PeerEndpoint, peer: PeerID) {
        guard connections[peer] == nil,
              !connectingPeers.contains(peer),
              reconnectTasks[peer] == nil else { return }

        let delay = reconnectDelay(for: peer)
        config.logger.info("Connection to \(String(peer.publicKey.prefix(16)))… dropped — reconnecting in \(String(describing: delay))")

        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await self.runScheduledReconnect(to: endpoint, peer: peer)
        }
        reconnectTasks[peer] = task
    }

    private func reconnectDelay(for peer: PeerID) -> Duration {
        let attempt = min((reconnectAttempts[peer] ?? 0) + 1, 16)
        reconnectAttempts[peer] = attempt

        let shift = min(attempt - 1, 10)
        let exponential = Self.reconnectBaseDelayMs * (UInt64(1) << UInt64(shift))
        let capped = min(exponential, Self.reconnectMaxDelayMs)
        let jitter = UInt64.random(in: 0...Self.reconnectJitterMs)
        return .milliseconds(capped + jitter)
    }

    private func runScheduledReconnect(to endpoint: PeerEndpoint, peer: PeerID) async {
        reconnectTasks.removeValue(forKey: peer)
        guard running,
              connections[peer] == nil,
              !connectingPeers.contains(peer),
              !intentionallyDisconnectedPeers.contains(peer) else { return }

        do {
            try await connect(to: endpoint)
        } catch {
            scheduleReconnect(to: endpoint, peer: peer)
        }
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
            await meterReceived(peer: peer, bytes: data.count)

            guard ContentAddressVerifier.data(data, matches: cid) else {
                tally.recordFailure(peer: peer)
                break
            }

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
            guard tally.shouldAllow(peer: peer) else { return }
            let closest = router.closestPeers(to: Array(target), count: config.kBucketSize)
            let endpoints = closest.map { $0.endpoint }
            fireToPeer(peer, .neighbors(endpoints))

        case .neighbors(let endpoints):
            guard tally.shouldAllow(peer: peer) else { return }
            for ep in endpoints {
                addDiscoveredPeer(ep, source: "neighbors", from: peer)
            }

        case .announceBlock(let cid):
            // Rate-limit per-peer broadcast relaying. One announce triggers N
            // outbound broadcasts; without this cap a single peer drives
            // unbounded uplink amplification across all N connected peers.
            var announceBucket = announceBuckets[peer] ?? TokenBucket(
                capacity: Self.announceGossipCapacity,
                refillPerSec: Self.announceGossipRefillPerSec
            )
            let announceAdmitted = announceBucket.tryConsume()
            announceBuckets[peer] = announceBucket
            if announceBuckets.count > 2 * (config.tallyConfig.maxPeers ?? 256) {
                // Shed oldest-first to prevent unbounded growth on heavy churn
                if let first = announceBuckets.first { announceBuckets.removeValue(forKey: first.key) }
            }
            if announceAdmitted, !haveSet.contains(cid) {
                haveSet.insert(cid)
                fireToPeer(peer, .dhtForward(cid: cid, ttl: 0))
                let payload = Message.announceBlock(cid: cid).serialize()
                broadcastPayload(payload, excluding: peer)
            }
            delegate?.ivy(self, didReceiveBlockAnnouncement: cid, from: peer)

        case .identify(let publicKey, let observedHost, let observedPort, let listenAddrs, let chainPorts, let signature):
            await handleIdentify(publicKey: publicKey, observedHost: observedHost, observedPort: observedPort, listenAddrs: listenAddrs, chainPorts: chainPorts, signature: signature, from: peer)

        case .dhtForward(let cid, let ttl, _, _, _):
            await handleDHTForward(cid: cid, ttl: ttl, from: peer)

        case .want(let rootCIDs):
            Task { await self.handleWant(rootCIDs: rootCIDs, from: peer) }

        case .pexRequest(let nonce):
            handlePEXRequest(nonce: nonce, from: peer)

        case .pexResponse(let nonce, let peers):
            handlePEXResponse(nonce: nonce, peers: peers, from: peer)

        case .findPins(let cid, _):
            await handleFindPins(cid: cid, from: peer)

        case .pins(let cid, let providers):
            handlePinsResponse(cid: cid, providers: providers, from: peer)
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .pinAnnounce(let rootCID, let publicKey, let expiry, _, _):
            handlePinAnnounce(rootCID: rootCID, publicKey: publicKey, expiry: expiry, from: peer)

        case .pinStored:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .deliveryAck:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .peerMessage:
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .blocks(let rootCID, let items):
            await handleBlocks(rootCID: rootCID, items: items, from: peer)

            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .announceVolume(let rootCID, let childCIDs, let totalSize):
            await handleAnnounceVolume(rootCID: rootCID, childCIDs: childCIDs, totalSize: totalSize, from: peer)

        case .pushVolume(let rootCID, let items):
            await handlePushVolume(rootCID: rootCID, items: items, from: peer)

        case .notHave(let rootCID):
            handleNotHave(rootCID: rootCID, from: peer)
            delegate?.ivy(self, didReceiveMessage: message, from: peer)

        case .nodeRecord(let record):
            handleNodeRecord(record, from: peer)

        case .getNodeRecord(let publicKey):
            handleGetNodeRecord(publicKey: publicKey, from: peer)
        }
    }

    // MARK: - Credit Line Metering

    private func meterSent(peer: PeerID, bytes: Int) async {
        await creditLedger.earnFromRelay(peer: peer, amount: Int64(bytes))
    }

    private func meterReceived(peer: PeerID, bytes: Int) async {
        await creditLedger.chargeForRelay(peer: peer, amount: Int64(bytes))
    }

    private func hasCreditCapacity(peer: PeerID) async -> Bool {
        guard let line = await creditLedger.creditLine(for: peer) else { return true }
        return !line.needsSettlement
    }

    // MARK: - DHT Forwarding

    private func handleDHTForward(cid: String, ttl: UInt8, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer), await hasCreditCapacity(peer: peer) else {
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
            await meterSent(peer: peer, bytes: data.count)
        } else if ttl > 0 {
            // Cap pendingForwards to prevent unbounded memory growth and the
            // associated O(n) cleanup scan that stalls the actor on disconnect.
            guard pendingForwards.count < Self.maxPendingForwards else { return }
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

    // MARK: - want (passive responder)

    private func handleWant(rootCIDs: [String], from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }
        for rootCID in rootCIDs {
            let items = await dataSource?.volumeData(for: rootCID, cids: []) ?? []
            guard !items.isEmpty, items.contains(where: { $0.cid == rootCID }) else {
                fireToPeer(peer, .notHave(rootCID: rootCID), bypassBudget: true)
                continue
            }

            fireToPeer(peer, .blocks(rootCID: rootCID, items: items), bypassBudget: true)
            let totalBytes = items.reduce(0) { $0 + $1.data.count }
            if totalBytes > 0 {
                let cpl = Router.commonPrefixLength(router.localHash, Router.hash(rootCID))
                tally.recordSent(peer: peer, bytes: totalBytes, cpl: cpl)
                await meterSent(peer: peer, bytes: totalBytes)
            }
        }
    }

    private func handleBlocks(rootCID: String, items: [(cid: String, data: Data)], from peer: PeerID) async {
        guard pendingVolumeRequests[rootCID] != nil else { return }
        guard !items.isEmpty else {
            markVolumeCandidateDone(rootCID: rootCID, peer: peer)
            return
        }

        var result: [String: Data] = [:]
        for item in items {
            guard ContentAddressVerifier.data(item.data, matches: item.cid) else {
                tally.recordFailure(peer: peer)
                markVolumeCandidateDone(rootCID: rootCID, peer: peer)
                return
            }
            result[item.cid] = item.data
        }

        guard result[rootCID] != nil else {
            markVolumeCandidateDone(rootCID: rootCID, peer: peer)
            return
        }

        for cid in result.keys {
            haveSet.insert(cid)
        }

        var totalReceived = 0
        for item in items {
            let cpl = Router.commonPrefixLength(router.localHash, Router.hash(item.cid))
            tally.recordReceived(peer: peer, bytes: item.data.count, cpl: cpl)
            totalReceived += item.data.count
        }
        if totalReceived > 0 { await meterReceived(peer: peer, bytes: totalReceived) }
        tally.recordSuccess(peer: peer)
        recordVolumeProvider(rootCID: rootCID, peer: peer)
        resolveVolumeRequest(key: rootCID, result: result)
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
            await creditLedger.establish(with: peerID)
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

        let discovered: [PeerEndpoint] = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                guard !Task.isCancelled else { cont.resume(returning: []); return }
                pendingPEX[nonce] = cont
                fireToPeer(target, .pexRequest(nonce: nonce))
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if let pending = self.pendingPEX.removeValue(forKey: nonce) {
                        pending.resume(returning: [])
                    }
                }
            }
        } onCancel: {
            Task { await self.resolvePendingPEX(nonce: nonce) }
        }

        for ep in discovered {
            if addDiscoveredPeer(ep, source: "pex", from: target) != nil {
                Task { try? await connect(to: ep) }
            }
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
        guard let cont = pendingPEX.removeValue(forKey: nonce) else {
            config.logger.warning("Ignoring unsolicited PEX response from \(peer.publicKey.prefix(16))…")
            return
        }

        let accepted = peers.filter { isAcceptableDiscoveredEndpoint($0, source: "pex", from: peer) }
        if accepted.count == peers.count {
            tally.recordSuccess(peer: peer)
        } else {
            tally.recordFailure(peer: peer)
        }
        cont.resume(returning: accepted)
    }

#if DEBUG
    func receivePEXResponseForTesting(nonce: UInt64, peers: [PeerEndpoint], from peer: PeerID) async -> [PeerEndpoint] {
        await withCheckedContinuation { cont in
            pendingPEX[nonce] = cont
            handlePEXResponse(nonce: nonce, peers: peers, from: peer)
        }
    }
#endif

    @discardableResult
    private func addDiscoveredPeer(_ endpoint: PeerEndpoint, source: String, from peer: PeerID) -> PeerID? {
        guard isAcceptableDiscoveredEndpoint(endpoint, source: source, from: peer) else {
            return nil
        }

        let discovered = PeerID(publicKey: endpoint.publicKey)
        guard connections[discovered] == nil else { return nil }
        router.addPeer(discovered, endpoint: endpoint, tally: tally)
        return discovered
    }

    private func isAcceptableDiscoveredEndpoint(_ endpoint: PeerEndpoint, source: String, from peer: PeerID) -> Bool {
        guard !endpoint.publicKey.isEmpty else {
            config.logger.warning("Rejecting \(source) endpoint from \(peer.publicKey.prefix(16))…: empty public key")
            return false
        }

        let discovered = PeerID(publicKey: endpoint.publicKey)
        guard discovered != localID else { return false }

        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              host != "0.0.0.0",
              host != "::",
              host != "unknown",
              endpoint.port != 0 else {
            config.logger.warning("Rejecting \(source) endpoint \(endpoint.publicKey.prefix(16))… from \(peer.publicKey.prefix(16))…: unusable address")
            return false
        }

        if config.minPeerKeyBits > 0 {
            let bits = KeyDifficulty.trailingZeroBits(of: endpoint.publicKey)
            guard bits >= config.minPeerKeyBits else {
                config.logger.warning("Rejecting \(source) endpoint \(endpoint.publicKey.prefix(16))… from \(peer.publicKey.prefix(16))…: \(bits) key PoW bits, need \(config.minPeerKeyBits)")
                return false
            }
        }

        return true
    }

    // MARK: - Pin Announcements

    private func handleFindPins(cid: String, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        let stored = pinAnnouncements[cid] ?? []
        let providers = stored.map(\.publicKey)
        fireToPeer(peer, .pins(cid: cid, providers: providers))
    }

    private func handlePinAnnounce(rootCID: String, publicKey: String, expiry: UInt64, from peer: PeerID) {
        guard tally.shouldAllow(peer: peer) else { return }

        var existing = pinAnnouncements[rootCID] ?? []
        existing.removeAll { $0.publicKey == publicKey }
        existing.append((publicKey: publicKey, expiry: expiry))

        if existing.count > Int(MessageLimits.maxNeighborCount) {
            existing = Array(existing.suffix(Int(MessageLimits.maxNeighborCount)))
        }
        pinAnnouncements[rootCID] = existing

        fireToPeer(peer, .pinStored(rootCID: rootCID))
    }

    /// Resolve any in-flight findPins waiters with the providers that just
    /// arrived, and seed them as candidates for future fetches. Provider
    /// peers may not be in our routing table yet; we just stash the keys
    /// and let fetchVolume gate on connection-reachability.
    private func handlePinsResponse(cid: String, providers: [String], from peer: PeerID) {
        let peerIDs = providers.map { PeerID(publicKey: $0) }
        if let waiters = pendingFindPins.removeValue(forKey: cid) {
            for cont in waiters { cont.resume(returning: peerIDs) }
        }
        for pk in providers {
            let pid = PeerID(publicKey: pk)
            recordVolumeProvider(rootCID: cid, peer: pid)
        }
    }

    public func publishPinAnnounce(rootCID: String, expiry: UInt64, signature: Data, fee: UInt64) {
        // Self-record: when we publish that we pin a CID, we are also a
        // valid answer to findPins for that CID. Without this, a node that
        // is itself in the closest-K to the CID hash never appears in its
        // own responses — IPFS provider records are bidirectional.
        var existing = pinAnnouncements[rootCID] ?? []
        existing.removeAll { $0.publicKey == config.publicKey }
        existing.append((publicKey: config.publicKey, expiry: expiry))
        pinAnnouncements[rootCID] = existing

        let msg = Message.pinAnnounce(rootCID: rootCID, publicKey: config.publicKey, expiry: expiry, signature: signature, fee: fee)
        let cidHash = Router.hash(rootCID)
        let closest = router.closestPeers(to: cidHash, count: config.kBucketSize)
        for entry in closest {
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, msg)
        }
    }

    public func storedPinAnnouncements(for cid: String) -> [String] {
        (pinAnnouncements[cid] ?? []).map(\.publicKey)
    }

    // MARK: - Node Records

    private func handleNodeRecord(_ record: NodeRecord, from peer: PeerID) {
        guard tally.shouldAllow(peer: peer) else { return }
        guard record.verify() else { return }
        guard record.serialize().count <= NodeRecord.maxSize else { return }
        if let existing = nodeRecordCache[record.publicKey] {
            guard record.sequenceNumber > existing.sequenceNumber else { return }
        }
        nodeRecordCache[record.publicKey] = record
    }

    private func handleGetNodeRecord(publicKey: String, from peer: PeerID) {
        guard tally.shouldAllow(peer: peer) else { return }
        if publicKey == config.publicKey, let local = localNodeRecord {
            fireToPeer(peer, .nodeRecord(record: local))
        } else if let cached = nodeRecordCache[publicKey] {
            fireToPeer(peer, .nodeRecord(record: cached))
        }
    }

    public func updateNodeRecord() {
        guard let addr = publicAddress else { return }
        localRecordSeq += 1
        localNodeRecord = NodeRecord.create(
            publicKey: config.publicKey,
            host: addr.host,
            port: addr.port,
            sequenceNumber: localRecordSeq,
            signingKey: config.signingKey
        )
        if let record = localNodeRecord {
            nodeRecordCache[config.publicKey] = record
        }
    }

    public func publishNodeRecord() {
        guard let record = localNodeRecord else { return }
        let msg = Message.nodeRecord(record: record)
        let keyHash = Router.hash(config.publicKey)
        let closest = router.closestPeers(to: keyHash, count: config.kBucketSize)
        for entry in closest {
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, msg)
        }
    }

    public func lookupNodeRecord(publicKey: String) async -> NodeRecord? {
        if let cached = nodeRecordCache[publicKey] { return cached }
        let keyHash = Router.hash(publicKey)
        let closest = router.closestPeers(to: keyHash, count: config.maxConcurrentRequests)
        for entry in closest {
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, .getNodeRecord(publicKey: publicKey))
        }
        try? await Task.sleep(for: .milliseconds(500))
        return nodeRecordCache[publicKey]
    }

    public func nodeRecord(for publicKey: String) -> NodeRecord? {
        nodeRecordCache[publicKey]
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

    /// Discover pinners for a CID via findPins. Awaits the first response
    /// or short timeout, then merges with locally-stored announcements.
    public func discoverPinners(cid: String) async -> [String] {
        let discovered = await findPinnersViaDHT(rootCID: cid)
        var seen: Set<String> = []
        var out: [String] = []
        for pk in storedPinAnnouncements(for: cid) where seen.insert(pk).inserted {
            out.append(pk)
        }
        for pid in discovered where seen.insert(pid.publicKey).inserted {
            out.append(pid.publicKey)
        }
        return out
    }

    /// DHT provider lookup: ask K closest peers (by XOR distance to the CID
    /// hash) which pinners they know for `rootCID`, await first non-empty
    /// response or a short timeout, return discovered peers. This is the
    /// IPFS-style provider record path — distinct from the routing-table
    /// XOR-closest-peer set which only covers peers we happen to have in
    /// our buckets, not the broader population that has announced pins.
    private func findPinnersViaDHT(rootCID: String) async -> [PeerID] {
        let cidHash = Router.hash(rootCID)
        let closest = router.closestPeers(to: cidHash, count: config.maxConcurrentRequests)
        var sent = 0
        for entry in closest {
            let reachable = connections[entry.id] != nil || localPeers[entry.id] != nil
            guard reachable else { continue }
            fireToPeer(entry.id, .findPins(cid: rootCID, fee: 0))
            sent += 1
        }
        guard sent > 0 else { return [] }

        return await withCheckedContinuation { cont in
            pendingFindPins[rootCID, default: []].append(cont)
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                self.resolvePendingFindPins(rootCID: rootCID, peers: [])
            }
        }
    }

    private func resolvePendingPEX(nonce: UInt64) {
        if let cont = pendingPEX.removeValue(forKey: nonce) {
            cont.resume(returning: [])
        }
    }

    private func resolvePendingFindPins(rootCID: String, peers: [PeerID]) {
        guard let waiters = pendingFindPins.removeValue(forKey: rootCID) else { return }
        for cont in waiters { cont.resume(returning: peers) }
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

        let childCIDs = items.map(\.cid)
        var totalSize: UInt64 = 0
        var verifiedCIDs: [String] = []

        guard items.contains(where: { $0.cid == rootCID }) else {
            tally.recordFailure(peer: peer)
            return
        }
        for (cid, data) in items {
            guard ContentAddressVerifier.data(data, matches: cid) else {
                tally.recordFailure(peer: peer)
                return
            }
            verifiedCIDs.append(cid)
            totalSize += UInt64(data.count)
        }
        for cid in verifiedCIDs {
            haveSet.insert(cid)
        }
        haveSet.insert(dedupKey)
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

    /// Fetch from all directly connected peers — no DHT lookup.
    /// Registers the continuation before any async work so cleanupAllPending
    /// can cancel it immediately without waiting for a DHT timeout.
    public func fetchVolumeFromAllPeers(rootCID: String) async -> [String: Data] {
        let candidates = Array(connections.keys) + Array(localPeers.keys)
        guard !candidates.isEmpty else { return [:] }
        return await fetchWithCandidates(rootCID: rootCID, candidates: candidates)
    }

    public func fetchVolume(rootCID: String) async -> [String: Data] {
        if let entries = await dataSource?.volumeData(for: rootCID, cids: []), !entries.isEmpty {
            var result: [String: Data] = [:]
            for item in entries { result[item.cid] = item.data }
            return result
        }
        return await fetchVolumeFromNetwork(rootCID: rootCID)
    }

    /// Single-phase content fetch. Sends `want([rootCID])` to candidates and
    /// waits for the first `blocks` response. Candidates are selected in order:
    /// 1. Locally-known providers (provider records + pin announcements + DHT)
    /// 2. All direct peers capped at maxWantCandidates
    ///
    /// Coalescing: if a waiter for this rootCID already exists, joins it without
    /// sending new messages. First responder wakes all coalesced waiters.
    private func fetchVolumeFromNetwork(rootCID: String) async -> [String: Data] {
        // Coalesce: join an existing in-flight request for the same content.
        if let existing = pendingVolumeRequests[rootCID] {
            guard existing.continuations.count < config.maxWaitersPerPendingCID else { return [:] }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(returning: [:]); return }
                    pendingVolumeRequests[rootCID]?.continuations.append(continuation)
                }
            } onCancel: {
                Task { await self.resolveVolumeRequestsForRoot(rootCID: rootCID) }
            }
        }

        // Build candidate list: known providers first, then broadcast fallback.
        var candidates: [PeerID] = []
        var seen: Set<String> = []

        for p in providerRecords[rootCID] ?? [] {
            guard connections[p] != nil || localPeers[p] != nil else { continue }
            guard tally.shouldAllow(peer: p) else { continue }
            if seen.insert(p.publicKey).inserted { candidates.append(p) }
        }
        for pk in storedPinAnnouncements(for: rootCID) {
            let pid = PeerID(publicKey: pk)
            guard connections[pid] != nil || localPeers[pid] != nil else { continue }
            guard tally.shouldAllow(peer: pid) else { continue }
            if seen.insert(pid.publicKey).inserted { candidates.append(pid) }
        }
        if candidates.count < 2 {
            let discovered = await findPinnersViaDHT(rootCID: rootCID)
            for pid in discovered {
                guard connections[pid] != nil || localPeers[pid] != nil else { continue }
                guard tally.shouldAllow(peer: pid) else { continue }
                if seen.insert(pid.publicKey).inserted { candidates.append(pid) }
            }
        }
        // Broadcast fallback: direct peers capped at maxWantCandidates
        if candidates.isEmpty {
            let allPeers = Array(connections.keys) + Array(localPeers.keys)
            for p in allPeers {
                guard tally.shouldAllow(peer: p) else { continue }
                if seen.insert(p.publicKey).inserted { candidates.append(p) }
                if candidates.count >= config.maxWantCandidates { break }
            }
        }

        guard !candidates.isEmpty else { return [:] }
        return await fetchWithCandidates(rootCID: rootCID, candidates: candidates)
    }

    /// Core send-and-wait: register continuation, send `want` to candidates,
    /// first `blocks` response wins. Re-checks coalescing inside the continuation
    /// to handle races where a concurrent fetch registered while we were in async
    /// candidate discovery (e.g., the DHT lookup in fetchVolumeFromNetwork).
    private func fetchWithCandidates(rootCID: String, candidates: [PeerID]) async -> [String: Data] {
        // Coalesce: join an existing in-flight request for this content.
        if let existing = pendingVolumeRequests[rootCID] {
            guard existing.continuations.count < config.maxWaitersPerPendingCID else { return [:] }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(returning: [:]); return }
                    pendingVolumeRequests[rootCID]?.continuations.append(continuation)
                }
            } onCancel: {
                Task { await self.resolveVolumeRequestsForRoot(rootCID: rootCID) }
            }
        }

        guard pendingVolumeRequests.count < config.maxPendingRequests else { return [:] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: [:]); return }
                // Re-check: a concurrent fetch may have registered while we were in async work.
                if pendingVolumeRequests[rootCID] != nil {
                    pendingVolumeRequests[rootCID]?.continuations.append(continuation)
                    return
                }
                pendingVolumeRequests[rootCID] = PendingVolumeRequest(
                    continuations: [continuation],
                    candidates: Set(candidates)
                )
                let message = Message.want(rootCIDs: [rootCID])
                let payload = message.serialize()
                for peer in candidates {
                    if let conn = connections[peer] {
                        conn.fireAndForget(payload)
                    } else if let local = localPeers[peer] {
                        local.send(message)
                    }
                }
                Task {
                    try? await Task.sleep(for: self.config.requestTimeout)
                    self.resolveVolumeRequest(key: rootCID, result: [:])
                }
            }
        } onCancel: {
            Task { await self.resolveVolumeRequestsForRoot(rootCID: rootCID) }
        }
    }

    private func handleNotHave(rootCID: String, from peer: PeerID) {
        markVolumeCandidateDone(rootCID: rootCID, peer: peer)
    }

    public func recordProvider(rootCID: String, peer: PeerID) {
        recordVolumeProvider(rootCID: rootCID, peer: peer)
    }

    /// P-1003: batch variant — record one peer as provider for multiple CIDs in
    /// a single actor hop instead of N sequential `recordProvider` calls.
    public func recordProviders(rootCIDs: [String], peer: PeerID) {
        for cid in rootCIDs where !cid.isEmpty {
            recordVolumeProvider(rootCID: cid, peer: peer)
        }
    }

    public func fetchVolume(rootCID: String, childCIDs: [String]) async -> [String: Data] {
        var result: [String: Data] = [:]
        var missing: [String] = []
        for cid in childCIDs {
            if let data = await getLocalBlock(cid: cid) {
                result[cid] = data
            } else {
                missing.append(cid)
            }
        }
        guard !missing.isEmpty else { return result }
        let networkResult = await fetchVolumeFromNetwork(rootCID: rootCID)
        if let data = networkResult[rootCID] {
            result[rootCID] = data
        }
        for cid in missing {
            if let data = networkResult[cid] { result[cid] = data }
        }
        return result
    }

    /// Resolves all pending volume requests for a given rootCID regardless of
    /// which peer key suffix they're stored under. Used by onCancel to handle
    /// cases where the peer's PeerID changed (key migration) after the request
    /// was registered.
    func resolveVolumeRequestsForRoot(rootCID: String) {
        resolveVolumeRequest(key: rootCID, result: [:])
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

    private func markVolumeCandidateDone(rootCID: String, peer: PeerID) {
        guard var request = pendingVolumeRequests[rootCID] else { return }
        request.candidates.remove(peer)
        if request.candidates.isEmpty {
            resolveVolumeRequest(key: rootCID, result: [:])
        } else {
            pendingVolumeRequests[rootCID] = request
        }
    }

    private func resolveVolumeRequest(key: String, result: [String: Data]) {
        guard let request = pendingVolumeRequests.removeValue(forKey: key) else { return }
        for cont in request.continuations {
            cont.resume(returning: result)
        }
    }

    /// Get known providers for a volume.
    public func providers(for rootCID: String) -> [PeerID] {
        providerRecords[rootCID] ?? []
    }

    // MARK: - Expiry

    public func evict() {
        evictExpiredPins()
        evictExpiredProviders()
    }

    private func evictExpiredPins() {
        let now = UInt64(Date().timeIntervalSince1970)
        let rootCIDs = Array(pinAnnouncements.keys)
        for rootCID in rootCIDs {
            guard var announcements = pinAnnouncements[rootCID] else { continue }
            announcements.removeAll { $0.expiry <= now }
            if announcements.isEmpty {
                pinAnnouncements.removeValue(forKey: rootCID)
            } else {
                pinAnnouncements[rootCID] = announcements
            }
        }
    }

    private func evictExpiredProviders() {
        let rootCIDs = Array(providerRecords.keys)
        for rootCID in rootCIDs {
            let liveKeys: Set<String>
            if let announcements = pinAnnouncements[rootCID] {
                liveKeys = Set(announcements.map(\.publicKey))
            } else {
                liveKeys = []
            }
            if var providers = providerRecords[rootCID] {
                providers.removeAll { !liveKeys.contains($0.publicKey) }
                if providers.isEmpty {
                    providerRecords.removeValue(forKey: rootCID)
                } else {
                    providerRecords[rootCID] = providers
                }
            }
        }
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

        // Volume requests are keyed by root CID, not peer. A single peer
        // disconnect no longer causes an isolated volume request cancellation —
        // the remaining peers may still deliver the content.
        // cleanupAllPending() handles full teardown.

        // Cancel any in-flight want-have checks where this peer was the only candidate.
        // If other peers are still expected, leave the check running.
    }

    /// Safety net: resolve all pending continuations when the actor is torn down.
    /// Prevents SWIFT TASK CONTINUATION MISUSE warnings when an Ivy instance is
    /// released while fetches are in flight (e.g. during test teardown or network
    /// reconfiguration). The `withTaskCancellationHandler` paths handle the common
    /// case; deinit catches anything that slips through.
    deinit {
        for (_, continuations) in pendingRequests {
            for cont in continuations { cont.resume(returning: nil) }
        }
        for (_, request) in pendingVolumeRequests {
            for cont in request.continuations { cont.resume(returning: [:]) }
        }
        for (_, cont) in pendingPEX {
            cont.resume(returning: [])
        }
        for (_, continuations) in pendingFindPins {
            for cont in continuations { cont.resume(returning: []) }
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

        for (cid, _) in pendingFindPins {
            resolvePendingFindPins(rootCID: cid, peers: [])
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
        if healthMonitor != nil {
            Task { await self.trackPeerHealth(unknownID) }
        }
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

    private func trackPeerHealth(_ peer: PeerID) async {
        await healthMonitor?.trackPeer(peer)
    }

    private func movePeerHealthTracking(from oldPeer: PeerID, to newPeer: PeerID) async {
        await healthMonitor?.removePeer(oldPeer)
        await healthMonitor?.trackPeer(newPeer)
    }

#if DEBUG
    func installHealthMonitorForTesting() {
        healthMonitor = PeerHealthMonitor(config: config.healthConfig, tally: tally, onStale: { _ in })
    }

    func trackHealthPeerForTesting(_ peer: PeerID) async {
        await trackPeerHealth(peer)
    }

    func moveHealthPeerForTesting(from oldPeer: PeerID, to newPeer: PeerID) async {
        await movePeerHealthTracking(from: oldPeer, to: newPeer)
    }

    func healthMonitorTracksPeerForTesting(_ peer: PeerID) async -> Bool {
        await healthMonitor?.tracksPeer(peer) ?? false
    }

    func trackedHealthPeerCountForTesting() async -> Int {
        await healthMonitor?.trackedPeerCount ?? 0
    }
#endif

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

    /// Extract the /16 subnet prefix from an IP address (first two octets).
    /// Used for diversity enforcement: max 2 connections per /16 subnet.
    private static func ipSubnet(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return "\(parts[0]).\(parts[1])"
    }
}
