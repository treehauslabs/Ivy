# Ivy

Peer-to-peer networking for content-addressed systems, built on trust.

## Motivation

Most P2P networks treat all peers equally. Connect to anyone, serve anyone, hope for the best. This works until it doesn't — Sybil attacks flood routing tables with malicious nodes, freeloaders consume bandwidth without contributing, and eclipse attacks isolate honest peers by surrounding them with adversaries.

The standard mitigations are blunt instruments: proof-of-work barriers to entry, hard-coded rate limits, or random peer selection that ignores months of reliable service history. A peer that has faithfully relayed data for weeks is treated the same as one that appeared five seconds ago.

Ivy takes a different approach: **your routing table is a trust graph.**

Every Kademlia k-bucket slot is a choice — which peer at this distance do you want handling your queries? Ivy fills those slots based on reputation. Peers that respond reliably and quickly rise to the top. Peers that fail, freeload, or disappear get replaced. Your routing table naturally evolves into a curated set of trusted relays at every distance in the keyspace, giving you O(log n) routing through peers you've verified through direct experience.

This isn't trust on faith. It's trust on evidence — bytes exchanged, latency measured, requests fulfilled, challenges solved. And it's local to each node, so there's no global reputation authority to compromise.

The result is a network where:
- **Honest peers route through honest peers.** Your queries travel through nodes that have earned their position in your routing table.
- **Freeloaders are progressively excluded.** Under load, only high-reputation peers get served. The system self-balances through reciprocity.
- **Caching is economically incentivized.** Serving data far from your DHT zone earns more reputation than serving data you're obligated to store, naturally creating a distributed CDN.
- **New peers can bootstrap.** Proof-of-work challenges let unknown peers earn enough reputation to participate, without requiring any existing social graph.

