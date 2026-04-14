# Ivy: SOTA Blockchain Networking Gap Analysis

**Date: April 2026**

This document inventories what Ivy currently implements versus what state-of-the-art blockchain networking protocols provide, identifies gaps, and prioritizes future work.

---

## 1. Current Ivy Capabilities

### Wire Protocol (45 message types)
- **Core**: ping/pong, identify, block, dontHave, announceBlock, wantBlocks
- **DHT**: findNode, neighbors, dhtForward (fee-aware, TTL-bounded)
- **Compact blocks (BIP 152-inspired)**: compactBlock, getBlockTxns, blockTxns
- **Transaction gossip**: newTxHashes, getTxns, txns
- **Block range sync**: getBlockRange, blockRange
- **Replication**: getZoneInventory, zoneInventory, haveCIDs, haveCIDsResult
- **Volume-aware**: getVolume, announceVolume (with totalSize + chainPath), pushVolume
- **Economic**: findPins, pins, pinAnnounce, pinStored, feeExhausted, directOffer, deliveryAck, balanceCheck, balanceLog, miningChallenge, miningChallengeSolution, settlementProof
- **Generic**: peerMessage (topic-based), blocks (batch), chainAnnounce

### Key Optimizations Already Implemented
| Technique | Inspired By | Status |
|---|---|---|
| Compact blocks | BIP 152 | Full (compactBlock + getBlockTxns + blockTxns) |
| High-bandwidth push | BIP 152 high-BW mode | Full (pushVolume to top-N reputation peers) |
| Size-annotated announcements | eth/68 | Full (announceVolume includes totalSize + chainPath) |
| Volume-aware storage co-location | Novel | Full (ProfitWeightedStore groups volume members, evicts by access frequency) |
| Volume-aware replication | Novel | Full (replication pushes entire volumes as units) |
| Volume-aware zone sync | Novel | Full (handleZoneInventory batches getVolume by root) |
| Fee-based DHT forwarding | Novel (Ivy economic layer) | Full |
| Reputation-based peer selection | GossipSub scoring | Partial (Tally reputation, but single-dimensional) |
| Peer health monitoring | Bitcoin keepalive | Full (ping/pong + stale detection + eviction) |
| Peer exchange (PEX) | BitTorrent PEX | Full |

---

## 2. Gap Analysis

### 2.1 Set Reconciliation (Erlay / BIP 330)

**What it is**: Instead of flooding every transaction hash to every peer, nodes periodically exchange compact "sketches" (Minisketch/PinSketch) of their transaction sets. The sketch of the symmetric difference reveals which transactions each side is missing. Only those are requested.

**Why it matters**: Transaction announcements consume ~44% of Bitcoin node bandwidth. Erlay reduces this to bandwidth proportional to the *difference* between sets, not the set size. This also decouples relay bandwidth from connection count, enabling nodes to maintain more connections (better eclipse resistance) without proportional bandwidth cost.

**Ivy gap**: Ivy's `newTxHashes` floods all hashes to all peers. The `haveCIDs`/`haveCIDsResult` replication probe sends full CID lists. Neither uses set reconciliation.

**Impact**: High. Directly reduces bandwidth for zone sync, replication probes, and transaction relay. Enables higher peer counts.

**Implementation sketch**:
- Add a Minisketch implementation (BCH-code based, ~32-bit short IDs)
- New messages: `reconcileSketch(nonce, sketch)`, `reconcileRequest(nonce, missing)`
- Replace periodic `haveCIDs` full-set probes with sketch exchange
- Transaction relay: flood to outbound peers only, reconcile with all peers periodically
- Fallback: if sketch decode fails (difference > capacity), bisect and retry

**References**: BIP 330, Erlay paper (Naumenko et al., 2019), Minisketch library

---

### 2.2 Erasure Coding for Block Propagation

**What it is**: Reed-Solomon coding splits a block into `k` data shreds and generates `n-k` parity shreds. Any `k` of `n` total shreds suffice to reconstruct the block. Shreds are distributed across different peers/paths.

**Why it matters**: Solana's Turbine uses 32:32 erasure coding (tolerates 50% loss) to propagate ~100MB/s of block data across thousands of validators in ~200ms. Without erasure coding, packet loss requires retransmission round-trips that compound at each relay hop.

**Ivy gap**: No erasure coding. Block propagation relies on full retransmission or compact block reconstruction. For high-throughput chains on Lattice, this will be a bottleneck.

**Impact**: High for high-throughput chains. Lower priority for low-TPS chains where compact blocks suffice.

