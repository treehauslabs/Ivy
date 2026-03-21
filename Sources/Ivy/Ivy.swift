import Foundation
import NIOCore
import NIOPosix
import Acorn
import Tally

public enum IvyError: Error, Sendable {
    case noRelayAvailable
    case notRunning
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
    private var _reticulumWorker: ReticulumNetwork?
    private var serverChannel: Channel?
    #if canImport(Network)
    private var discovery: LocalDiscovery?
    #endif
    private var running = false

    private let stunClient: STUNClient
    private let relayService: RelayService
    public let transport: Transport
    public let announceService: AnnounceService
    private var interfaces: [any NetworkInterface] = []
    private(set) public var publicAddress: ObservedAddress?
    private(set) public var natStatus: NATStatus = .unknown
    private var observedAddresses: BoundedDictionary<ObservedAddress, Int> = BoundedDictionary(capacity: 256)
    private var relayedPeers: [PeerID: PeerID] = [:]
    private var peerListenAddrs: [PeerID: [(String, UInt16)]] = [:]
    private var pendingDialBacks: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var pendingRelayRequests: [PeerID: CheckedContinuation<Bool, Never>] = [:]
    private var pendingHolePunches: [UInt64: CheckedContinuation<[(String, UInt16)], Never>] = [:]
    private var pendingForwards: [String: [PeerID]] = [:]
    private var announceTask: Task<Void, Never>?
    private var healthMonitor: PeerHealthMonitor?
    private var haveSet = InventorySet()
    private var recentBlockSenders: BoundedDictionary<String, PeerID> = BoundedDictionary(capacity: 4096)
    private var localPeers: [PeerID: LocalPeerConnection] = [:]
    private var _casBridge: CASBridge?
    private var _serviceBus: LocalServiceBus?

    public init(config: IvyConfig, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config
        self.localID = PeerID(publicKey: config.publicKey)
        self.tally = Tally(config: config.tallyConfig)
        self.router = Router(localID: PeerID(publicKey: config.publicKey), k: config.kBucketSize)
        self.group = group
        self.stunClient = STUNClient(group: group, servers: config.stunServers)
        self.relayService = RelayService()
        self.transport = Transport(localID: PeerID(publicKey: config.publicKey), tally: Tally(config: config.tallyConfig), enableTransport: config.enableTransport)
        self.announceService = AnnounceService(localID: PeerID(publicKey: config.publicKey), tally: Tally(config: config.tallyConfig))
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

        if config.enableUDP {
            let udpIface = UDPInterface(name: "udp0", port: config.udpPort, group: group)
            try await udpIface.start()
            interfaces.append(udpIface)
            await transport.registerInterface(udpIface)
            Task { await listenOnInterface(udpIface) }
        }

        let tcpIface = TCPInterface(name: "tcp0", port: config.listenPort, group: group)
        await transport.registerInterface(tcpIface)
        interfaces.append(tcpIface)

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

        if config.enableAutoNAT {
            Task {
                try? await Task.sleep(for: .seconds(5))
                await self.probeReachability()
            }
        }

        if config.enableAnnounce {
            startAnnouncing()
        }

        await transport.startAutoPruning()

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
    }

    public func stop() async {
        config.logger.info("Ivy node shutting down")
        running = false
        announceTask?.cancel()
        announceTask = nil
        await transport.stopAutoPruning()
        if let monitor = healthMonitor { await monitor.stopMonitoring() }

        cleanupAllPending()
        config.logger.debug("Drained all pending operations")

        try? await serverChannel?.close().get()
        serverChannel = nil
        for iface in interfaces {
            await iface.stop()
        }
        interfaces.removeAll()
        #if canImport(Network)
        discovery?.stop()
        discovery = nil
        #endif
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        relayedPeers.removeAll()
        peerListenAddrs.removeAll()
        pendingForwards.removeAll()
    }

    // MARK: - Connection Management

    public func connect(to endpoint: PeerEndpoint) async throws {
        let peer = PeerID(publicKey: endpoint.publicKey)
        guard connections[peer] == nil, relayedPeers[peer] == nil else { return }

        do {
            let conn = try await PeerConnection.dial(endpoint: endpoint, group: group)
            connections[peer] = conn
            router.addPeer(peer, endpoint: endpoint, tally: tally)
            if let monitor = healthMonitor { await monitor.trackPeer(peer) }
            delegate?.ivy(self, didConnect: peer)
            Task { await handleInbound(conn) }
            sendIdentify(to: conn)
        } catch {
            guard config.enableRelay else { throw error }
            try await connectViaRelay(to: endpoint)
        }
    }

