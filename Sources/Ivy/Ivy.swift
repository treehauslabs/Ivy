import Foundation
import NIOCore
import NIOPosix
import Acorn
import Tally

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

    public init(config: IvyConfig, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config
        self.localID = PeerID(publicKey: config.publicKey)
        self.tally = Tally(config: config.tallyConfig)
        self.router = Router(localID: PeerID(publicKey: config.publicKey), k: config.kBucketSize)
        self.group = group
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
        for bootstrap in config.bootstrapPeers {
            Task { try? await connect(to: bootstrap) }
        }
    }

    public func stop() async {
        running = false
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
    }

    // MARK: - Connection Management

    public func connect(to endpoint: PeerEndpoint) async throws {
        let peer = PeerID(publicKey: endpoint.publicKey)
        guard connections[peer] == nil else { return }
        let conn = try await PeerConnection.dial(endpoint: endpoint, group: group)
        connections[peer] = conn
        router.addPeer(peer, endpoint: endpoint, tally: tally)
        delegate?.ivy(self, didConnect: peer)
        Task { await handleInbound(conn) }
    }

    public var connectedPeers: [PeerID] {
        Array(connections.keys)
    }

    public func disconnect(_ peer: PeerID) {
        connections[peer]?.cancel()
        connections.removeValue(forKey: peer)
        delegate?.ivy(self, didDisconnect: peer)
    }

    // MARK: - Content Fetching

    func fetchBlock(cid: String) async -> Data? {
        let peers = selectPeersForRequest(cid: cid)
        guard !peers.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            pendingRequests[cid, default: []].append(continuation)
            for peer in peers {
                guard let conn = connections[peer] else { continue }
                Task {
                    let start = ContinuousClock.now
                    try? await conn.send(.wantBlock(cid: cid))
                    tally.recordRequest(peer: peer)
                    let elapsed = start.duration(to: ContinuousClock.now)
                    let micros = Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
                    tally.recordLatency(peer: peer, microseconds: micros)
                }
            }
            Task {
                try? await Task.sleep(for: config.requestTimeout)
                self.resolvePending(cid: cid, data: nil)
            }
        }
    }

    public func announceBlock(cid: String) async {
        for (peer, conn) in connections {
            guard tally.shouldAllow(peer: peer) else { continue }
            try? await conn.send(.announceBlock(cid: cid))
        }
    }

    public func broadcastBlock(cid: String, data: Data) async {
        for (_, conn) in connections {
            try? await conn.send(.block(cid: cid, data: data))
        }
    }

    // MARK: - DHT

    public func findNode(target: String) async -> [PeerEndpoint] {
        let targetHash = Router.hash(target)
        let closest = router.closestPeers(to: targetHash, count: config.kBucketSize)
        let results = closest.map { $0.endpoint }

        for entry in closest.prefix(3) {
            guard let conn = connections[entry.id] else { continue }
            try? await conn.send(.findNode(target: Data(targetHash)))
        }

        return results
    }

    // MARK: - Serving

    public func handleBlockRequest(cid: String, from peer: PeerID) async {
        guard tally.shouldAllow(peer: peer) else {
            guard let conn = connections[peer] else { return }
            try? await conn.send(.dontHave(cid: cid))
            return
        }

        var data: Data?
        if let w = _worker {
            let near = await w.near
            if let near {
                let cidObj = ContentIdentifier(rawValue: cid)
                data = await near.get(cid: cidObj)
            }
        }

        guard let conn = connections[peer] else { return }
        if let data {
            try? await conn.send(.block(cid: cid, data: data))
            let dataHash = Router.hash(cid)
            let cpl = Router.commonPrefixLength(Router.hash(localID.publicKey), dataHash)
            tally.recordSent(peer: peer, bytes: data.count, cpl: cpl)
        } else {
            try? await conn.send(.dontHave(cid: cid))
        }
    }

    // MARK: - Private

    private func handleInbound(_ conn: PeerConnection) async {
        for await message in conn.messages {
            await handleMessage(message, from: conn.id)
        }
        connections.removeValue(forKey: conn.id)
        delegate?.ivy(self, didDisconnect: conn.id)
    }

    private func handleMessage(_ message: Message, from peer: PeerID) async {
        switch message {
        case .ping(let nonce):
            guard let conn = connections[peer] else { return }
            try? await conn.send(.pong(nonce: nonce))

        case .pong:
            tally.recordSuccess(peer: peer)

        case .wantBlock(let cid):
            await handleBlockRequest(cid: cid, from: peer)

        case .block(let cid, let data):
            let peerHash = Router.hash(peer.publicKey)
            let dataHash = Router.hash(cid)
            let cpl = Router.commonPrefixLength(peerHash, dataHash)
            tally.recordReceived(peer: peer, bytes: data.count, cpl: cpl)
            tally.recordSuccess(peer: peer)
            resolvePending(cid: cid, data: data)
            delegate?.ivy(self, didReceiveBlock: cid, data: data, from: peer)

        case .dontHave:
            tally.recordFailure(peer: peer)

        case .findNode(let target):
            let closest = router.closestPeers(to: Array(target), count: config.kBucketSize)
            let endpoints = closest.map { $0.endpoint }
            guard let conn = connections[peer] else { return }
            try? await conn.send(.neighbors(endpoints))

        case .neighbors(let endpoints):
            for ep in endpoints {
                let newPeer = PeerID(publicKey: ep.publicKey)
                if connections[newPeer] == nil && newPeer != localID {
                    router.addPeer(newPeer, endpoint: ep, tally: tally)
                }
            }

        case .announceBlock(let cid):
            delegate?.ivy(self, didReceiveBlockAnnouncement: cid, from: peer)
        }
    }

    private func selectPeersForRequest(cid: String) -> [PeerID] {
        let cidHash = Router.hash(cid)
        let closest = router.closestPeers(to: cidHash, count: config.maxConcurrentRequests * 2)
        var candidates = closest
            .filter { connections[$0.id] != nil }
            .map { (id: $0.id, rep: tally.reputation(for: $0.id)) }
        candidates.sort { $0.rep > $1.rep }
        return Array(candidates.prefix(config.maxConcurrentRequests).map(\.id))
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
        Task { await handleInbound(conn) }
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