**Implementation sketch**:
- Reed-Solomon encoder/decoder (k data + m parity shreds, configurable ratio)
- New messages: `shred(rootCID, index, totalShreds, dataShreds, data, merkleProof)`, `getShreds(rootCID, indices)`
- Per-shred Merkle proofs for independent verification
- Integrate with Turbine-style tree propagation: send different shreds to different peers, who forward to their subtrees
- Composable with volumes: each volume member could be independently erasure-coded

**References**: Solana Turbine, Reed-Solomon (ISA-L, leopard-RS), Solana Alpenglow/Rotor proposal

---

### 2.3 Graphene (IBLT + Bloom Filter Block Propagation)

**What it is**: Encodes a block's transaction set as a Bloom filter + IBLT (Invertible Bloom Lookup Table). The receiver filters its mempool through the Bloom filter, constructs its own IBLT, and subtracts to find the set difference. Encodes block contents in ~10% of compact block size when mempool overlap is high.

**Why it matters**: For chains where >95% of block transactions are already in the receiver's mempool (common for PoW chains with predictable block contents), Graphene dramatically outperforms compact blocks. Even for moderate overlap (80-90%), the savings are significant.

**Ivy gap**: No IBLT implementation. Compact blocks send all short tx IDs regardless of mempool overlap. No way to leverage high mempool overlap for sub-linear encoding.

**Impact**: Medium. Most impactful for chains with stable mempools and predictable block construction. Less useful for chains with high transaction churn.

**Implementation sketch**:
- IBLT implementation (hash table with XOR-based cell values, iterative peeling decode)
- Extended compact block: sender includes Bloom filter + IBLT instead of full tx ID list
- Receiver: filter mempool through Bloom filter, IBLT-subtract, decode difference
- Fallback to full compact block if IBLT decode fails
- Requires canonical transaction ordering within blocks

**References**: Graphene paper (Ozisik et al., 2019), Practical Rateless Set Reconciliation (SIGCOMM 2024)

---

### 2.4 Connection Type Differentiation

**What it is**: Bitcoin Core maintains distinct connection types: 8 full-relay outbound, 2 block-relay-only outbound, 1 feeler, and up to 114 inbound. Block-relay-only connections relay blocks but not transactions, making them invisible to transaction-timing fingerprinting attacks.