    public var connectedPeers: [PeerID] {
        var peers = [PeerID]()
        peers.reserveCapacity(connections.count + relayedPeers.count + localPeers.count)
        peers.append(contentsOf: connections.keys)
        peers.append(contentsOf: relayedPeers.keys)
        peers.append(contentsOf: localPeers.keys)
        return peers
    }

    public var directPeerCount: Int { connections.count }
    public var relayedPeerCount: Int { relayedPeers.count }

    public func disconnect(_ peer: PeerID) {
        if let conn = connections.removeValue(forKey: peer) {
            conn.cancel()
        }
        if relayedPeers.removeValue(forKey: peer) != nil {
            Task { await relayService.removeCircuit(between: localID.publicKey, and: peer.publicKey) }
        }
        cleanupPendingForPeer(peer)
        peerListenAddrs.removeValue(forKey: peer)
        if let monitor = healthMonitor {
            Task { await monitor.removePeer(peer) }
        }
        delegate?.ivy(self, didDisconnect: peer)
    }

    // MARK: - Sending

    func sendToPeer(_ peer: PeerID, _ message: Message) async throws {
        if let conn = connections[peer] {
            try await conn.send(message)
        } else if let relayPeer = relayedPeers[peer], let relayConn = connections[relayPeer] {
            let data = message.serialize()
            try await relayConn.send(.relayData(peerKey: peer.publicKey, data: data))
        }
    }

    private func sendPreSerialized(_ peer: PeerID, _ payload: Data) async throws {
        if let conn = connections[peer] {
            try await conn.sendPreSerialized(payload)
        } else if let relayPeer = relayedPeers[peer], let relayConn = connections[relayPeer] {
            try await relayConn.send(.relayData(peerKey: peer.publicKey, data: payload))
        }
    }

    func fireToPeer(_ peer: PeerID, _ message: Message) {
        if let local = localPeers[peer] {
            local.send(message)
        } else if let conn = connections[peer] {
            conn.fireAndForgetMessage(message)
        } else if let relayPeer = relayedPeers[peer], let relayConn = connections[relayPeer] {
            let data = message.serialize()
            relayConn.fireAndForgetMessage(.relayData(peerKey: peer.publicKey, data: data))
        }
    }

    func firePayloadToPeer(_ peer: PeerID, _ payload: Data) {
        if let local = localPeers[peer] {
            if let msg = Message.deserialize(payload) { local.send(msg) }
        } else if let conn = connections[peer] {
            conn.fireAndForget(payload)
        } else if let relayPeer = relayedPeers[peer], let relayConn = connections[relayPeer] {
            relayConn.fireAndForgetMessage(.relayData(peerKey: peer.publicKey, data: payload))
        }
    }

    // MARK: - Content Fetching

