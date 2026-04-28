# Ivy P2P Economic Model

## Overview

Ivy is a peer-to-peer network serving Lattice's multi-chain architecture. Each chain maintains its own Kademlia overlay, parent chains bootstrap child chain peer sets, and peer quality is managed through Tally reputation with PoW identity floors.

The current model uses peer exchange (PEX) with Tally reputation — nodes connect freely, serve data cooperatively, and build trust through successful exchanges. This document also describes a credit line extension that can be enabled per-node for chains that want paid data availability, without changing the protocol.

## Per-Chain Kademlia Overlays

### One Overlay Per Chain

Each chain in the Lattice tree operates its own Kademlia DHT. A node's routing table for chain X contains K entries — peers that participate in chain X, each tracked by Tally for reputation.

All chain operations stay within the chain's overlay:

- **Pin discovery** (`findPins`): Route toward K closest nodes to a CID hash within the chain's keyspace. Those nodes store pin announcements for that chain's data.
- **Data retrieval** (`getVolume`): Request data from peers within the chain overlay. DHT forwarding reaches pinners through intermediaries if needed.
- **Block gossip**: Announce new blocks to chain overlay peers.
- **Pin announcements** (`pinAnnounce`): Declare that you serve specific CIDs, stored by K closest nodes in the chain overlay.

There is no global routing table. The nexus chain's overlay (which every node participates in, since merged mining requires it) is the root of the tree, not a separate discovery layer.

### Routing Table Structure

Each per-chain routing table follows Kademlia structure:

| Parameter | Description |
|-----------|-------------|
| K | Bucket size (entries per distance bucket) |
| Alpha | Lookup concurrency (parallel queries per round) |
| Buckets | Organized by XOR distance from local node ID |

Each entry is a `BucketEntry` containing the peer's identity, endpoint, and Tally reputation. Eviction follows reputation-weighted Kademlia rules: a new peer only replaces an existing entry if it has higher Tally reputation than the lowest-reputation entry in the bucket.

### Why Per-Chain

A single global routing table organized by XOR distance to the local node's ID distributes entries across the keyspace — but those entries are random with respect to any specific child chain. If chain X has 50 participants out of 10,000 nodes, the probability that any of the K global routing entries serve chain X is negligible.

Per-chain tables ensure:
- `findPins` for chain X CIDs routes through chain X peers who actually store relevant pin announcements
- Block gossip reaches chain X participants directly
- Data retrieval stays within the chain's peer set
- Peer exchange discovers more chain X participants, not random global nodes

### Multi-Chain Peers

A single physical connection between two nodes serves all chains they both participate in. Peers advertise which chains they serve, and each node places the peer into the routing table for every shared chain.

```
Node A serves: [Nexus, Chain X, Chain Y]
Node B serves: [Nexus, Chain X, Chain Z]

One TCP connection between A and B.
B appears in A's routing tables for: Nexus, Chain X
A appears in B's routing tables for: Nexus, Chain X
```

This means:
- **One connection, many roles.** A peer in your nexus routing table that also serves chain X appears in both tables. No duplicate connections.
- **Shared Tally reputation.** A peer's behavior on one chain informs its reputation on all shared chains. A peer that delivers blocks reliably on the nexus is likely reliable on chain X too.
- **Chain membership is dynamic.** A peer can start serving a new child chain at any time. It announces the new chain, and connected peers add it to that chain's routing table without reconnecting.
- **Message routing is chain-scoped.** Each message is tagged with its chain context. A `findPins` for chain X routes through chain X's routing table, even if the physical connection also carries nexus traffic.
- **Routing table slots are independent.** A peer consuming a slot in the nexus table does not consume a slot in chain X's table — each chain has its own K-bucket structure. A well-connected peer may appear in many chain tables simultaneously.

## Parent-Child Chain Bootstrap

### The Bootstrap Problem

When a node discovers a new child chain (via a `GenesisAction` on the parent chain), it needs peers for that chain's overlay. But it has no connections to child chain peers yet.

Pin discovery on the nexus DHT cannot solve this — the nexus keyspace is organized around nexus peer IDs, and the K closest nexus nodes to a child chain CID hash have no reason to know about child chain pinners.

### Resolution Through Merged Mining

Parent chain peers already have child chain data. Merged mining means parent chain blocks embed child chain blocks — every parent chain peer that processed the `GenesisAction` has the child chain's genesis and subsequent blocks.

The bootstrap flow:

1. Node is on the parent chain, connected to parent chain peers.
2. A parent chain block arrives containing a `GenesisAction` for child chain X. The genesis CID is now known.
3. Parent chain peers that processed this block already serve chain X data.
4. Those peers become the initial entries in the node's chain X routing table.
5. Through those initial peers, the node discovers more chain X participants via peer exchange and builds out the routing table.

### Hierarchical Bootstrap

This mechanism is recursive. It is not specific to the nexus:

- The nexus bootstraps its direct children
- Each child chain bootstraps its own children
- Each grandchild bootstraps its children

Every chain bootstraps the chains it parents. The parent-child relationship is the only cross-chain link. The nexus is the root of the tree, but has no special discovery role beyond being the chain that every node participates in.

### Reputation Inheritance

When a parent chain peer becomes an initial entry in a child chain routing table, it starts with fresh Tally scores on the child chain — but the node already has reputation data for that peer from the parent chain. This history informs how the node prioritizes among its initial child chain peers, giving established peers a natural advantage over unknown ones.

## Node Records