Ivy is the networking layer for the [Acorn](https://github.com/treehauslabs/Acorn) content-addressed storage ecosystem. It connects Acorn's local CAS chain (memory → disk) to the wider network, using [Tally](https://github.com/treehauslabs/Tally) for reputation accounting at every layer of the protocol.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Your Application                  │
│              (Lattice, cashew, or custom)            │
└──────────────────────┬──────────────────────────────┘
                       │ AcornCASWorker protocol
┌──────────────────────▼──────────────────────────────┐
│  MemoryCASWorker → DiskCASWorker → NetworkCASWorker  │
│       (L1 cache)     (L2 persist)    (L3 network)   │
└──────────────────────────────────────┬──────────────┘
                                       │
┌──────────────────────────────────────▼──────────────┐
│                        Ivy                           │
│                                                      │
│  ┌─────────┐  ┌────────┐  ┌───────────────────────┐ │
│  │ Router  │  │ Tally  │  │   Local Discovery     │ │
│  │ (DHT)   │  │ (rep)  │  │   (Bonjour/mDNS)     │ │
│  └────┬────┘  └───┬────┘  └───────────┬───────────┘ │
│       │           │                    │             │
│  ┌────▼───────────▼────────────────────▼───────────┐ │
│  │            Peer Connections                      │ │
│  │     TCP with length-prefixed message framing     │ │
│  └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

## How It Works

### Content Routing

When your application requests a CID that isn't stored locally, the request cascades through the Acorn worker chain until it reaches Ivy's `NetworkCASWorker`. Ivy then:

1. Finds the closest connected peers to the CID in the DHT keyspace
2. Ranks them by Tally reputation score
3. Sends `WANT_BLOCK` to the top candidates in parallel
4. Returns the first valid response
5. Records bandwidth and latency in Tally for future peer selection

### Trust-Line Routing

Ivy's routing table is a standard Kademlia structure — 256 buckets, one per bit of XOR distance from the local node. The difference is the eviction policy: when a bucket is full and a new peer arrives, Ivy evicts the peer with the **lowest Tally reputation** rather than the oldest.

Over time, each bucket fills with the most reliable, fastest peers at that distance. Queries naturally route through trusted nodes at every hop.

### Distance-Scaled Incentives

Not all data serving is equal. A peer relaying data far from their DHT zone is doing the network a favor — they cached something they weren't obligated to store. Ivy scales reputation credit by the common prefix length (CPL) between the data's hash and the serving peer's ID:

```
credit = bytes * (256 - CPL) / 256
```

- **CPL = 0** (data far from peer): full credit — peer is caching/relaying
- **CPL = 200** (data near peer): reduced credit — peer is serving their DHT obligation

This creates an economic flywheel: peers who cache popular content earn more reputation, which gets them into more routing tables, which gets them more requests, which earns more reputation.

### Peer Discovery

Ivy discovers peers through two channels:

- **Local**: Bonjour/mDNS advertising and browsing on the LAN. Peers on the same network find each other automatically with zero configuration.
- **Global**: Bootstrap peers and Kademlia `FIND_NODE` queries. Connect to known entry points, then iteratively discover peers across the keyspace.

Both channels feed into the same routing table and reputation system.

### Gating Under Load

When a peer sends a `WANT_BLOCK` request, Ivy checks `tally.shouldAllow(peer:)` before serving. Under light load, everyone gets served. Under heavy load, only high-reputation peers get through. This is Tally's rate-aware gating — the network degrades gracefully rather than collapsing.

## Usage

### Starting a Node

```swift
import Ivy

let config = IvyConfig(
    publicKey: myPublicKey,
    listenPort: 4001,
    bootstrapPeers: [
        PeerEndpoint(publicKey: "abc...", host: "seed1.example.com", port: 4001),
    ],
    enableLocalDiscovery: true
)

let node = Ivy(config: config)
try await node.start()
```

### Plugging into the Acorn CAS Chain

```swift
import Acorn
import AcornMemoryWorker
import AcornDiskWorker

let memory = MemoryCASWorker()
let disk = DiskCASWorker(directory: dataPath)
let network = await node.worker()

// Link the chain: memory → disk → network
let chain = CompositeCASWorker(workers: [
    ("memory", memory),
    ("disk", disk),
    ("network", network),
])

// Now any get(cid:) cascades through memory → disk → network
let data = await chain.get(cid: someCID)
```

### Announcing Blocks

```swift
await node.announceBlock(cid: newBlock.rawValue)
```

### Handling Events

```swift
class MyHandler: IvyDelegate {
    func ivy(_ ivy: Ivy, didConnect peer: PeerID) {
        print("Connected to \(peer)")
    }

    func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        // A peer announced a new block — fetch it if interesting
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

## Wire Protocol

Binary, length-prefixed messages over TCP:

```
[4 bytes: payload length (big-endian uint32)]
[1 byte: message type]
[payload]
```

| Type | Tag | Payload | Purpose |
|------|-----|---------|---------|
| `PING` | 0 | uint64 nonce | Liveness check |
| `PONG` | 1 | uint64 nonce | Liveness response |
| `WANT_BLOCK` | 2 | string CID | Request content by CID |
| `BLOCK` | 3 | string CID + data | Deliver content |
| `DONT_HAVE` | 4 | string CID | Negative response |
| `FIND_NODE` | 5 | 32 bytes target hash | DHT peer lookup |
| `NEIGHBORS` | 6 | array of (key, host, port) | DHT lookup response |
| `ANNOUNCE_BLOCK` | 7 | string CID | New content available |

## Requirements

- Swift 6.0+
- macOS 14+ / iOS 17+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/treehauslabs/Ivy.git", branch: "main"),
]
```

## Dependencies

| Package | Role |
|---------|------|
| [Acorn](https://github.com/treehauslabs/Acorn) | `AcornCASWorker` protocol, `ContentIdentifier` |
| [Tally](https://github.com/treehauslabs/Tally) | Peer reputation, rate limiting, distance-scaled accounting |
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA-256 for Kademlia node IDs and XOR distance |

## Testing

```bash
swift test
```

22 tests across 2 suites: Message (serialization roundtrips for all message types, framing, edge cases) and Router (XOR distance, common prefix length, k-bucket management, reputation-weighted eviction, closest-peer queries).