    func fetchBlock(cid: String) async -> Data? {
        if pendingRequests[cid] != nil {
            return await withCheckedContinuation { continuation in
                pendingRequests[cid, default: []].append(continuation)
            }
        }

        return await withCheckedContinuation { continuation in
            pendingRequests[cid] = [continuation]

            let peers = selectPeersForRequest(cid: cid)
            if !peers.isEmpty {
                for peer in peers {
                    fireToPeer(peer, .wantBlock(cid: cid))
                    tally.recordRequest(peer: peer)
                }
            } else {
                let cidHash = Router.hash(cid)
                let closest = router.closestPeers(to: cidHash, count: 3)
                for entry in closest {
                    let reachable = connections[entry.id] != nil || relayedPeers[entry.id] != nil
                    guard reachable else { continue }
                    fireToPeer(entry.id, .dhtForward(cid: cid, ttl: 3))
                }
            }

            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.resolvePending(cid: cid, data: nil)
            }
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

    public func broadcastBlock(cid: String, data: Data) {
        let payload = Message.block(cid: cid, data: data).serialize()
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
                (connections[$0.id] != nil || relayedPeers[$0.id] != nil)
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
        conn.fireAndForgetMessage(.identify(
            publicKey: config.publicKey,
            observedHost: observedHost,
            observedPort: observedPort,
            listenAddrs: listenAddrs
        ))
    }

    private func handleIdentify(publicKey: String, observedHost: String, observedPort: UInt16, listenAddrs: [(String, UInt16)], from peer: PeerID) {
        let realID = PeerID(publicKey: publicKey)

        if peer.publicKey.hasPrefix("inbound-") && peer != realID {
            if let conn = connections.removeValue(forKey: peer) {
                conn.id = realID
                connections[realID] = conn
                let endpoint = PeerEndpoint(publicKey: publicKey, host: conn.endpoint.host, port: conn.endpoint.port)
                router.addPeer(realID, endpoint: endpoint, tally: tally)
            }
        }

        peerListenAddrs[realID] = listenAddrs

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

    // MARK: - AutoNAT

    private func probeReachability() async {
        let peers = Array(connections.keys.prefix(4))
        guard peers.count >= 2 else { return }

        let host: String
        let port: UInt16
        if let pub = publicAddress {
            host = pub.host
            port = pub.port
        } else {
            host = "0.0.0.0"
            port = config.listenPort
        }

        var successes = 0
        for peer in peers {
            let nonce = UInt64.random(in: 0...UInt64.max)
            let result: Bool = await withCheckedContinuation { cont in
                pendingDialBacks[nonce] = cont
                Task {
                    try? await sendToPeer(peer, .dialBack(nonce: nonce, host: host, port: port))
                }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if let pending = self.pendingDialBacks.removeValue(forKey: nonce) {
                        pending.resume(returning: false)
                    }
                }
            }
            if result { successes += 1 }
        }

        let newStatus: NATStatus = successes >= 2 ? .reachable : .unreachable
        if natStatus != newStatus {
            natStatus = newStatus
            delegate?.ivy(self, didUpdateNATStatus: newStatus)
        }
    }

    private static func probeAddress(host: String, port: Int, group: EventLoopGroup) async -> Bool {
        do {
            let bootstrap = ClientBootstrap(group: group)
                .connectTimeout(.seconds(5))
            let channel = try await bootstrap.connect(host: host, port: port).get()
            channel.close(promise: nil)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Circuit Relay

    private func connectViaRelay(to endpoint: PeerEndpoint) async throws {
        let targetKey = endpoint.publicKey
        let targetPeer = PeerID(publicKey: targetKey)

        for (relayPeerID, _) in connections {
            if relayPeerID.publicKey == targetKey { continue }

            let success: Bool = await withCheckedContinuation { cont in
                pendingRelayRequests[relayPeerID] = cont
                Task {
                    try? await sendToPeer(relayPeerID, .relayConnect(srcKey: config.publicKey, dstKey: targetKey))
                }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if let pending = self.pendingRelayRequests.removeValue(forKey: relayPeerID) {
                        pending.resume(returning: false)
                    }
                }
            }

            if success {
                relayedPeers[targetPeer] = relayPeerID
                router.addPeer(targetPeer, endpoint: endpoint, tally: tally)
                delegate?.ivy(self, didConnect: targetPeer)

                Task { self.sendIdentifyViaRelay(to: targetPeer) }

                if config.enableHolePunch {
                    Task { await attemptHolePunchUpgrade(target: targetPeer, relay: relayPeerID) }
                }
                return
            }
        }

        throw IvyError.noRelayAvailable
    }

    private func sendIdentifyViaRelay(to peer: PeerID) {
        var listenAddrs: [(String, UInt16)] = [("0.0.0.0", config.listenPort)]
        if let pub = publicAddress {
            listenAddrs.append((pub.host, pub.port))
        }
        fireToPeer(peer, .identify(
            publicKey: config.publicKey,
            observedHost: "relay",
            observedPort: 0,
            listenAddrs: listenAddrs
        ))
    }

    private func handleRelayConnect(srcKey: String, dstKey: String, from peer: PeerID) async {
        if dstKey == config.publicKey {
            let srcPeer = PeerID(publicKey: srcKey)
            relayedPeers[srcPeer] = peer
            let endpoint = PeerEndpoint(publicKey: srcKey, host: "relay", port: 0)
            router.addPeer(srcPeer, endpoint: endpoint, tally: tally)
            delegate?.ivy(self, didConnect: srcPeer)
            Task { self.sendIdentifyViaRelay(to: srcPeer) }
        } else if config.enableRelay {
            let targetPeer = PeerID(publicKey: dstKey)
            let srcPeer = PeerID(publicKey: srcKey)

            guard tally.shouldAllow(peer: srcPeer) else {
                try? await sendToPeer(peer, .relayStatus(code: 1))
                return
            }

            guard connections[targetPeer] != nil else {
                try? await sendToPeer(peer, .relayStatus(code: 1))
                return
            }

            let created = await relayService.createCircuit(initiator: srcKey, target: dstKey)
            if created {
                try? await sendToPeer(peer, .relayStatus(code: 0))
                try? await sendToPeer(targetPeer, .relayConnect(srcKey: srcKey, dstKey: dstKey))
            } else {
                try? await sendToPeer(peer, .relayStatus(code: 2))
            }
        }
    }

    private func handleRelayData(peerKey: String, data: Data, from peer: PeerID) async {
        let senderKey = peer.publicKey

        if await relayService.hasCircuit(between: senderKey, and: peerKey) {
            let forwarded = await relayService.relay(from: senderKey, to: peerKey, bytes: data.count)
            if forwarded {
                let targetPeer = PeerID(publicKey: peerKey)
                if let targetConn = connections[targetPeer] {
                    try? await targetConn.send(.relayData(peerKey: senderKey, data: data))
                }
            }
        } else {
            let srcPeer = PeerID(publicKey: peerKey)
            if let innerMsg = Message.deserialize(data) {
                await handleMessage(innerMsg, from: srcPeer)
            }
        }
    }

    // MARK: - Hole Punching (DCUtR)

    private func attemptHolePunchUpgrade(target: PeerID, relay: PeerID) async {
        var myAddrs: [(String, UInt16)] = []
        if let pub = publicAddress {
            myAddrs.append((pub.host, pub.port))
        }
        myAddrs.append(("0.0.0.0", config.listenPort))

        let nonce = UInt64.random(in: 0...UInt64.max)

        let targetAddrs: [(String, UInt16)] = await withCheckedContinuation { cont in
            pendingHolePunches[nonce] = cont
            Task {
                try? await sendToPeer(target, .holepunchConnect(addrs: myAddrs, nonce: nonce))
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                if let pending = self.pendingHolePunches.removeValue(forKey: nonce) {
                    pending.resume(returning: [])
                }
            }
        }

        guard !targetAddrs.isEmpty else { return }

        try? await sendToPeer(target, .holepunchSync(nonce: nonce))
        try? await Task.sleep(for: .milliseconds(200))

        for (host, port) in targetAddrs where host != "0.0.0.0" && host != "relay" {
            let endpoint = PeerEndpoint(publicKey: target.publicKey, host: host, port: port)
            do {
                let conn = try await PeerConnection.dial(endpoint: endpoint, group: group)
                relayedPeers.removeValue(forKey: target)
                connections[target] = conn
                Task { await handleInbound(conn) }
                sendIdentify(to: conn)
                delegate?.ivy(self, didUpgradeToDirectConnection: target)
                return
            } catch {
                continue
            }
        }
    }

    private func handleHolepunchConnect(addrs: [(String, UInt16)], nonce: UInt64, from peer: PeerID) async {
        peerListenAddrs[peer] = addrs

        if let cont = pendingHolePunches.removeValue(forKey: nonce) {
            cont.resume(returning: addrs)
        } else if relayedPeers[peer] != nil {
            var myAddrs: [(String, UInt16)] = []
            if let pub = publicAddress {
                myAddrs.append((pub.host, pub.port))
            }
            myAddrs.append(("0.0.0.0", config.listenPort))
            try? await sendToPeer(peer, .holepunchConnect(addrs: myAddrs, nonce: nonce))
        }
    }

    private func handleHolepunchSync(nonce: UInt64, from peer: PeerID) async {
        guard let addrs = peerListenAddrs[peer], relayedPeers[peer] != nil else { return }

        Task {
            try? await Task.sleep(for: .milliseconds(100))

            for (host, port) in addrs where host != "0.0.0.0" && host != "relay" {
                let endpoint = PeerEndpoint(publicKey: peer.publicKey, host: host, port: port)
                do {
                    let conn = try await PeerConnection.dial(endpoint: endpoint, group: self.group)
                    self.relayedPeers.removeValue(forKey: peer)
                    self.connections[peer] = conn
                    Task { await self.handleInbound(conn) }
                    await self.sendIdentify(to: conn)
                    self.delegate?.ivy(self, didUpgradeToDirectConnection: peer)
                    return
                } catch {
                    continue
                }
            }
        }
    }

    // MARK: - Message Handling

    private func handleInbound(_ conn: PeerConnection) async {
        for await message in conn.messages {
            await handleMessage(message, from: conn.id)
        }
        let peer = conn.id
        connections.removeValue(forKey: peer)
        cleanupPendingForPeer(peer)
        if relayedPeers.values.contains(peer) {
            let relayedThroughThis = relayedPeers.filter { $0.value == peer }.map(\.key)
            for p in relayedThroughThis {
                relayedPeers.removeValue(forKey: p)
                cleanupPendingForPeer(p)
                delegate?.ivy(self, didDisconnect: p)
            }
        }
        Task { await relayService.removeAllCircuits(forPeer: peer.publicKey) }
        peerListenAddrs.removeValue(forKey: peer)
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

        case .wantBlock(let cid):
            if haveSet.contains(cid), let data = await getLocalBlock(cid: cid) {
                fireToPeer(peer, .block(cid: cid, data: data))
                tally.recordSent(peer: peer, bytes: data.count, cpl: 0)
            } else {
                await handleBlockRequest(cid: cid, from: peer)
            }

        case .haveBlock(let cid):
            haveSet.insert(cid)

        case .wantBlocks(let cids):
            for cid in cids {
                await handleBlockRequest(cid: cid, from: peer)
            }

        case .block(let cid, let data):
            tally.recordReceived(peer: peer, bytes: data.count, cpl: 0)
            tally.recordSuccess(peer: peer)
            if haveSet.contains(cid) {
                resolvePending(cid: cid, data: data)
                break
            }
            haveSet.insert(cid)
            recentBlockSenders[cid] = peer
            resolvePending(cid: cid, data: data)
            resolveForwards(cid: cid, data: data, from: peer)
            delegate?.ivy(self, didReceiveBlock: cid, data: data, from: peer)

        case .dontHave:
            tally.recordFailure(peer: peer)

        case .findNode(let target):
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
            delegate?.ivy(self, didReceiveBlockAnnouncement: cid, from: peer)

        case .identify(let publicKey, let observedHost, let observedPort, let listenAddrs):
            handleIdentify(publicKey: publicKey, observedHost: observedHost, observedPort: observedPort, listenAddrs: listenAddrs, from: peer)

        case .dialBack(let nonce, let host, let port):
            Task {
                let success = await Self.probeAddress(host: host, port: Int(port), group: group)
                self.fireToPeer(peer, .dialBackResult(nonce: nonce, success: success))
            }

        case .dialBackResult(let nonce, let success):
            if let cont = pendingDialBacks.removeValue(forKey: nonce) {
                cont.resume(returning: success)
            }

        case .relayConnect(let srcKey, let dstKey):
            await handleRelayConnect(srcKey: srcKey, dstKey: dstKey, from: peer)

        case .relayStatus(let code):
            if let cont = pendingRelayRequests.removeValue(forKey: peer) {
                cont.resume(returning: code == 0)
            }

        case .relayData(let peerKey, let data):
            await handleRelayData(peerKey: peerKey, data: data, from: peer)

        case .holepunchConnect(let addrs, let nonce):
            await handleHolepunchConnect(addrs: addrs, nonce: nonce, from: peer)

        case .holepunchSync(let nonce):
            await handleHolepunchSync(nonce: nonce, from: peer)

        case .dhtForward(let cid, let ttl):
            await handleDHTForward(cid: cid, ttl: ttl, from: peer)

        case .announce(let destinationHash, let hops, let payload):
            await handleAnnounceMessage(destinationHash: destinationHash, hops: hops, payload: payload, from: peer)

        case .pathRequest(let destinationHash):
            await handlePathRequest(destinationHash: destinationHash, from: peer)

        case .pathResponse(let destinationHash, let hops, let announcePayload):
            await handlePathResponse(destinationHash: destinationHash, hops: hops, announcePayload: announcePayload, from: peer)

        case .transportPacket(let data):
            await handleTransportPacketMessage(data: data, from: peer)

        case .chainAnnounce(let destinationHash, let hops, let chainData, let announcePayload):
            await handleChainAnnounce(destinationHash: destinationHash, hops: hops, chainData: chainData, announcePayload: announcePayload, from: peer)

        case .compactBlock(let chainHash, let headerCID, let txCIDs):
            delegate?.ivy(self, didReceiveCompactBlock: headerCID, txCIDs: txCIDs, chainHash: chainHash, from: peer)

        case .getBlockTxns(let chainHash, let headerCID, let missingTxCIDs):
            delegate?.ivy(self, didRequestBlockTxns: headerCID, missingTxCIDs: missingTxCIDs, chainHash: chainHash, from: peer)

        case .blockTxns(let chainHash, let headerCID, let transactions):
            delegate?.ivy(self, didReceiveBlockTxns: headerCID, transactions: transactions, chainHash: chainHash, from: peer)

        case .newTxHashes(let chainHash, let txHashes):
            delegate?.ivy(self, didReceiveNewTxHashes: txHashes, chainHash: chainHash, from: peer)

        case .getTxns(let chainHash, let txHashes):
            delegate?.ivy(self, didRequestTxns: txHashes, chainHash: chainHash, from: peer)

        case .txns(let chainHash, let transactions):
            delegate?.ivy(self, didReceiveTxns: transactions, chainHash: chainHash, from: peer)

        case .getBlockRange(let chainHash, let startIndex, let count):
            delegate?.ivy(self, didRequestBlockRange: startIndex, count: count, chainHash: chainHash, from: peer)

        case .blockRange(let chainHash, let startIndex, let blocks):
            delegate?.ivy(self, didReceiveBlockRange: startIndex, blocks: blocks, chainHash: chainHash, from: peer)

        case .blockManifest(let blockCID, let referencedCIDs):
            haveSet.insert(blockCID)
            delegate?.ivy(self, didReceiveBlockManifest: blockCID, referencedCIDs: referencedCIDs, from: peer)

        case .getCIDs(let cids):
            await handleGetCIDs(cids: cids, from: peer)

        case .cidData(let items):
            for (cid, data) in items {
                haveSet.insert(cid)
                resolvePending(cid: cid, data: data)
            }
            delegate?.ivy(self, didReceiveCIDData: items, from: peer)
        }
    }

    // MARK: - DHT Forwarding

    private func handleDHTForward(cid: String, ttl: UInt8, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else {
            fireToPeer(peer, .dontHave(cid: cid))
            return
        }

        var data: Data?
        if let w = _worker {
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
                let reachable = connections[entry.id] != nil || relayedPeers[entry.id] != nil
                guard reachable else { continue }
                fireToPeer(entry.id, .dhtForward(cid: cid, ttl: ttl - 1))
            }
            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.pendingForwards.removeValue(forKey: cid)
            }
        } else {
            fireToPeer(peer, .dontHave(cid: cid))
        }
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