**Why it matters**: Homogeneous connections leak information (transaction origin timing) and are vulnerable to eclipse attacks (attacker fills all slots with controlled nodes). Differentiated connections provide privacy (block-relay-only peers can't fingerprint transactions) and partition resistance (diverse connection types are harder to monopolize).

**Ivy gap**: Single connection type (`PeerConnection`). All connections relay all message types. The `highBandwidthPeers` config distinguishes behavior but not connection type. No feeler connections. No anchor persistence across restarts.

**Impact**: Medium-High. Critical for chains where transaction privacy matters and for eclipse resistance in adversarial networks.

**Implementation sketch**:
- `ConnectionType` enum: `.fullRelay`, `.blockRelayOnly`, `.feeler`, `.inbound`
- Block-relay-only: filter message handling to only process block-related messages
- Feeler connections: periodic short-lived outbound connections to test reachability, populate routing table
- Anchor persistence: save block-relay-only peer endpoints to disk, reconnect on restart
- Peer rotation: periodically connect to a random peer; if it provides a novel block, replace a block-relay-only peer

**References**: Bitcoin Core PR #15759 (block-relay-only), PR #17428 (anchors), PR #19858 (peer rotation)

---

### 2.5 Multi-Dimensional Peer Eviction

**What it is**: When connection slots are full, Bitcoin Core protects peers across multiple dimensions before evicting: fastest ping (4), most recent transaction relayer (4), most recent block relayer (4), longest uptime (4), most diverse network group (4). Only unprotected peers from the largest network group are eviction candidates.

**Why it matters**: Single-metric eviction (e.g., only by reputation) can be gamed. An attacker who provides fast responses but no novel data would survive eviction. Multi-dimensional protection ensures no single attack vector can monopolize connection slots.

**Ivy gap**: Tally reputation is a single composite score. No multi-dimensional protection. No ASN/netgroup-based diversity enforcement. Eviction is binary (health monitor marks stale, then disconnects).

**Impact**: Medium. Important for adversarial environments. Less critical for permissioned or small networks.

**Implementation sketch**:
- Protect top-4 peers by: lowest latency, most recent useful block, most recent useful transaction, longest uptime, most diverse IP prefix
- Track per-peer metrics in PeerHealthMonitor: `lastUsefulBlock`, `lastUsefulTx`, `avgLatency`, `connectedSince`
- IP-prefix diversity: group peers by /16 (IPv4) or /32 (IPv6), protect representatives from each group
- Eviction candidate: from the largest unprotected IP group, evict the peer with lowest Tally reputation

**References**: Bitcoin Core eviction logic, Eclipse Attacks on Bitcoin's P2P Network (Heilman et al., USENIX 2015)

---

### 2.6 Cut-Through / Streaming Block Relay

**What it is**: Instead of store-and-forward (receive entire block, validate, then forward), begin forwarding packets as they arrive after checking only the block header. The block is reconstructed at each node in parallel with forwarding.

**Why it matters**: For large blocks, store-and-forward adds latency proportional to block_size/bandwidth at each hop. Cut-through reduces this to packet_size/bandwidth per hop. The FIBRE relay network achieved near-speed-of-light block propagation using this technique combined with FEC.

**Ivy gap**: `MessageFrameDecoder` buffers entire messages (up to 4MB) before dispatching. No streaming decode or partial forwarding. All message handling is atomic.

**Impact**: Medium. Most impactful for chains with large blocks (>1MB) and multi-hop relay paths. Less important for chains where blocks fit in a single packet.

**Implementation sketch**:
- Streaming message framing: header indicates total size, handler can act after header arrives
- New message type: `streamBlock(rootCID, totalShreds, shredIndex, data)` — each shred independently forwardable
- Pre-validation forwarding: check PoW/header after first shred, forward remaining shreds optimistically
- Composable with erasure coding: each shred can be independently forwarded and verified via Merkle proof
- Penalty: if validation ultimately fails, penalize the forwarding peer in Tally

**References**: FIBRE (bitcoinfibre.org), Falcon relay network, Bodyless Block Propagation (2024)

---

### 2.7 Data Availability Sampling (DAS)

**What it is**: Light clients verify that block data was published without downloading all of it. Data is erasure-coded and committed via KZG polynomial commitments. Clients randomly sample a small number of chunks (30-40); if all pass verification, there is high statistical confidence (>99.9999%) the full data is available.

**Why it matters**: DAS enables light clients to participate in data availability verification without full node resources. This is foundational for modular blockchains (Celestia, Ethereum post-Fusaka) where execution, consensus, and data availability are separated.

**Ivy gap**: No DAS primitives. No erasure coding (prerequisite). No KZG commitment support. No column/row-based gossip subscription.

**Impact**: Low-Medium for Lattice today. High if Lattice adopts a modular architecture where data availability is separated from execution. This is a forward-looking capability.

**Implementation sketch**:
- Prerequisite: erasure coding (Gap 2.2)
- Column-based gossip: extend `peerMessage` topics to support column subscriptions
- Custody assignment: deterministic column assignment based on node ID hash
- New messages: `getColumn(blockCID, columnIndex)`, `column(blockCID, columnIndex, data, proof)`
- Sampling API: `sampleAvailability(blockCID, sampleCount) -> Bool`
- KZG is application-layer cryptography; Ivy transports commitments and proofs as opaque blobs

**References**: EIP-7594 (PeerDAS), Celestia 2D Reed-Solomon, Danksharding proposal

---

### 2.8 Typed Transaction Announcements

**What it is**: Ethereum's eth/68 extends transaction hash announcements with per-transaction type and size metadata. Receivers can make accept/reject decisions without a follow-up request.

**Why it matters**: Prevents wasting bandwidth requesting transactions a node can't or won't process (e.g., blob transactions without blob storage, oversized transactions under bandwidth pressure).

**Ivy gap**: `newTxHashes` sends only `(chainHash, txHashes)`. No per-transaction metadata. Receivers must request transactions blind.

**Impact**: Low-Medium. Useful once Lattice supports multiple transaction types with different processing requirements.

**Implementation sketch**:
- Extend `newTxHashes` to `newTxAnnounce(chainHash, announcements: [(hash, type, size)])`
- Receiver filters by type (skip unsupported types) and size (budget bandwidth)
- Backward-compatible: old `newTxHashes` still works, new message is additive

**References**: Ethereum eth/68 specification

---

### 2.9 Bandwidth Budgeting Per Peer

**What it is**: Per-peer send queues with size limits, priority-based send scheduling, and global upload caps. Bitcoin Core implements `maxuploadtarget` and per-peer rate management.

**Why it matters**: A single slow or abusive peer can consume disproportionate send buffer resources, delaying messages to other peers. Global upload limits prevent nodes on constrained connections from being overwhelmed.

**Ivy gap**: All sends are immediate `fireAndForget` or `writeAndFlush`. No send queue, no per-peer budget, no global upload limit, no message prioritization. Tally's `shouldAllow` is a binary gate, not a rate limiter.

**Impact**: Medium. Important for nodes on bandwidth-constrained connections and for preventing amplification attacks.

**Implementation sketch**:
- Per-peer send queue with priority levels: P0 (blocks/consensus), P1 (transactions), P2 (historical/zone sync)
- Per-peer byte budget per interval (e.g., 1MB/s default, configurable)
- Global upload cap (e.g., 200GB/day, stops serving historical data when approaching limit)
- Adaptive: increase budget for peers that provide useful data (new blocks, novel transactions)

**References**: Bitcoin Core `maxuploadtarget`, Per-peer message processing (PR #19398)

---

### 2.10 Cross-Chain Message Routing (IBC-style)

**What it is**: Standardized cross-chain communication where chains maintain light clients of each other and off-chain relayers transport state proofs between them. Used by Cosmos IBC (115+ connected chains) and Polkadot XCM.

**Why it matters**: Lattice is a multi-chain architecture. Chains in the hierarchy need to communicate: child chains settle to parent chains, cross-chain transfers need proof relay, and shared security (merged mining) needs coordination.

**Ivy gap**: `chainAnnounce` broadcasts to a destination hash, and `chainPath` identifies chains in the hierarchy, but there is no structured cross-chain message protocol. No light client state management. No proof relay. Cross-chain communication is currently application-layer responsibility.

**Impact**: Medium-High for Lattice. Cross-chain messaging is fundamental to a multi-chain architecture, but much of the complexity is in the consensus/application layer rather than the P2P layer.

**Implementation sketch**:
- New messages: `crossChainPacket(sourceChain, destChain, proof, payload)`, `crossChainAck(sourceChain, destChain, sequence)`
- Routing: use `chainPath` to route packets through the chain hierarchy
- Relayer role: any Ivy node can relay cross-chain packets (permissionless)
- Light client verification is application-layer; Ivy transports proofs opaquely
- Sequence-based ordering for reliable delivery

**References**: Cosmos IBC, Polkadot XCM, IBC v2 specification

---

## 3. Priority Matrix

| Gap | Impact | Complexity | Priority |
|---|---|---|---|
| 2.1 Set Reconciliation (Erlay) | High | High | **P0** |
| 2.2 Erasure Coding | High | High | **P0** |
| 2.4 Connection Type Differentiation | Med-High | Medium | **P1** |
| 2.10 Cross-Chain Message Routing | Med-High | High | **P1** |
| 2.5 Multi-Dimensional Eviction | Medium | Low | **P1** |
| 2.9 Bandwidth Budgeting | Medium | Medium | **P1** |
| 2.6 Cut-Through Relay | Medium | High | **P2** |
| 2.3 Graphene (IBLT) | Medium | High | **P2** |
| 2.8 Typed Tx Announcements | Low-Med | Low | **P2** |
| 2.7 Data Availability Sampling | Low-Med | Very High | **P3** |

**P0** = Implement next. Direct bandwidth/latency improvement for all chains.
**P1** = Implement for production hardening. Security and multi-chain support.
**P2** = Implement when specific chain requirements demand it.
**P3** = Forward-looking. Implement when Lattice architecture requires it.

---

## 4. Dependency Graph

```
Erasure Coding (2.2)
  └─> Cut-Through Relay (2.6)
  └─> Data Availability Sampling (2.7)
        └─> Column Gossip (requires peerMessage topic extensions)

Set Reconciliation (2.1)
  └─> Graphene (2.3) — shares IBLT primitive

Connection Types (2.4)
  └─> Multi-Dimensional Eviction (2.5) — eviction policy uses connection type

Cross-Chain Routing (2.10)
  └─> Uses chainPath (already implemented)
  └─> Independent of other gaps
```

---

## 5. What Ivy Already Does Better

Ivy has unique capabilities that most blockchain P2P networks lack:

1. **Fee-based DHT forwarding**: Every hop has an economic cost. This is Sybil-resistant by design — spam costs real credit. No other major blockchain P2P network has per-hop economic routing.

2. **Volume-aware everything**: Storage co-location, batch fetching, batch replication, batch zone sync. Blocks and transactions as semantic units (volumes) rather than individual CIDs. This is a novel contribution not found in Bitcoin, Ethereum, or Solana networking.

3. **Productive settlement via merged mining**: Debt settlement generates useful PoW for the blockchain. This turns an economic obligation into a security contribution. Unique to Ivy.

4. **Reputation-routed DHT**: Kademlia routing modified by Tally reputation scores. Peers that serve data reliably get better routing table positions. This is more sophisticated than Bitcoin's random peer selection or Ethereum's static reputation scores.

5. **Credit line economics**: Bilateral IOUs with threshold-based settlement avoid per-transaction blockchain overhead. Hundreds of micropayments aggregate into a single settlement event.
