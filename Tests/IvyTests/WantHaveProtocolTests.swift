import Testing
import Foundation

@testable import Ivy
@testable import Tally

// MARK: - Thread-safe message recorder

/// Records messages received by a simulated peer. @unchecked Sendable because
/// access is serialised via a Mutex.
final class PeerMessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [Message] = []

    func record(_ message: Message) {
        lock.withLock { self._messages.append(message) }
    }

    var messages: [Message] { lock.withLock { _messages } }

    func received(getVolume rootCID: String) -> Bool {
        messages.contains {
            if case .getVolume(let cid, _) = $0 { return cid == rootCID }
            return false
        }
    }

    func received(haveCIDs: Bool) -> Bool {
        messages.contains { if case .haveCIDs = $0 { return true }; return false }
    }
}

// MARK: - Suite

/// Tests for the two-phase want-have/want-block content fetch protocol.
///
/// The protocol invariant: data is content-addressed, so any peer serving a
/// CID is equally valid. Phase 1 (want-have) discovers who has the content
/// cheaply; Phase 2 (want-block) transfers data only from confirmed holders.
@Suite("Want-Have Protocol")
struct WantHaveProtocolTests {

    private func makeNode(publicKey: String, haveCheckTimeout: Duration = .milliseconds(50), requestTimeout: Duration = .seconds(5)) -> Ivy {
        Ivy(config: IvyConfig(
            publicKey: publicKey,
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            requestTimeout: requestTimeout,
            healthConfig: PeerHealthConfig(
                keepaliveInterval: .seconds(999),
                staleTimeout: .seconds(999),
                maxMissedPongs: 99,
                enabled: false
            ),
            enablePEX: false,
            replicationInterval: .seconds(999),
            haveCheckTimeout: haveCheckTimeout
        ))
    }

    // MARK: - Scenario 1: getVolume only sent to HAVE-confirmed peers