### Identity-to-Endpoint Resolution

NodeRecords are signed, versioned records that map a node's public key to its network endpoint (host, port). They enable endpoint discovery without on-chain state.

| Field | Description |
|-------|-------------|
| publicKey | Node identity (hex-encoded Curve25519 public key) |
| host | IP address or hostname |
| port | Listening port |
| sequenceNumber | Monotonically increasing; incremented on any field change |
| signature | Curve25519 EdDSA signature over all other fields |

### Properties

- **Max size**: 300 bytes
- **Self-signed only**: Records can only be created by the key owner
- **Sequence-based conflict resolution**: Higher sequence number always supersedes lower for the same public key
- **Query-only propagation**: Records are never re-gossiped. Served in response to `getNodeRecord` queries and exchanged during the connection handshake.
- **Auto-updated**: When a node discovers its public address changes (via peer feedback, requiring 10+ independent confirmations within 5 minutes), it increments the sequence number and re-signs.

### Cache

Each node maintains a bounded LRU cache of NodeRecords (up to 5,000 entries). Validation before caching:

1. Signature verification
2. Sequence number must exceed any cached record for that public key
3. Record size within 300-byte limit

## Trust and Reputation

### Tally

Each node maintains per-peer reputation scores via Tally. Scores are computed from:

| Signal | Weight | Description |
|--------|--------|-------------|
| Reciprocity | Configurable | Balance of bytes sent vs received |
| Latency | Configurable | Response time relative to baseline |
| Success rate | Configurable | Fraction of requests that succeed |
| Challenge hardness | Configurable | Proof-of-work challenges completed |
| PoW identity | Configurable | Trailing zero bits in SHA-256 of public key |

The PoW identity floor gives new peers a baseline reputation proportional to the computational cost of generating their identity — a lightweight sybil resistance mechanism that works before any behavioral data is available.

### Peer Quality Enforcement

Tally reputation determines:
- **Routing table eviction**: Low-reputation peers are replaced by higher-reputation newcomers
- **Request prioritization**: High-reputation peers get served first under load
- **DHT forwarding**: Requests from low-reputation peers may be deprioritized or dropped
- **Connection acceptance**: Nodes can set minimum reputation thresholds for inbound connections

## Peer Sufficiency

### Per-Chain Requirements

Each chain overlay needs enough peers for reliable operation:

- Block gossip requires mesh connectivity (target: K peers per chain)
- Pin discovery requires coverage of the keyspace (Kademlia's bucket structure ensures this with K entries)
- Data retrieval requires reachable pinners (DHT forwarding handles multi-hop if direct connections don't cover the pinner)

### Maintenance

Nodes monitor per-chain peer counts. When a chain's routing table falls below a minimum threshold:

1. Query existing chain peers for additional peers (peer exchange within the chain overlay)
2. Ask parent chain peers for more child chain participants (re-bootstrap from parent)
3. Accept inbound connections from new chain participants

## Future Extension: Credit Line Routing

The current PEX + Tally model treats all data exchange as cooperative. The protocol supports a credit line extension where each routing table entry becomes a bilateral payment channel, enabling paid data retrieval and relay fees. This section documents the design for future implementation.

### Credit Line Channels

Every pair of connected peers would maintain a bilateral credit line. Each side independently sets how much credit it extends to the other.

| Field | Description |
|-------|-------------|
| Balance | Current net position (positive = peer owes you, negative = you owe peer) |
| Local limit | Maximum credit you extend to this peer |
| Remote limit | Maximum credit the peer extends to you |
| Settlement history | Track record of successful settlements |

### Credit Line Path Routing

When node A wants data pinned by node C, but A is not directly connected to C, the request routes through intermediaries:

```
A --[credit line]--> B --[credit line]--> C
       pays B              pays C
       B earns relay fee
```

Each hop deducts from the sender's credit line. The relay keeps the difference as profit. Relays have skin in the game: B fronts credit to C on A's behalf, so B only routes through peers it trusts.

### Relationship to PEX + Tally

The credit line model is a strict superset of PEX + Tally. Setting credit limits to maximum and relay fees to zero reproduces cooperative PEX behavior exactly. The protocol wire format does not change — credit line accounting is purely local state.

This means nodes can independently choose where they sit on the altruistic-to-mercenary spectrum:

- Generous defaults: high limits, zero fees — indistinguishable from plain PEX
- Strict limits: enforce credit limits, charge relay fees — paid data availability for specific chains

The transition from cooperative to paid is a per-node configuration change, not a protocol upgrade.

### Settlement

Settlement is entirely off-chain, negotiated between peers:

- Mutual balance reset (symmetric traffic nets to roughly zero)
- On-chain token transfer on any chain both peers participate in
- External payment
- Credit rollover

Settlement history feeds into Tally reputation, creating a virtuous cycle: reliable settlement leads to higher reputation, which enables higher credit limits.

## Summary

| Layer | Current Model | Future Extension |
|-------|--------------|-----------------|
| Identity | PoW-difficulty public keys, NodeRecords | Same |
| Connectivity | Per-chain Kademlia routing tables | Same, entries become credit line channels |
| Discovery | Pin announcements within chain overlays, parent-chain bootstrap | Same |
| Economics | Cooperative (PEX + Tally reputation) | Credit line path routing with optional relay fees |
| Trust | Tally reputation: reciprocity, latency, success rate, PoW floor | Same + settlement track record |
| Topology | Kademlia O(log N) per chain | Same, small-world clustering from credit line relationships |