    // MARK: - Announce & Transport

    private func startAnnouncing() {
        announceTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.broadcastAnnounce()
                try? await Task.sleep(for: self.config.announceInterval)
            }
        }
    }

    private func broadcastAnnounce() async {
        let packet = await announceService.createAnnounce(
            publicKey: config.publicKey,
            name: config.announceAppName,
            signingKey: config.signingKey,
            appData: nil
        )
        let payload = Message.announce(
            destinationHash: packet.destinationHash,
            hops: packet.hops,
            payload: packet.payload
        ).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
    }

    public func sendAnnounce(appData: Data? = nil) async {
        let packet = await announceService.createAnnounce(
            publicKey: config.publicKey,
            name: config.announceAppName,
            signingKey: config.signingKey,
            appData: appData
        )
        let payload = Message.announce(
            destinationHash: packet.destinationHash,
            hops: packet.hops,
            payload: packet.payload
        ).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
    }

    public func requestPath(destinationHash: Data) {
        let payload = Message.pathRequest(destinationHash: destinationHash).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
    }

    private func handleChainAnnounce(destinationHash: Data, hops: UInt8, chainData: Data, announcePayload: Data, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        if let reticulum = _reticulumWorker {
            await reticulum.processChainAnnounce(
                destinationHash: destinationHash,
                hops: hops,
                chainData: chainData,
                announcePayload: announcePayload,
                from: peer
            )
        }

        if let announceData = ChainAnnounceData.deserialize(chainData) {
            delegate?.ivy(self, didReceiveChainAnnounce: announceData, destinationHash: destinationHash, hops: hops, from: peer)
        }

        if await transport.isTransportEnabled {
            let fwdPayload = Message.chainAnnounce(
                destinationHash: destinationHash,
                hops: hops + 1,
                chainData: chainData,
                announcePayload: announcePayload
            ).serialize()
            for (otherPeer, conn) in connections where otherPeer != peer {
                guard tally.shouldAllow(peer: otherPeer) else { continue }
                conn.fireAndForget(fwdPayload)
            }
        }
    }

    public func broadcastChainAnnounce(destinationHash: Data, hops: UInt8, chainData: Data, announcePayload: Data) {
        let payload = Message.chainAnnounce(
            destinationHash: destinationHash,
            hops: hops,
            chainData: chainData,
            announcePayload: announcePayload
        ).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
    }

    private func handleAnnounceMessage(destinationHash: Data, hops: UInt8, payload: Data, from peer: PeerID) async {
        let tPacket = TransportPacket(
            packetType: .announce,
            hops: hops,
            destinationHash: destinationHash,
            payload: payload
        )

        let accepted = await announceService.processAnnounce(tPacket, from: peer, hops: hops)
        guard accepted else { return }

        await transport.recordPath(
            destinationHash: destinationHash,
            from: peer,
            onInterface: "tcp0",
            hops: hops,
            announceHash: tPacket.packetHash
        )

        if let parsed = AnnouncePayload.deserialize(payload) {
            delegate?.ivy(self, didReceiveAnnounce: parsed.publicKey, destinationHash: destinationHash, hops: hops, appData: parsed.appData)
        }

        if await transport.isTransportEnabled {
            let fwdPayload = Message.announce(
                destinationHash: destinationHash,
                hops: hops + 1,
                payload: payload
            ).serialize()
            for (otherPeer, conn) in connections where otherPeer != peer {
                guard tally.shouldAllow(peer: otherPeer) else { continue }
                conn.fireAndForget(fwdPayload)
            }
        }
    }

    private func handlePathRequest(destinationHash: Data, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        if let path = await transport.lookupPath(destinationHash) {
            fireToPeer(peer, .pathResponse(
                destinationHash: destinationHash,
                hops: path.hops,
                announcePayload: Data()
            ))
            delegate?.ivy(self, didDiscoverPath: destinationHash, hops: path.hops, via: peer)
        } else if await transport.isTransportEnabled {
            let payload = Message.pathRequest(destinationHash: destinationHash).serialize()
            for (otherPeer, conn) in connections where otherPeer != peer {
                guard tally.shouldAllow(peer: otherPeer) else { continue }
                conn.fireAndForget(payload)
            }
        }
    }

    private func handlePathResponse(destinationHash: Data, hops: UInt8, announcePayload: Data, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }

        await transport.recordPath(
            destinationHash: destinationHash,
            from: peer,
            onInterface: "tcp0",
            hops: hops
        )

        delegate?.ivy(self, didDiscoverPath: destinationHash, hops: hops, via: peer)
    }

    private func handleTransportPacketMessage(data: Data, from peer: PeerID) async {
        guard let packet = TransportPacket.deserialize(data) else { return }

        let action = await transport.handleInboundPacket(packet, from: peer, onInterface: "tcp0")

        switch action {
        case .deliver(let p):
            delegate?.ivy(self, didReceiveTransportPacket: p, from: peer)

        case .forwardTo(let nextPeer, _, let p):
            let fwdPayload = Message.transportPacket(data: p.serialize()).serialize()
            if let conn = connections[nextPeer] {
                conn.fireAndForget(fwdPayload)
                tally.recordSent(peer: nextPeer, bytes: data.count, cpl: 0)
            }

        case .forwardOnAllExcept(_, let p):
            let fwdPayload = Message.transportPacket(data: p.serialize()).serialize()
            for (otherPeer, conn) in connections where otherPeer != peer {
                guard tally.shouldAllow(peer: otherPeer) else { continue }
                conn.fireAndForget(fwdPayload)
                tally.recordSent(peer: otherPeer, bytes: data.count, cpl: 0)
            }

        case .drop:
            break
        }
    }

    public func sendTransportPacket(_ packet: TransportPacket, via path: Transport.PathEntry) {
        fireToPeer(path.receivedFrom, .transportPacket(data: packet.serialize()))
        tally.recordSent(peer: path.receivedFrom, bytes: packet.payload.count, cpl: 0)
    }

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

    public func reticulumWorker() -> ReticulumNetwork {
        if let existing = _reticulumWorker { return existing }
        let w = ReticulumNetwork(node: self, transport: transport, announceService: announceService)
        _reticulumWorker = w
        return w
    }

    private func listenOnInterface(_ iface: any NetworkInterface) async {
        for await (packet, _) in iface.inboundPackets {
            let unknownPeer = PeerID(publicKey: "iface-\(iface.name)")
            let action = await transport.handleInboundPacket(packet, from: unknownPeer, onInterface: iface.name)
            switch action {
            case .deliver(let p):
                delegate?.ivy(self, didReceiveTransportPacket: p, from: unknownPeer)
            case .forwardTo(let nextPeer, _, let p):
                fireToPeer(nextPeer, .transportPacket(data: p.serialize()))
            case .forwardOnAllExcept(let excludeIface, let p):
                for otherIface in interfaces where otherIface.name != excludeIface {
                    try? await otherIface.send(p, to: nil)
                }
                let payload = Message.transportPacket(data: p.serialize()).serialize()
                for (peer, conn) in connections {
                    guard tally.shouldAllow(peer: peer) else { continue }
                    conn.fireAndForget(payload)
                }
            case .drop:
                break
            }
        }
    }

    // MARK: - Cleanup

    private func cleanupPendingForPeer(_ peer: PeerID) {
        if let cont = pendingRelayRequests.removeValue(forKey: peer) {
            cont.resume(returning: false)
        }

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
        for (_, cont) in pendingDialBacks {
            cont.resume(returning: false)
        }
        pendingDialBacks.removeAll()

        for (_, cont) in pendingRelayRequests {
            cont.resume(returning: false)
        }
        pendingRelayRequests.removeAll()

        for (_, cont) in pendingHolePunches {
            cont.resume(returning: [])
        }
        pendingHolePunches.removeAll()

        for (cid, _) in pendingRequests {
            resolvePending(cid: cid, data: nil)
        }

        pendingForwards.removeAll()
    }

    // MARK: - Private Helpers

    private func selectPeersForRequest(cid: String) -> [PeerID] {
        let cidHash = Router.hash(cid)
        let closest = router.closestPeers(to: cidHash, count: config.maxConcurrentRequests * 2)
        var candidates = closest
            .filter { connections[$0.id] != nil || relayedPeers[$0.id] != nil }
            .map { (id: $0.id, rep: tally.reputation(for: $0.id)) }
        candidates.sort { $0.rep > $1.rep }
        return Array(candidates.prefix(config.maxConcurrentRequests).map(\.id))
    }

    private func handleGetCIDs(cids: [String], from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else { return }
        var found: [(String, Data)] = []
        for cid in cids {
            if let data = await getLocalBlock(cid: cid) {
                found.append((cid, data))
            }
        }
        if !found.isEmpty {
            fireToPeer(peer, .cidData(items: found))
            let totalBytes = found.reduce(0) { $0 + $1.1.count }
            tally.recordSent(peer: peer, bytes: totalBytes, cpl: 0)
        }
    }

    public func sendBlockManifest(blockCID: String, referencedCIDs: [String]) {
        haveSet.insert(blockCID)
        let payload = Message.blockManifest(blockCID: blockCID, referencedCIDs: referencedCIDs).serialize()
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            conn.fireAndForget(payload)
        }
        for (peer, local) in localPeers {
            local.send(.blockManifest(blockCID: blockCID, referencedCIDs: referencedCIDs))
            _ = peer
        }
    }

    public func requestCIDs(_ cids: [String], from peer: PeerID) {
        fireToPeer(peer, .getCIDs(cids: cids))
    }

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
