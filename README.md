<p align="center">
  <img src="https://img.shields.io/badge/swift-6.0+-F05138?style=flat&logo=swift" alt="Swift 6.0+">
  <img src="https://img.shields.io/badge/platforms-macOS%20|%20iOS%20|%20tvOS%20|%20watchOS%20|%20visionOS-lightgrey" alt="Platforms">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License">
  <img src="https://img.shields.io/badge/SPM-compatible-brightgreen" alt="SPM Compatible">
</p>

# Ivy

**Reputation-routed P2P networking for content-addressed blockchains.**

Ivy is a full-featured peer-to-peer networking stack that replaces blind peer selection with evidence-based trust. Every routing decision — which peer to query, which connection to keep, who gets served under load — is informed by measured behavior: bytes relayed, latency observed, challenges solved. The result is a self-healing network where honest nodes naturally route through honest nodes.

Ivy powers the networking layer for the [Acorn](https://github.com/treehauslabs/Acorn) content-addressed storage ecosystem, with reputation accounting by [Tally](https://github.com/treehauslabs/Tally).

---

## Table of Contents

- [Why Ivy](#why-ivy)
- [Architecture](#architecture)
- [Transports](#transports)
- [NAT Traversal](#nat-traversal)
- [Content Routing](#content-routing)
- [Gossip & Announcements](#gossip--announcements)
- [Chain-Aware Networking](#chain-aware-networking)
- [Reputation System](#reputation-system)
- [Peer Health](#peer-health)
- [Quick Start](#quick-start)
- [Wire Protocol](#wire-protocol)
- [Configuration](#configuration)
- [Installation](#installation)
- [Testing](#testing)

---

## Why Ivy

Most P2P networks treat all peers equally. Connect to anyone, serve anyone, hope for the best. This works until it doesn't — Sybil attacks flood routing tables, freeloaders consume bandwidth without contributing, and eclipse attacks isolate honest nodes by surrounding them with adversaries.

Standard mitigations are blunt: proof-of-work barriers, hard-coded rate limits, random peer selection that ignores months of reliable service. A peer that has faithfully relayed data for weeks gets treated the same as one that appeared five seconds ago.

Ivy takes a different approach: **your routing table is a trust graph.**

| Property | Traditional DHT | Ivy |
|---|---|---|
| Bucket eviction | Oldest peer | Lowest reputation |
| Peer selection | Random / nearest | Reputation-ranked nearest |
| Load shedding | Drop all or none | Serve high-reputation peers first |
| Caching incentive | None | Distance-scaled reputation credit |
| Sybil resistance | Proof-of-work only | PoW bootstrap + reputation earned over time |

The network this produces:

- **Honest peers route through honest peers.** Queries travel through nodes that earned their position in your routing table through direct experience.
- **Freeloaders are progressively excluded.** Under load, only high-reputation peers get served. The system self-balances through reciprocity.
- **Caching is economically incentivized.** Serving data far from your DHT zone earns more reputation than serving data you're obligated to store, naturally forming a distributed CDN.
- **New peers can bootstrap.** Proof-of-work challenges let unknown peers earn enough reputation to participate without any existing social graph.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       Your Application                        │
│                (Lattice, cashew, or custom)                    │
└──────────────────────────┬───────────────────────────────────┘
                           │ AcornCASWorker protocol
┌──────────────────────────▼───────────────────────────────────┐
│   MemoryCASWorker → DiskCASWorker → NetworkCASWorker          │
│        (L1 cache)     (L2 persist)    (L3 network)            │
└──────────────────────────────────────────┬───────────────────┘
                                           │
┌──────────────────────────────────────────▼───────────────────┐
│                            Ivy                                │
│                                                               │
│  ┌──────────┐  ┌────────────┐  ┌───────────┐  ┌───────────┐ │
│  │  Router   │  │   Tally    │  │ Transport │  │ Announce  │ │
│  │  (DHT)    │  │   (rep)    │  │  (paths)  │  │ (gossip)  │ │
│  └─────┬─────┘  └─────┬──────┘  └─────┬─────┘  └─────┬─────┘ │
│        │              │              │              │         │
│  ┌─────▼──────────────▼──────────────▼──────────────▼───────┐ │
│  │                   Peer Connections                        │ │
│  │          TCP  ·  UDP  ·  Relay Circuits                   │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  NAT Traversal: STUN · Hole Punching · AutoNAT           │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  Discovery: Bonjour/mDNS (LAN) · Bootstrap · FIND_NODE   │ │
│  └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

---

## Transports

Ivy communicates over multiple transport layers simultaneously, selecting the best path for each message.

### TCP

Primary transport for reliable, ordered delivery. Length-prefixed binary framing over persistent connections.

- Default port: `4001`
- MTU: 512 KB
- Built on SwiftNIO for non-blocking I/O

### UDP

Lightweight transport for small, latency-sensitive messages (announces, pings, peer discovery).

- Default port: `4002`
- MTU: 500 bytes
- Datagram-based, no connection overhead

### Relay Circuits

When direct connectivity is impossible (symmetric NAT, firewalls), Ivy routes traffic through relay peers.

- Up to 4 circuits per peer, 128 total
- Circuit lifetime: 120 seconds or 128 KB transferred
- Automatic fallback to direct connection for large data transfers
- Relay-first DHT: queries forward through closest peers, caching responses along the return path

---

## NAT Traversal

Ivy uses a layered approach to establish direct connectivity across NATs and firewalls.

```
1. STUN     →  Discover public IP and port mapping
2. AutoNAT  →  Determine reachability from the outside
3. Hole Punch → Coordinate simultaneous open for cone NATs
4. Relay     →  Fall back to circuit relay if all else fails
```

**STUN** queries public servers (Google, Cloudflare) to learn your observed address. **AutoNAT** asks connected peers to verify inbound reachability. **Hole punching** coordinates with a rendezvous peer to establish direct UDP/TCP connectivity. If none of that works, traffic flows through **relay circuits** with automatic upgrade to direct when possible.

---

## Content Routing

When your application requests a CID not stored locally, the request cascades through the Acorn CAS worker chain until it reaches Ivy's `NetworkCASWorker`:

1. Find the closest peers to the CID in DHT keyspace
2. Rank candidates by Tally reputation score
3. Send `WANT_BLOCK` to the top candidates in parallel
4. Return the first valid response
5. Record bandwidth and latency in Tally for future peer selection

### Relay-First DHT

Ivy forwards DHT queries through the closest connected peers rather than requiring direct connections to every node. Each hop caches the response, building a distributed content cache along well-traveled paths.

### Trust-Weighted Routing Table

Standard Kademlia — 256 buckets, one per bit of XOR distance. The difference is eviction: when a bucket is full and a new peer arrives, Ivy evicts the peer with the **lowest Tally reputation** rather than the oldest. Over time, each bucket fills with the fastest, most reliable peers at that distance.

---

## Gossip & Announcements

Ivy uses a gossip protocol for content and peer discovery. Announcements carry cryptographic signatures and propagate through the network with TTL-based hop limits (max 128 hops).

### Block Announcements

When a node produces or receives a new block, it gossips a `ANNOUNCE_BLOCK` to connected peers. Receiving peers:

1. Check a fast-path `haveSet` — skip if already known
2. Cache the block locally
3. Re-announce to their own peers

This creates rapid, protocol-level block propagation without polling.

### Peer Announces

Periodic announcements (every 5 minutes) carry the node's public key, name hash, and optional application data. The transport layer maintains a path table (up to 10,000 entries) mapping announced destinations to the best known routes.

---

## Reputation System

Every interaction is metered by [Tally](https://github.com/treehauslabs/Tally). Reputation is local to each node — there is no global authority to compromise.

### Distance-Scaled Credit

Not all data serving is equal. Credit scales by the common prefix length (CPL) between the content hash and the serving peer's ID:

```
credit = bytes × (256 - CPL) / 256
```

- **CPL ≈ 0** (data far from peer): full credit — the peer is caching content it has no obligation to store
- **CPL ≈ 200** (data near peer): reduced credit — the peer is serving its DHT zone obligation

This creates an economic flywheel: caching popular content earns reputation, which gets you into more routing tables, which gets you more requests.

### Load Gating

When a peer sends `WANT_BLOCK`, Ivy checks `tally.shouldAllow(peer:)` before responding. Under light load, everyone gets served. Under heavy load, only high-reputation peers get through. The network degrades gracefully rather than collapsing.

---

## Peer Health

The `PeerHealthMonitor` continuously monitors connection liveness:

- Keepalive pings every 60 seconds
- Peer marked stale after 3 missed pongs or 180 seconds of silence
- Stale peers are automatically removed from the routing table
- Health events feed back into Tally for reputation adjustments

---

## Quick Start

### Starting a Node

```swift
import Ivy

let config = IvyConfig(
    publicKey: myPublicKey,
    listenPort: 4001,
    bootstrapPeers: [
        PeerEndpoint(publicKey: "abc...", host: "seed1.example.com", port: 4001),
    ],
    enableLocalDiscovery: true,
    enableRelay: true,
    enableHolePunch: true
)

let node = Ivy(config: config)
try await node.start()
```

### CAS Chain Integration

```swift
import Acorn
import AcornMemoryWorker
import AcornDiskWorker

let memory = MemoryCASWorker()
let disk = DiskCASWorker(directory: dataPath)
let network = await node.worker()

let chain = CompositeCASWorker(workers: [
    ("memory", memory),
    ("disk", disk),
    ("network", network),
])

// Reads cascade: memory → disk → network
let data = await chain.get(cid: someCID)
```

### Publishing & Announcing Blocks

```swift
// Store content in CAS, then announce the CID to the network
await node.publishBlock(cid: newBlock.rawValue)

// Or announce a CID you already have
await node.announceBlock(cid: existingBlock.rawValue)
```

### Event Handling

```swift
class MyHandler: IvyDelegate {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID) {
        print("Connected to \(peer)")
    }

    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        Task {
            let data = await chain.get(cid: ContentIdentifier(rawValue: cid))
        }
    }
}

await node.delegate = MyHandler()
```

### Inspecting Network State

```swift
let peers = await node.connectedPeers
let rep = node.tally.reputation(for: somePeer)
let pressure = node.tally.ratePressure()
let closest = node.router.closestPeers(to: targetHash, count: 10)
```

---

## Wire Protocol

Binary, length-prefixed messages over TCP:

```
┌─────────────────────┬──────────────┬─────────────────┐
│ 4 bytes: length     │ 1 byte: type │ variable: payload│
│ (big-endian uint32) │              │                  │
└─────────────────────┴──────────────┴─────────────────┘
```

| Type | Tag | Payload | Direction |
|------|:---:|---------|:---------:|
| `PING` | `0x00` | `uint64` nonce | ↔ |
| `PONG` | `0x01` | `uint64` nonce | ↔ |
| `WANT_BLOCK` | `0x02` | CID (string) | → |
| `BLOCK` | `0x03` | CID + data | ← |
| `DONT_HAVE` | `0x04` | CID (string) | ← |
| `FIND_NODE` | `0x05` | 32-byte target hash | → |
| `NEIGHBORS` | `0x06` | array of (key, host, port) | ← |
| `ANNOUNCE_BLOCK` | `0x07` | CID (string) | ↔ |

---

## Configuration

Key parameters in `IvyConfig`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `kBucketSize` | 20 | Peers per DHT bucket |
| `maxConcurrentRequests` | 6 | Parallel outbound queries |
| `requestTimeout` | 15s | Per-request deadline |
| `relayTimeout` | 5s | Relay circuit setup deadline |
| `defaultTTL` | 7 | Hop limit for forwarded messages |
| `announceInterval` | 300s | Peer announce frequency |
| `enableRelay` | `true` | Circuit relay support |
| `enableAutoNAT` | `true` | Reachability detection |
| `enableHolePunch` | `true` | NAT hole punching |
| `enableUDP` | `true` | UDP transport |
| `enableTransport` | `true` | Path-based transport layer |
| `enableLocalDiscovery` | `true` | Bonjour/mDNS on LAN |

---

## Installation

Add Ivy to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/treehauslabs/Ivy.git", branch: "main"),
]
```

Then add `"Ivy"` to your target's dependencies.

### Requirements

- Swift 6.0+
- macOS 14+ / iOS 17+ / tvOS 17+ / watchOS 10+ / visionOS 1+

### Dependencies

| Package | Role |
|---------|------|
| [Acorn](https://github.com/treehauslabs/Acorn) | Content-addressed storage protocol and types |
| [Tally](https://github.com/treehauslabs/Tally) | Reputation accounting, rate limiting, distance-scaled credit |
| [SwiftNIO](https://github.com/apple/swift-nio) | Non-blocking TCP/UDP I/O |

---

## Testing

```bash
swift test
```

22 tests across 2 suites covering message serialization (all types, framing, edge cases) and router logic (XOR distance, common prefix length, k-bucket management, reputation-weighted eviction, closest-peer queries).

---

<p align="center">
  <sub>Built by <a href="https://github.com/treehauslabs">Treehaus Labs</a></sub>
</p>