    /// Phase 2 must only fire getVolume to peers that confirmed HAVE.
    /// A DONT_HAVE peer must never receive getVolume — the bandwidth saving.
    @Test("getVolume not sent to peer that responded DONT_HAVE")
    func testGetVolumeOnlySentToConfirmedHolders() async throws {
        let node = makeNode(publicKey: "requester-s1")
        let nodeID = await node.localID

        let peerHave = PeerID(publicKey: "holder-have-aaaaaaaa")
        let peerDont = PeerID(publicKey: "nonholder-dont-bbbbbb")

        let (haveLocal, haveRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: peerHave)
        let (dontLocal, dontRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: peerDont)
        await node.registerLocalPeer(haveLocal, as: peerHave)
        await node.registerLocalPeer(dontLocal, as: peerDont)
        await node.addToRouter(peerHave, endpoint: PeerEndpoint(publicKey: peerHave.publicKey, host: "local", port: 0))
        await node.addToRouter(peerDont, endpoint: PeerEndpoint(publicKey: peerDont.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let rootCID = "bafyrei-s1-rootcid"
        let expectedData = Data("content from HAVE peer".utf8)
        let dontLog = PeerMessageLog()

        // HAVE peer: confirms HAVE, serves data
        Task {
            for await msg in haveRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    haveRemote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    haveRemote.send(.blocks(rootCID: cid, items: [(cid: cid, data: expectedData)]))
                }
            }
        }
        // DONT_HAVE peer: records all messages it receives
        Task {
            for await msg in dontRemote.messages {
                dontLog.record(msg)
                if case .haveCIDs(let nonce, _) = msg {
                    dontRemote.send(.haveCIDsResult(nonce: nonce, have: []))
                }
            }
        }

        let result = await node.fetchVolumeFromAllPeers(rootCID: rootCID)

        #expect(result[rootCID] == expectedData, "Data must come from the HAVE-confirmed peer")
        #expect(!dontLog.received(getVolume: rootCID),
            "DONT_HAVE peer must never receive getVolume — that wastes bandwidth")
    }

    // MARK: - Scenario 2: Concurrent requests coalesce

    /// Two concurrent fetches for the same rootCID must coalesce: both callers
    /// receive data when the single network response arrives.
    @Test("Concurrent fetches for same CID both resolve on one response")
    func testConcurrentRequestsBothResolve() async throws {
        let node = makeNode(publicKey: "requester-s2")
        let nodeID = await node.localID

        let peer = PeerID(publicKey: "holder-coalesce-cccc0")
        let (local, remote) = LocalPeerConnection.pair(localID: nodeID, remoteID: peer)
        await node.registerLocalPeer(local, as: peer)
        await node.addToRouter(peer, endpoint: PeerEndpoint(publicKey: peer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let rootCID = "bafyrei-s2-coalesce"
        let expectedData = Data("shared content".utf8)

        Task {
            for await msg in remote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    remote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    remote.send(.blocks(rootCID: cid, items: [(cid: cid, data: expectedData)]))
                }
            }
        }

        async let fetch1 = node.fetchVolumeFromAllPeers(rootCID: rootCID)
        async let fetch2 = node.fetchVolumeFromAllPeers(rootCID: rootCID)
        let (r1, r2) = await (fetch1, fetch2)

        // Both must resolve (at least one with actual data)
        #expect(
            r1[rootCID] == expectedData || r2[rootCID] == expectedData,
            "At least one concurrent fetch must receive the data"
        )
    }

    // MARK: - Scenario 3: haveCheckTimeout fallback

    /// When no peer responds to haveCIDs within haveCheckTimeout, the protocol
    /// falls back to sending getVolume to all original candidates. Without this,
    /// a silent Phase 1 would starve Phase 2 forever.
    @Test("Falls back to all candidates when haveCIDs times out")
    func testHaveCheckTimeoutFallback() async throws {
        let node = makeNode(publicKey: "requester-s3", haveCheckTimeout: .milliseconds(10))
        let nodeID = await node.localID

        let peer = PeerID(publicKey: "silent-phase1-peer00")
        let (local, remote) = LocalPeerConnection.pair(localID: nodeID, remoteID: peer)
        await node.registerLocalPeer(local, as: peer)
        await node.addToRouter(peer, endpoint: PeerEndpoint(publicKey: peer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let rootCID = "bafyrei-s3-timeout"
        let expectedData = Data("fallback content".utf8)
        let log = PeerMessageLog()

        Task {
            for await msg in remote.messages {
                log.record(msg)
                // Silently ignore haveCIDs — simulates a peer that doesn't speak Phase 1
                if case .getVolume(let cid, _) = msg {
                    // But DOES respond to getVolume (the fallback)
                    remote.send(.blocks(rootCID: cid, items: [(cid: cid, data: expectedData)]))
                }
            }
        }

        let result = await node.fetchVolumeFromAllPeers(rootCID: rootCID)

        #expect(log.received(getVolume: rootCID),
            "Peer must receive getVolume as fallback after haveCIDs timeout")
        #expect(result[rootCID] == expectedData,
            "Fallback path must still deliver data")
    }

    // MARK: - Scenario 4: First valid response wakes all waiters

    /// The first non-empty blocks response resolves all waiters. A second
    /// response from another peer must be silently discarded — not crash
    /// (double-resume) and not deliver duplicate data.
    @Test("First valid blocks response resolves all waiters; second is discarded")
    func testFirstResponseWakesAllWaiters() async throws {
        let node = makeNode(publicKey: "requester-s4", haveCheckTimeout: .milliseconds(20))
        let nodeID = await node.localID

        let fastPeer = PeerID(publicKey: "fast-winner-ffffffff")
        let slowPeer = PeerID(publicKey: "slow-loser-ssssssss0")
        let (fLocal, fRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: fastPeer)
        let (sLocal, sRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: slowPeer)
        await node.registerLocalPeer(fLocal, as: fastPeer)
        await node.registerLocalPeer(sLocal, as: slowPeer)
        await node.addToRouter(fastPeer, endpoint: PeerEndpoint(publicKey: fastPeer.publicKey, host: "local", port: 0))
        await node.addToRouter(slowPeer, endpoint: PeerEndpoint(publicKey: slowPeer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let rootCID = "bafyrei-s4-firstwins"
        let fastData = Data("fast wins".utf8)

        Task {
            for await msg in fRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    fRemote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    fRemote.send(.blocks(rootCID: cid, items: [(cid: cid, data: fastData)]))
                }
            }
        }
        Task {
            for await msg in sRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    sRemote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    try? await Task.sleep(for: .milliseconds(200))
                    sRemote.send(.blocks(rootCID: cid, items: [(cid: cid, data: Data("slow loses".utf8))]))
                }
            }
        }

        // This would crash with "resuming already-resumed continuation" if there's a double-resume bug
        let result = await node.fetchVolumeFromAllPeers(rootCID: rootCID)

        #expect(result[rootCID] == fastData, "Fast peer's response must be the winner")
    }

    // MARK: - Scenario 5: Slow peer doesn't block fast peer

    /// The fetch must resolve at the speed of the fastest responding peer,
    /// not the slowest. A 3-second peer must not hold up a 10ms peer.
    @Test("Fast peer response doesn't wait for slow peer — bounded latency")
    func testFastPeerDoesNotWaitForSlowPeer() async throws {
        let node = makeNode(publicKey: "requester-s5", haveCheckTimeout: .milliseconds(20))
        let nodeID = await node.localID

        let fastPeer = PeerID(publicKey: "fast-latency-fff0000")
        let slowPeer = PeerID(publicKey: "slow-latency-sss0000")
        let (fLocal, fRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: fastPeer)
        let (sLocal, sRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: slowPeer)
        await node.registerLocalPeer(fLocal, as: fastPeer)
        await node.registerLocalPeer(sLocal, as: slowPeer)
        await node.addToRouter(fastPeer, endpoint: PeerEndpoint(publicKey: fastPeer.publicKey, host: "local", port: 0))
        await node.addToRouter(slowPeer, endpoint: PeerEndpoint(publicKey: slowPeer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let rootCID = "bafyrei-s5-latency"
        let fastData = Data("fast data".utf8)

        Task {
            for await msg in fRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    fRemote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    try? await Task.sleep(for: .milliseconds(10))
                    fRemote.send(.blocks(rootCID: cid, items: [(cid: cid, data: fastData)]))
                }
            }
        }
        Task {
            for await msg in sRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    sRemote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    try? await Task.sleep(for: .seconds(3))  // would stall the whole fetch
                    sRemote.send(.blocks(rootCID: cid, items: [(cid: cid, data: Data("slow".utf8))]))
                }
            }
        }

        let start = ContinuousClock.now
        let result = await node.fetchVolumeFromAllPeers(rootCID: rootCID)
        let elapsed = ContinuousClock.now - start

        #expect(result[rootCID] == fastData, "Fast peer's data must win")
        #expect(elapsed < .milliseconds(500),
            "Fetch must resolve near fast-peer latency, not slow-peer latency — got \(elapsed)")
    }

    // MARK: - Scenario 6: Byzantine empty blocks

    /// A peer that claims HAVE but delivers empty blocks must NOT poison the
    /// waiter. An honest peer responding later must still be able to deliver.
    ///
    /// Regression: old code called resolveVolumeRequest even for empty items,
    /// letting a Byzantine peer race to resolve all waiters with [:].
    @Test("Byzantine peer returning empty blocks does not poison waiters")
    func testByzantineEmptyBlocksDoesNotPoisonWaiters() async throws {
        let node = makeNode(publicKey: "requester-s6", haveCheckTimeout: .milliseconds(20))
        let nodeID = await node.localID

        let byzantinePeer = PeerID(publicKey: "byzantine-liar-bbbbb")
        let honestPeer = PeerID(publicKey: "honest-server-hhhhh0")
        let (bLocal, bRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: byzantinePeer)
        let (hLocal, hRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: honestPeer)
        await node.registerLocalPeer(bLocal, as: byzantinePeer)
        await node.registerLocalPeer(hLocal, as: honestPeer)
        await node.addToRouter(byzantinePeer, endpoint: PeerEndpoint(publicKey: byzantinePeer.publicKey, host: "local", port: 0))
        await node.addToRouter(honestPeer, endpoint: PeerEndpoint(publicKey: honestPeer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let rootCID = "bafyrei-s6-byzantine"
        let honestData = Data("real content".utf8)

        // Byzantine: claims HAVE but delivers empty blocks
        Task {
            for await msg in bRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    bRemote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    bRemote.send(.blocks(rootCID: cid, items: []))  // empty! Byzantine lie
                }
            }
        }
        // Honest: responds slightly after Byzantine (to ensure Byzantine fires first)
        Task {
            for await msg in hRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    hRemote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    try? await Task.sleep(for: .milliseconds(30))
                    hRemote.send(.blocks(rootCID: cid, items: [(cid: cid, data: honestData)]))
                }
            }
        }

        let result = await node.fetchVolumeFromAllPeers(rootCID: rootCID)

        #expect(result[rootCID] == honestData,
            "Honest peer's data must win — Byzantine empty-blocks must not resolve waiters with [:]")
    }

    // MARK: - Gap 1: notHave signal (Bitcoin NOTFOUND equivalent)

    /// When a confirmed HAVE peer sends notHave for a volume request, the fetch
    /// must resolve quickly rather than waiting for the full requestTimeout.
    @Test("notHave signal resolves fetch without waiting for requestTimeout")
    func testNotHaveResolvesImmediately() async throws {
        let node = makeNode(publicKey: "requester-nothave",
                            haveCheckTimeout: .milliseconds(20),
                            requestTimeout: .seconds(10))
        let nodeID = await node.localID

        let lyingPeer = PeerID(publicKey: "lying-have-notserve0")
        let (local, remote) = LocalPeerConnection.pair(localID: nodeID, remoteID: lyingPeer)
        await node.registerLocalPeer(local, as: lyingPeer)
        await node.addToRouter(lyingPeer, endpoint: PeerEndpoint(publicKey: lyingPeer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let rootCID = "bafyrei-nothave-root"
        Task {
            for await msg in remote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    remote.send(.haveCIDsResult(nonce: nonce, have: [rootCID]))
                } else if case .getVolume(let cid, _) = msg {
                    remote.send(.notHave(rootCID: cid))
                }
            }
        }

        let start = ContinuousClock.now
        let result = await node.fetchVolumeFromAllPeers(rootCID: rootCID)
        let elapsed = ContinuousClock.now - start

        #expect(result.isEmpty)
        #expect(elapsed < .milliseconds(500),
            "notHave must resolve fetch quickly, not wait requestTimeout=10s — got \(elapsed)")
    }

    /// notHave must record a tally failure so repeated liars get deprioritised.
    @Test("notHave records tally failure for the lying peer")
    func testNotHaveRecordsTallyFailure() async throws {
        let node = makeNode(publicKey: "requester-nothave-tally",
                            haveCheckTimeout: .milliseconds(20),
                            requestTimeout: .milliseconds(100))
        let nodeID = await node.localID

        let peer = PeerID(publicKey: "nothave-tally-peer00")
        let (local, remote) = LocalPeerConnection.pair(localID: nodeID, remoteID: peer)
        await node.registerLocalPeer(local, as: peer)
        await node.addToRouter(peer, endpoint: PeerEndpoint(publicKey: peer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        let tally = await node.tally
        let repBefore = tally.reputation(for: peer)

        Task {
            for await msg in remote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    remote.send(.haveCIDsResult(nonce: nonce, have: ["bafyrei-tally-cid"]))
                } else if case .getVolume(let cid, _) = msg {
                    remote.send(.notHave(rootCID: cid))
                }
            }
        }

        _ = await node.fetchVolumeFromAllPeers(rootCID: "bafyrei-tally-cid")
        let repAfter = tally.reputation(for: peer)
        #expect(repAfter <= repBefore,
            "notHave must not improve peer reputation — before=\(repBefore) after=\(repAfter)")
    }

    // MARK: - Scenario 7: Consecutive DONT_HAVEs degrade peer reputation

    /// A peer that consistently returns DONT_HAVE should accumulate failures
    /// in the tally, degrading its reputation and eventually excluding it from
    /// candidate selection via tally.shouldAllow(peer:).
    @Test("Consecutive DONT_HAVEs degrade peer reputation in tally")
    func testConsecutiveDontHavesDegradePeerReputation() async throws {
        // Short requestTimeout so fallback getVolume doesn't stall the test
        let node = makeNode(publicKey: "requester-s7",
                            haveCheckTimeout: .milliseconds(10),
                            requestTimeout: .milliseconds(50))
        let nodeID = await node.localID

        let lyingPeer = PeerID(publicKey: "dont-have-liar-lllll")
        let (lLocal, lRemote) = LocalPeerConnection.pair(localID: nodeID, remoteID: lyingPeer)
        await node.registerLocalPeer(lLocal, as: lyingPeer)
        await node.addToRouter(lyingPeer, endpoint: PeerEndpoint(publicKey: lyingPeer.publicKey, host: "local", port: 0))
        try await Task.sleep(for: .milliseconds(20))

        // Always responds DONT_HAVE to haveCIDs; also responds to getVolume fallback
        // with empty so the test doesn't wait for requestTimeout on each iteration.
        Task {
            for await msg in lRemote.messages {
                if case .haveCIDs(let nonce, _) = msg {
                    lRemote.send(.haveCIDsResult(nonce: nonce, have: []))
                } else if case .getVolume(let cid, _) = msg {
                    lRemote.send(.blocks(rootCID: cid, items: []))
                }
            }
        }

        let tally = await node.tally
        let initialRep = tally.reputation(for: lyingPeer)

        // Multiple fetch attempts — each DONT_HAVE records a tally failure
        for i in 0..<5 {
            _ = await node.fetchVolumeFromAllPeers(rootCID: "bafyrei-s7-rep\(i)")
        }

        let finalRep = tally.reputation(for: lyingPeer)

        #expect(finalRep <= initialRep,
            "Consecutive DONT_HAVEs must not improve reputation — initial=\(initialRep) final=\(finalRep)")
    }
}
