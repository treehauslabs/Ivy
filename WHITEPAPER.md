# Ivy: A Cooperative Peer-to-Peer Data Storage and Retrieval Network

**Version 1.1 — Draft**

---

## Abstract

Ivy is a peer-to-peer protocol for cooperative data storage and retrieval where trust is the fundamental economic primitive. Rather than relying on a blockchain for every transaction, Ivy overlays bilateral credit lines onto a Kademlia-style DHT. Balances accumulate as peers forward and serve content, with settlement required only when a threshold is exceeded. Settlement is productive: debtors clear their balances by mining blocks for any compatible PoW blockchain, where every hash is a lottery ticket. Merged mining across multiple chains makes block discovery probable during typical settlements. Peers with cryptographically expensive identities receive higher base trust, creating a Sybil-resistant identity layer without a central authority.

---

## 1. Introduction

Decentralized storage networks face a trilemma: they must be **Sybil-resistant**, **low-latency**, and **economically sustainable** without imposing excessive coordination costs. Existing approaches typically sacrifice one:

- **IPFS/BitTorrent**: Free retrieval but no persistence guarantees and weak Sybil resistance.
- **Filecoin/Arweave**: On-chain settlement for every storage deal imposes latency and fee overhead.
- **Traditional CDNs**: Low latency but centralized trust and pricing.

Ivy resolves this by overlaying an economic layer onto standard DHT routing. Every connected peer pair maintains a credit line — a bilateral IOU that adjusts as services are exchanged. Retrieval requests forward through the DHT as usual, and each hop charges its upstream neighbor. Settlement occurs only when the accumulated imbalance exceeds a trust threshold. When it does, the debtor settles by mining blocks for any PoW blockchain the creditor chooses — every hash is a lottery ticket, and merged mining across multiple chains makes productive settlement the norm. This makes per-block retrieval payments practical: hundreds of micropayments accumulate into a single mining session, with no per-transaction chain overhead.

---

## 2. Identity and Sybil Resistance

### 2.1 Proof-of-Work Key Generation

Every peer is identified by a public key. The **difficulty** of a key is defined as the number of trailing zero bits in `SHA256(publicKey)`. Each additional trailing zero bit doubles the expected computational work required to find such a key.

```
difficulty(pk) = trailingZeroBits(SHA256(pk))
```

Concretely: a peer generates candidate Curve25519 private keys at random, derives the corresponding public key, computes SHA256 of the public key, and checks the trailing zero bits. A key with 24 trailing zero bits required evaluation of roughly 2^24 (~16 million) candidate keys — meaningful work on commodity hardware, but not a barrier to legitimate participation. A key with 32+ trailing zero bits represents substantial investment.

### 2.2 Base Trust Scoring

Key difficulty translates directly into **base trust** — the initial credit line a new peer receives before any interaction history:

```
baseTrust(pk) = clamp((difficulty(pk) - minDifficulty) / (maxDifficulty - minDifficulty), 0, 1)
```

Where `minDifficulty` and `maxDifficulty` are configurable parameters. This gives harder keys a head start without making low-difficulty keys unable to participate — they simply start with smaller credit lines and must build reputation through reliable service.

### 2.3 Difficulty Tiers

| Tier         | Trailing Zero Bits | Approx. Work   |
|--------------|-------------------|-----------------|
| None         | 0-7               | Trivial         |
| Low          | 8-15              | ~256 keys       |
| Medium       | 16-23             | ~65K keys       |
| High         | 24-31             | ~16M keys       |
| Exceptional  | 32+               | ~4B keys        |

### 2.4 Bootstrapping New Peers

1. **Minimum base trust**: Even zero-difficulty keys receive a small, non-zero credit line — enough for a few trial interactions.
2. **Key investment**: Peers expecting to participate seriously invest computation upfront in key generation, arriving with a meaningful base trust.
3. **Routing table bootstrap**: A new peer connects to a bootstrap node and performs `findNode(self.hash)` lookups to discover nearby peers (see Section 5.1). Each connection establishes a new credit line (at baseTrust) and inserts the new peer into others' routing tables. After O(log n) rounds, the peer has a populated routing table and is reachable by the network. The cost is a few control-rate `findNode` queries — trivially covered by the minimum base trust. Once routing is established, the peer begins earning fees by serving DHT queries and forwarding requests.

---

## 3. Unit of Account: Work-Denominated Credits

Bilateral balances require a common denomination. Ivy denominates all balances and rates in **work-denominated credits (ivy)**. One ivy is defined as the expected computational work to find a SHA256 hash with 16 trailing zero bits:

```
1 ivy = 2^16 expected SHA256 evaluations (~65,536 hashes)
```

This definition is:

- **Universally measurable**: Any peer can verify "how much work does N ivy represent" without a price oracle.
- **Anchored to physical reality**: Computation has real energy and hardware costs, giving the unit a natural floor value.
- **Compatible with PoW settlement**: Settling a debt of N ivy means performing N ivy of computational work. The unit of account and the settlement mechanism are the same thing.
- **Consensus-free**: Two peers need only agree that 1 ivy = this much work. No minting, no blockchain, no coordination.

Ivy is a unit of **work**, not a unit of **value**. The real cost of 1 ivy varies by hardware — cheap on an ASIC, expensive on a phone. This is efficient, not unfair: peers with more computational resources can offer lower fees, attracting more traffic. The fee-bid mechanism (Section 5.1) determines value — what requesters are willing to pay for content, denominated in the common work unit.

Rate schedules denominate in ivy: retrieval in ivy per block, storage in ivy per byte per day. Forwarding fees are set per-request by the requester as a fee bid (Section 5.1).

---

## 4. Content-Addressed Storage Interface

Ivy exposes a content-addressed storage (CAS) interface to applications:

```
get(cid, selector) -> [Block]
save(cid, data, pin: PinOptions?) -> Bool
```

- **cid**: A content identifier (hash of the root of a data structure).
- **selector**: A path into the content-addressed DAG describing which subset to retrieve. Selector semantics — including path expressions, containment rules, and DAG traversal behavior — are defined by the Cashew content-addressed data model. When omitted, the entire object at the CID is returned.

Data in Ivy is structured as a **DAG (directed acyclic graph)** of content-addressed blocks, where each block's CID is the hash of its contents and blocks reference each other by CID. A root CID is the entry point to an arbitrarily complex data structure — a file, a directory, a database snapshot.

### 4.1 Selectors and Pin Announcements

A **selector** describes a subset of a DAG. When a peer pins content, its pin announcement includes both the root CID and the selector describing which portion of the DAG it holds:

```
pinAnnounce(rootCID, selector, pinnerPublicKey, expiry, signature, fee)
```

A peer may hold the entire DAG (selector = root) or only a subset (e.g., a specific subtree, a range of entries). Different peers may hold different subsets of the same root — the DHT stores all their announcements, allowing a retriever to find the set of peers that collectively covers the data it needs.

### 4.2 Retrieval

Retrieval is two phases: **discover** who has the data (`findPins`), then **fetch** directly toward the pinner (`dhtForward` with a target hint). Both use the same fee model — the requester sets a fee, forwarders take cuts, the destination keeps the remainder. The full retrieval flow is described in Section 5.2.

The node handles all of this transparently — the application just calls `get(cid, selector)`.

---

## 5. DHT Economics

### 5.1 Uniform Per-Hop Charging

All DHT operations — `findPins`, `findNode`, `dhtForward`, and `pinAnnounce` — are charged uniformly. Each hop charges its upstream neighbor **on response relay**: the balance is adjusted only when the response successfully passes back through the hop. No charge on failure. This applies to every message relayed through the DHT:

```
findPins:     A -> B -> N: findPins(cid, fee: 10)           Discovery
              N -> B -> A: pins([...])                       Each hop paid from fee

findNode:     A -> B -> E: findNode(target, fee: 10)         Peer location
              E -> B -> A: neighbors([...])                  Each hop paid from fee

dhtForward:   A -> B -> Z: dhtForward(cid, sel, fee: 50)     Data fetch
              Z -> B -> A: blocks([...])                     Each hop paid from fee

pinAnnounce:  M -> B -> C: pinAnnounce(cid, sel, fee: 5)     Announce availability
              C -> B -> M: pinStored(cid)                     Each hop paid from fee
```

Every DHT service is economically accountable. Nodes are incentivized to maintain accurate routing tables (good routing attracts `findNode` traffic), store pin announcements reliably (`findPins` queries earn fees), and cache content (`dhtForward` responses earn the most — proportional to data size).

**Request fees**: Every request carries a **fee** set by the requester — the total amount the requester is willing to pay for the entire operation. Each forwarder deducts its relay fee from the remaining fee before forwarding. The **destination keeps whatever is left** — this is the content payment. If the remaining fee hits zero before reaching the destination, the request fails (the route is too expensive). If the request succeeds (response relays back), every hop in the chain gets paid. If it fails (timeout, `dontHave`), nobody pays.

```
A -> B: dhtForward(cid, sel, fee: 50)    B takes 3, forwards with fee: 47
B -> N: dhtForward(cid, sel, fee: 47)    N takes 3, forwards with fee: 44
N -> Z: dhtForward(cid, sel, fee: 44)    Z keeps 44 as the content payment
Z -> N -> B -> A: blocks([...])          Success — B earns 3, N earns 3, Z earns 44
```

The fee is a **bid**: "I'll pay up to 50 ivy total for this content." Forwarders take their cuts. Z sees the remainder and decides whether to serve — if 44 doesn't cover Z's cost, Z rejects with `dontHave` and nobody pays. If it does, Z serves and keeps the remainder as pure revenue.

This creates a natural market: forwarders that charge less leave more for the content provider, making the request more likely to succeed. Requesters set fees based on urgency — higher fees for faster, more reliable paths. The fee also acts as a TTL: requests with small budgets die early if routing is expensive, preventing wasteful searches for rare content.

**Relay fee setting**: Each peer sets its own relay fee locally — a static amount, or dynamic based on current load, available bandwidth, or relationship with the neighbor. The protocol does not prescribe a fee-setting strategy. The market converges: peers that charge too much lose traffic to cheaper competitors; peers that charge too little lose money.

**All responses are success for fee purposes** — including empty results (e.g., `findPins` returning no pinners, `findNode` returning a partial neighbor list). The responding peer provided a service by checking its state and returning a result. Only timeouts and `feeExhausted` are failures where nobody pays. This prevents free-riding on queries for nonexistent content.

**Fee discovery**: When a request fails because the fee is exhausted, the failing hop returns `feeExhausted(consumed: X)` — the total fee consumed before the request died. The requester learns the minimum routing cost and retries with a calibrated fee. Failed attempts cost nothing (pay-on-success), so fee discovery is a free round trip. For repeat requests to the same keyspace region, the requester caches successful fees as a starting bid.

**How `findNode` works:** To locate a peer T in the network, A sends `findNode(T.hash, fee)` through connected neighbors. The request relays through the DHT — each hop forwards to its closest known peer toward T, and the response (a list of peers near T) bubbles back:

```
A -> B: findNode(T.hash, fee: 10)     B takes 2, forwards with fee: 8
B -> E: findNode(T.hash, fee: 8)      E takes 2, responds (closest to T it knows)
E -> B: neighbors([T, F, G])          Success — fees locked in
B -> A: neighbors([T, F, G])          B earns 2, E earns 2 + 4 remainder
```

For `findNode` and `findPins`, the destination peer (the one that responds) keeps the remainder — same model as `dhtForward`. This incentivizes peers near the target to maintain accurate routing tables.

A sends through multiple neighbors in parallel for speed and redundancy. After each round, A merges the results — newly discovered peers can be connected to and queried in the next round, converging closer to T. This is a hybrid of recursive relay (each query chains through the DHT) and iterative control (A drives multiple rounds, cross-referencing results).

**Convergence**: At each hop, the forwarder selects its closest known peer toward the target. By the Kademlia bucket structure, this peer shares at least one more prefix bit with the target — common prefix length (CPL) increases by at least 1 per hop. O(log n) bits of CPL are needed to reach the target's neighborhood, so O(log n) hops per chain suffice. This is the same greedy-progress guarantee as standard Kademlia — the relay model chains the same steps that the iterative model parallelizes.

Latency is slightly higher per round (sequential hops vs. direct contact), but parallel chains and the small size of control messages keep the total lookup time well under a second for typical networks. The tradeoff is that A only needs credit lines with its direct neighbors, never with remote peers.

### 5.2 Retrieval Flow

Retrieval is two phases: **discover** pinners, then **fetch** toward the pinner. Both use the same per-hop charging.

**Discover:** The retriever queries the DHT neighborhood of the CID hash for pin announcements:

```
A -> B -> N: findPins(cid, fee: 10)
N -> B -> A: pins([{pinner: Z, selector: "/", publicKey: ...}])
```

**Fetch:** The retriever sends a `dhtForward` with a `target` field set to Z's hash. The DHT routes toward Z using standard Kademlia greedy forwarding — the same routing that `findNode` uses, but carrying the data request as payload:

```
A -> B -> N -> Z: dhtForward(cid, selector, target: Z.hash, fee: 50)
Z: resolves selector against local DAG
Z -> N -> B -> A: blocks(cid, [matching blocks])     Each hop caches and charges
A: verify each block's CID
```

Every hop routes toward Z through existing peer connections — no new credit lines needed. A only pays B. Payment cascades through the chain. If the fee is exhausted before reaching Z (bad routing), `feeExhausted(consumed: X)` returns and A can do an explicit `findNode(Z.hash)` to improve its routing table before retrying.

### 5.3 Caching and Retrieval Incentives

Every peer that relays a block has the data in hand. If it caches the block, subsequent requests for the same CID are served locally — the cacher is now the destination and keeps the entire remaining fee (no downstream hops). **Caching is automatically profitable** — a forwarder that caches converts from earning a small relay fee to earning the full content payment.

This creates a self-optimizing content distribution network: popular content migrates toward well-connected peers because caching it earns money. Rarely accessed content stays at the edges, stored by pinners who earn storage fees. No central coordination is needed — the cache topology emerges from individual profit-maximizing decisions.

Forwarders are also incentivized to relay even content they don't cache. A peer well-positioned between a requester and a provider can forward at a margin — accepting at rate R_c upstream and paying R_p downstream. Pricing emerges from competition: peers that charge less attract more traffic.

**Latency optimization is emergent.** When a forwarder caches content and publishes a `pinAnnounce`, it becomes discoverable as a pinner for future `findPins` queries — closer to local requesters than the original distant pinner. Each round of requests pushes the effective pinner closer to the demand:

1. First request fetches from a distant pinner. Each relay hop caches.
2. A caching hop publishes a pin announcement for what it cached.
3. Future `findPins` queries return the nearby cacher alongside the original pinner.
4. Requesters select the closest pinner (fewest estimated hops, cheapest fee) — naturally preferring the nearby cache.

The same applies to relayers: requesters track which neighbors deliver results fastest and route future requests through them. Slow relayers lose traffic to faster competitors. No protocol mechanism needed — the requester's local experience is the routing optimizer.

No latency field or tier system is needed. The speed preference emerges from caching (creates nearby copies), pin announcements (makes them discoverable), and client-side selection (pick the closest pinner and the fastest neighbor). Popular content converges toward requesters automatically, and fast infrastructure attracts traffic naturally.

### 5.4 Direct Connect for Large Transfers

When the requested content exceeds a size threshold, relaying the full payload back through the DHT chain wastes intermediary bandwidth. Instead, the provider offers a **direct connect** with an N-backup for evidence:

```
A -> B -> N -> Z: dhtForward(cid, sel, target: Z, fee: 50)   B takes 3 (fee:47), N takes 3 (fee:44)
Z -> N:           block(cid, data)                          Backup: N verifies CID ✓, holds copy
Z -> N -> B -> A: directOffer(cid, endpoint, size, timeout) Relayed back through chain
A -> Z:           [direct TCP connection]             A dials Z (or hole punch)
Z -> A:           block(cid, data)                    Data flows directly
A -> B -> N:      deliveryAck                         A confirms receipt, triggers payment
N:                discards backup
```

Z sends the data to both A (directly) and N (Z's direct neighbor in the chain). N verifies the CID on the backup and holds it until the `timeout` specified in the `directOffer`. A confirms receipt by sending `deliveryAck` back through the chain, which triggers the payment cascade: B earns 3, N earns 3, Z earns 44.

**If A doesn't ack** (claims non-delivery or disconnects): N holds verified data. After a timeout, N relays the backup through the remaining chain to A. This relay is observable by every hop — standard pay-on-relay. A receives the data and pays. A cannot avoid payment because the relay is the same mechanism as normal DHT forwarding.

**If Z sends garbage to A but valid data to N**: A doesn't ack. N relays valid data through the chain. A receives correct data, pays. No harm — A got the right data through the backup path.

**If Z sends garbage to both A and N**: N verifies CID on the backup — hash doesn't match. N rejects. No relay, no payment. Z earned nothing.

**Z's dominant strategy**: Always send the backup to N. Without it, Z can't get paid if A disputes — N has nothing to relay and the request times out with no payment.

**Hole punching**: The DHT path between A and Z doubles as a signaling channel for NAT traversal. Both the request (A -> Z) and the offer (Z -> A) traverse through connected peers, giving both sides the other's observed address. If both peers are behind NAT, A and Z coordinate a simultaneous TCP open using the DHT path for timing signals. No additional infrastructure is needed.

**Cost**: Z sends the data twice — to A (direct) and to N (one hop). For a chain of 4 hops, this is 2 copies instead of 4. Still a net bandwidth savings over full relay.

**Fallback**: If direct connection fails (symmetric NATs, firewall), N already has the data and relays through the chain as normal. The direct connect attempt cost nothing extra — N's backup was the fallback all along.

### 5.5 Direct Peer Messaging

Connected peers can exchange arbitrary application messages outside the DHT economic layer. A `peerMessage(topic, payload)` between two directly connected peers is free — no fee, no DHT routing, no forwarding. It uses the existing TCP connection and credit line relationship.

This provides a base messaging primitive for applications built on Ivy:

- **Blockchain block gossip**: Peers propagate new blocks to connected neighbors. Each peer decides locally whether to relay to its own neighbors — standard gossip protocol over the Ivy connection graph.
- **Transaction propagation**: Same gossip pattern for unconfirmed transactions.
- **Application-level signaling**: Coordination between peers for any purpose (contract negotiation, presence, custom protocols).

Peer messages are not economically charged because they don't consume DHT routing resources — they travel one hop between directly connected peers. Abuse is bounded by the existing credit line relationship: a peer that floods its neighbor with messages can be rate-limited or disconnected. The trust relationship is the throttle.

### 5.6 Failure Handling

If a forwarder receives `dontHave` or the fee budget is exhausted, no balance adjustment occurs — the requester only pays for successful delivery. Content is self-authenticating (the CID is the hash of the data), so forwarders cannot deliver garbage. If corrupt data is received, the requester disputes via reconciliation (Section 6.2) with cryptographically provable evidence of the CID mismatch.

Forwarders should rate-limit neighbors with high failure rates. A neighbor whose requests fail 80%+ is likely spamming or misconfigured — throttling is a local decision that bounds the bandwidth cost of failed requests.

If a relay peer disconnects while an in-flight request is in transit, the request times out. Nobody pays (no response was relayed). The requester retries through a different neighbor.

---

## 6. Trust System

### 6.1 Bilateral Credit Lines

Trust in Ivy is **local and bilateral** — there is no global trust score. Each peer maintains its own view of every peer it has interacted with. Reputation is a local computation, not a protocol mechanism — each peer derives it from its own interaction history (successful deliveries, settlement track record, response latency). The credit line is the primary trust signal; reputation is how each peer weighs local decisions like bucket eviction, announcement prioritization, and neighbor selection.

Every relationship is a **credit line** with a net balance. Services rendered in either direction adjust the balance — if both peers serve each other, the balance oscillates near zero and settlement is rarely needed. If one peer primarily serves the other, the balance drifts and settlement is triggered when the imbalance exceeds the threshold.

```
Peer A <----[net balance: +12 ivy favoring A]----> Peer B
             threshold: 50 ivy
```

The threshold starts small and grows as the relationship matures:

```
initialThreshold = baseTrust(otherPeer) * baseThresholdMultiplier
currentThreshold = initialThreshold * (1 + log2(successfulSettlements + 1))
```

This logarithmic growth ensures trust builds gradually and plateaus. With `baseThresholdMultiplier = 100 ivy`, a zero-difficulty peer starts with a threshold of ~1 ivy (enough for several control-message queries), while a Medium-difficulty peer (16 trailing zeros) starts at ~50 ivy (enough for dozens of block retrievals). These values are configurable per node.

### 6.2 Balance Reconciliation

Both peers independently track the running balance using a sequence-numbered log of operations. Either peer can send `balanceCheck(sequence, balance)` at any time to verify alignment. If the counterparty's sequence or balance differs:

1. The peer with the lower sequence sends `balanceLog(fromSequence, operations)` — the list of operations the other peer is missing. The receiver replays them and confirms.
2. If both peers have operations the other is missing (concurrent operations during a network hiccup), both exchange logs and replay to convergence.
3. If a specific operation is disputed (e.g., a delivery that one side claims didn't happen), the disputing party provides evidence. CID mismatches are cryptographically provable — the peer with stronger evidence prevails. Unresolvable disputes reduce both parties' trust thresholds.

### 6.3 Settlement via Mining

When a balance exceeds the trust threshold, the debtor must settle. Ivy's primary settlement mechanism is **proof-of-work** — the debtor performs computational work equivalent to the debt, and the creditor accepts the proof as debt discharge.

**No settlement needed for net providers.** A peer that provides more service than it consumes is always a creditor — its balances are positive, it never exceeds a threshold, and settlement never triggers. Such a peer spends its earned credit on future requests, paying for consumption with prior service. No blockchain, no mining, no tokens. This is the common case for storage providers, active forwarders, and balanced participants. Settlement only triggers for net consumers — peers that consistently use more than they contribute.

**Base case (no blockchain needed):** When settlement is needed, the debtor proves it expended work equal to the outstanding debt. Both parties agreed (in the credit line terms) that PoW is acceptable settlement. The creditor receives proof of work — the debt is cleared because the debtor paid a real cost (energy, hardware time). This works without any blockchain. It is debt discharge through demonstrated effort, analogous to community service settling a fine.

**Mining optimization (when a compatible chain exists):** If the creditor runs a mining node, the PoW work doubles as block mining. The creditor constructs a block template with its own reward address; the debtor hashes against it. Any block discovered produces real tokens for the creditor — turning settlement from a pure cost into productive work. The protocol is chain-agnostic: any PoW chain works. Merged mining across multiple chains amplifies the lottery — a single hash is checked against all chains simultaneously, making block discovery probable during typical settlements.

**How it works:**

1. The creditor issues a **mining challenge** — a block template for the creditor's chosen chain, with B's reward address in the coinbase:

```
B -> A: miningChallenge(hashPrefix, blockTargetDifficulty, noncePrefix)
```

The `noncePrefix` occupies the first bytes of the extra-nonce field, binding the work to B's template. A cannot reuse solutions for a different creditor or construct a competing block with A's own reward address.

2. The debtor mines. Any solution meeting any chain's difficulty is submitted:

```
A -> B: miningChallengeSolution(nonce, hash, blockNonce)
```

3. If the hash satisfies any chain's difficulty, B assembles and submits the block. The block reward goes to B — real, fungible value.

4. Sub-chain-difficulty work still proves computation expended. B accepts this as partial settlement.

**Challenge freshness**: If the chain tip changes, B re-issues the challenge. A discards stale work. The creditor must remain online and chain-aware during settlement mining — constructing block templates requires a node for the chosen chain (or access to one). Peers that cannot run a chain node accept only direct token transfer (Section 6.4) for settlement.

**The lottery economics:**

With merged mining across N chains, the probability of producing a block per hash is:

```
P(any block) ≈ Σ(1 / 2^difficulty_i)
```

With chains at accessible difficulty (e.g., 2^20), a typical settlement of 100 ivy (~6 million hashes) has a ~99.8% chance of producing at least one real block. The more chains the creditor mines, the better the odds.

**Settlement accounting:** Each solution's work value is `2^(trailingZeroBits(hash) - 16) ivy`. When cumulative work equals or exceeds the debt, it is settled. Block reward surplus is credited to the debtor. Settlement credit is based on work proved, not on block finality — if a discovered block is later orphaned, the debtor's settlement credit is unaffected (the work was real regardless of the block's fate).

**The cost of debt**: Mining rewards go to the creditor during settlement. Had the debtor not been in debt, it could have mined independently and kept those rewards. This creates a strong incentive to settle quickly or maintain balanced credit lines.

**Multiple creditors**: If a debtor exceeds the threshold with multiple creditors simultaneously, the debtor settles with whichever creditor demands first, or splits mining effort across creditors. This is a local scheduling decision — the protocol does not prescribe an order.

### 6.4 On-Chain Settlement

For immediate finality, the debtor can send tokens on any blockchain directly to the creditor:

```
A -> B: settlementProof(txHash, amount, chainId)
B: verifies tx on chain, credits A's balance
```

The two peers agree on which chain and token to use. This is bilateral negotiation — part of the credit line relationship, not a protocol-level decision.

### 6.5 Trust Decay and Recovery

- **Missed settlement**: Credit limit halved immediately. Two consecutive misses reduce it to zero.
- **Timeout**: If unreachable for longer than the contract duration, the trust relationship is suspended. Debt is remembered.
- **Recovery**: A peer that settles outstanding debts can rebuild trust, but from the reduced level — trust is easier to lose than to gain.

---

## 7. Pinning

### 7.1 Pinning Contracts

Pinning contracts ensure data **persistence** — a peer commits to storing content and making it available for retrieval over a defined period. A pinning contract specifies: pinner, client, CIDs, duration, replication factor, and rate (ivy per byte per day).

**Negotiation**: The client negotiates with its direct neighbors — no connection to a stranger is needed. The client sends contract terms via `peerMessage(topic: "pinContract", payload: terms)` to a neighbor. The neighbor can **accept** (becoming the pinner, with an existing credit line) or **broker** (forwarding the offer to its own neighbors, taking a margin). The brokerage chain mirrors DHT forwarding — each hop decides locally whether to pin or forward.

**Data transfer**: The client does not push data to the pinner. The client publishes a `pinAnnounce` making the data discoverable, and the pinner **pulls** the data using the normal retrieval protocol (`findPins` + `dhtForward`). The retrieval cost is small and is factored into the pinning rate. No large data transfer over a new credit line — the data flows through the DHT like any other retrieval.

**Payment**: The client pays its direct neighbor (the broker or the pinner). If brokered, each hop takes a margin — the same pattern as forwarding fees. The pinning payment accrues on the bilateral credit line, settled via the same mechanisms as any other debt.

Peers may also **voluntarily** pin content — because it is close in XOR distance, because they expect retrieval revenue, or for altruistic reasons. Voluntary pins require no contract negotiation — the peer simply stores the data and publishes a pin announcement.

### 7.2 Pin Announcements

When a peer pins content, it publishes a pin announcement into the DHT (Section 4.1) including the root CID and the selector describing which subset of the DAG it holds. The pinner can be anywhere in the keyspace — the announcement is routed to and stored by the k-closest peers to the CID hash (not the pinner's hash). Like all DHT operations, publishing an announcement carries a fee — forwarders take relay cuts and the storing peer keeps the remainder as payment for holding the announcement.

Pinners refresh announcements by re-publishing before expiry, paying the announcement fee each time. Long-lived pins pay more in announcement fees — proportional to the storage resources they consume at the DHT peers.

**Spam resistance** operates at two levels. First, each announcement costs a fee — flooding thousands of fake announcements costs thousands of fees, paid through credit lines bounded by the attacker's key difficulty and trust thresholds. Second, DHT peers near the CID hash decide which announcements to keep, prioritizing announcements from higher-key-difficulty and higher-reputation peers. Expired entries are evicted first, then lowest-priority entries when storage is full. A Sybil attacker with many Medium-difficulty keys must pay per-announcement fees AND compete against High-difficulty legitimate pinners for storage slots.

### 7.3 Proof of Retrievability

Pinning contracts are verified through the existing retrieval protocol. The client (or any auditor) periodically retrieves random subsets of pinned content via `get(cid, selector)` and verifies the returned blocks against their CIDs. If retrieval succeeds, the pinner has the data. If it fails, the pinner is penalized and the contract may be voided.

This requires no new protocol — the storage guarantee IS the retrieval protocol. Content is self-authenticating (CID = hash of data), so the pinner cannot fake a successful retrieval. The audit cost is one retrieval fee per check, and the frequency is tunable per contract. Since pin announcements are public, any peer can audit any pinner — not just the client.

---

## 8. Network Architecture

```
+-----------------------------------------------------------+
|  Application Layer                                        |
|  CAS Interface: get(cid, selector), save(cid, data)      |
+-----------------------------------------------------------+
|  Economic Layer                                           |
|  Credit Lines, Settlement, Fee Bids                       |
|  Unit of Account: work-denominated credits (ivy)          |
+-----------------------------------------------------------+
|  Routing Layer                                            |
|  Kademlia DHT, Peer Exchange, NAT Traversal               |
+-----------------------------------------------------------+
|  Transport Layer                                          |
|  TCP + NIO, STUN, Binary Message Protocol                 |
+-----------------------------------------------------------+
```

### 8.1 End-to-End: Storing Data

An application wants to persist a structured object — for example, a directory containing files. The CAS layer encodes this as a DAG (directed acyclic graph) of content-addressed blocks, where each block's CID is the hash of its contents and blocks reference each other by CID.

```
Directory (root CID: Qm-root)
├── metadata.json  (CID: Qm-meta)
├── photo-a.jpg    (CID: Qm-a)
│   ├── chunk-0    (CID: Qm-a0)
│   └── chunk-1    (CID: Qm-a1)
└── photo-b.jpg    (CID: Qm-b)
    └── chunk-0    (CID: Qm-b0)
```

**Step 1 — Build the DAG locally.** The application chunks data into blocks, computes CIDs bottom-up (leaves first, then parents that reference child CIDs), and stores each block in the local verified distance store. The root CID (`Qm-root`) is the handle for the entire structure.

**Step 2 — Announce availability.** The node publishes a `pinAnnounce(Qm-root, selector: "/", ...)` to the k-closest peers to `Qm-root`'s hash in the DHT. The selector `"/"` indicates this node holds the complete DAG. A peer that holds only a subset (e.g., it cached `photo-a.jpg` from a prior retrieval) would announce with a narrower selector.

**Step 3 — Replicate (optional).** If the application requests `pin: PinOptions(replication: 3)`, the node negotiates pinning contracts with its neighbors via `peerMessage`. Neighbors accept or broker the contract to their own neighbors. Each contracted pinner then **pulls** the data using the normal retrieval protocol — the client's pin announcement (Step 2) makes the data discoverable. Each pinner publishes their own pin announcement with the selector covering what they received.

The total on-network cost: one pin announcement per pinner (small DHT operation), plus the data transfer to each pinner (charged via credit lines). No blockchain interaction.

### 8.2 End-to-End: Retrieving a Subset

An application wants a specific file from the directory above — `photo-a.jpg` — using a selector: `get(Qm-root, "/photo-a.jpg")`.

**Step 1 — Discover pinners.** A queries the DHT neighborhood of `Qm-root`'s hash for pin announcements. Peers near the hash store the announcements (not the data). A discovers:

- Peer C (somewhere in the network) announced `pinAnnounce(Qm-root, "/", ...)` — C has the full DAG.
- Peer D (elsewhere) announced `pinAnnounce(Qm-root, "/photo-b.jpg", ...)` — D has only photo-b.

C's selector covers A's request. D's doesn't. A targets C.

**Step 2 — Fetch with selector.** A sends a `dhtForward` targeted at C:

```
A -> B -> N -> C: dhtForward(Qm-root, selector: "/photo-a.jpg", target: C.hash, fee: 50)
```

The DHT routes toward C through existing connections. C resolves the selector against its local store, traversing root → photo-a.jpg manifest → chunk-0, chunk-1:

```
C -> N -> B -> A: blocks(Qm-root, [Qm-a, Qm-a0, Qm-a1])    N and B cache
```

A verifies every block's CID. `Qm-meta`, `Qm-b`, and `Qm-b0` were never transferred.

**Total cost:** 1 discovery (findPins) + 1 fetch (dhtForward + blocks). Payment cascades through the fetch path: A pays B, B pays N, N pays C. A never establishes a credit line with C.

**What the caching did:** B and N cached all the blocks as they relayed. If N publishes a `pinAnnounce(Qm-root, "/photo-a.jpg", ...)` to the DHT, future retrievers can discover N as a closer pinner — fewer hops, cheaper. Caching forwarders become partial pinners organically.

**Multi-peer coverage:** If no single pinner covers the full selector, A sends parallel targeted requests toward each pinner. Each returns its portion, A assembles locally.

**Direct connect (large results):** If the matching blocks are large, C sends a `directOffer` instead of relaying through the DHT. A connects directly to C for the data payload, but payment still cascades through the credit line chain (A -> B -> N -> C) as described in Section 5.4.

### 8.3 Use Case: Blockchain Data Backbone

Ivy can serve as the unified data layer for a PoW blockchain, replacing the separate P2P networking, block storage, and chain sync infrastructure that traditional blockchains maintain independently. The direct peer messaging layer (Section 5.5) provides gossip; the CAS provides block storage and retrieval; and settlement mining produces the chain's blocks.

**Block structure as a DAG.** Each blockchain block is stored as a content-addressed DAG:

```
Block 47 (CID: Q47)
├── header  (CID: Q47-h)  — prev: Q46, merkle root, timestamp, nonce
├── state   (CID: Q47-s)  — account balances, contract state
└── txns    (CID: Q47-t)  — list of included transactions
```

**Transaction propagation.** Users submit transactions to connected peers via `peerMessage(topic: "mempool", payload: signedTx)`. Each peer validates and gossips to its own neighbors. No fees — peer messages between direct peers are free. The Ivy connection graph is the gossip substrate.

**Block production via settlement.** When a validator's credit line with a peer exceeds the threshold, the creditor issues a mining challenge. The validator selects transactions from its mempool, constructs a block, and mines against the challenge. If the validator finds a valid nonce, three things happen at once: the debt is settled, the creditor receives the block reward, and the blockchain advances by one block. **Settlement mining IS block production.**

**Block propagation.** The block producer gossips the new block's CID and header to direct peers via `peerMessage(topic: "newBlock", ...)`. Each peer validates the header, fetches the full block through a paid `dhtForward`, validates the transactions and state, and gossips to its own peers. The block producer earns retrieval fees from every peer that fetches the block data. **Gossip is free; data is paid.**

**Voluntary pinning.** Every full node that syncs the chain already has the block data. Publishing a pin announcement costs a negligible DHT operation. Serving retrievals earns fees. Full nodes voluntarily pin because they already have the data and it's profitable to announce it. The more nodes that sync, the more pinners exist, the cheaper and faster sync becomes for the next node. **Syncing the chain creates the infrastructure for future syncs.**

**Light client queries.** A light client that doesn't store the full chain can query specific state (e.g., an account balance) using a selector against the latest block's state root:

```
get(Q47, "/state/accounts/myAddress")
```

The serving peer resolves the selector against its local state trie and returns only the Merkle path from the state root to the requested account — a few KB instead of the full state. The light client verifies the Merkle proof against the block header's state root. A cryptographically verified state query for a few ivy.

**Chain sync.** A new full node fetches the chain history through Ivy's normal retrieval protocol — `findPins` + `dhtForward` for each block, batched in parallel. The sync cost (fees paid through credit lines) is settled by mining — which produces new blocks for the chain. The node earns back its sync investment by serving chain data to future sync requests.

**The symbiotic loop:**

```
Using Ivy (retrievals, sync, queries)
  → accumulates debt on credit lines
    → settlement via mining
      → produces new blocks for the chain
        → blocks stored and served via Ivy
          → earns retrieval fees
```

Storage usage drives mining demand. Mining produces blocks. Blocks are stored and served through Ivy. Serving earns fees. The blockchain's economic activity funds its own data infrastructure, and the data infrastructure's economic activity funds the blockchain's security.

---

## 9. Security

### 9.1 Threat Model

A computationally bounded adversary controls some fraction of network peers. The adversary can: generate identities (bounded by key difficulty cost), refuse to forward or serve (bounded by pay-on-success — earns nothing), lie about delivery (bounded by N-backup and CID verification), and flood pin announcements (bounded by per-announcement fee cost and reputation-weighted eviction).

The adversary cannot: forge CIDs (SHA256 collision resistance), break Curve25519 signatures, or observe direct connections it is not party to.

**Core security property**: Honest behavior is a Nash equilibrium when the credit line threshold is less than the expected future revenue from the relationship. If `threshold < expectedFutureRevenue(relationship)`, no single-deviation strategy (stealing, lying, free-riding) is profitable. The logarithmic growth / instant halving asymmetry ensures this holds after a small number of successful interactions — the relationship becomes more valuable to preserve than any single theft it enables.

### 9.2 Sybil Resistance

Key difficulty provides a base cost for identity creation. Combined with bilateral trust earned through reliable service, Sybil attack cost scales with both identity count and trust depth. A Medium-difficulty key (2^23 work) yields a small initial credit line — useful for participation but insufficient for meaningful theft. Generating thousands of Medium keys costs hours of computation, and each key must independently build trust before it can extract value.

### 9.3 Eclipse Attacks

Reputation-weighted bucket eviction makes it difficult for an attacker to surround a target node with malicious peers. Established high-reputation peers are preferred over newcomers in routing table slots.

### 9.4 Free-Riding

Peers that consume without contributing exhaust their credit lines. Without settlement, they can't make new requests — the system self-enforces participation. The maximum extractable value per identity is bounded by the credit line threshold, which is calibrated to be smaller than the cost of the identity (key difficulty + trust building time).

### 9.5 Content Integrity

Content is self-authenticating (CID = hash of data). Forwarders cannot deliver garbage — any mismatch is cryptographically provable. In DHT relay, every forwarding hop can verify the CID before relaying. In direct connect, N (Z's neighbor) verifies the backup copy. Colluding peers (e.g., Z and N fabricating data) are caught at the first honest hop that verifies the CID.

### 9.6 Direct Connect Honesty

The N-backup mechanism (Section 5.4) ensures direct connect is honest-incentive-compatible:

- **A withholds ack**: N relays verified backup through chain. A pays via observable relay.
- **A disconnects after receiving**: A loses trust relationship with B. Theft bounded by threshold.
- **Z sends garbage to A**: N has valid backup, relays correct data. A gets right data, pays.
- **Z sends garbage to everyone**: N rejects (CID mismatch). Nobody pays.
- **Z skips backup to N**: Z can't get paid if A disputes — self-defeating.
- **Z and N collude**: First honest relay hop verifies CID, rejects garbage.

### 9.7 Privacy

In the base protocol, forwarders see the CID, selector, and fee for every request they relay. This reveals what content is being requested and the requester's willingness to pay. This is comparable to IPFS, where routing-layer peers see all CID requests in the clear, and is acceptable for non-sensitive content.

For sensitive data, the trust line extension (Section 12) provides privacy via sealed envelopes — the CID, selector, and requester identity are encrypted for the destination only, with data flowing directly between requester and provider. The base protocol trades privacy for simplicity; the trust line extension adds privacy when needed.

---

## 10. Protocol Reference

### 10.1 Messages

All protocol messages and their fields:

| Message | Fields | Direction | Fee-charged |
|---------|--------|-----------|-------------|
| `findPins` | cid, fee | Relayed through DHT | Yes (on response relay) |
| `pins` | [{pinnerPublicKey, selector}] | Response | — |
| `findNode` | targetHash, fee | Relayed through DHT | Yes (on response relay) |
| `neighbors` | [PeerEndpoint] | Response | — |
| `dhtForward` | cid, selector, target?, fee | Relayed toward target (or CID hash) | Yes (on response relay) |
| `blocks` | cid, [Block] | Response | — |
| `dontHave` | cid | Response | — |
| `feeExhausted` | consumed | Response (on fee depletion) | — |
| `directOffer` | cid, endpoint, size, timeout | Relayed back through chain | No |
| `deliveryAck` | requestId | Relayed back through chain | No |
| `pinAnnounce` | rootCID, selector, publicKey, expiry, signature, fee | Relayed to CID neighborhood | Yes (on `pinStored` relay) |
| `pinStored` | rootCID | Response (from storing peer) | — |
| `miningChallenge` | hashPrefix, blockTargetDifficulty, noncePrefix | Direct (creditor → debtor) | No |
| `miningChallengeSolution` | nonce, hash, blockNonce? | Direct (debtor → creditor) | No |
| `settlementProof` | txHash, amount, chainId | Direct (debtor → creditor) | No |
| `balanceCheck` | sequence, balance | Direct (either peer) | No |
| `balanceLog` | fromSequence, [(sequence, amount, requestId)] | Direct (either peer) | No |
| `peerMessage` | topic, payload | Direct (either peer) | No |
| `identify` | publicKey, observedHost, observedPort, listenAddrs, signature | Direct (on connect) | No |
| `ping` | nonce | Direct (either peer) | No |
| `pong` | nonce | Direct (response to ping) | No |

The `target` field on `dhtForward` is optional. When present, each hop routes toward the target's hash instead of the CID's hash — used after `findPins` to route directly toward a known pinner.

### 10.2 Data Structures

**Credit Line** (per connected peer pair):

```
CreditLine {
    peerA:              publicKey
    peerB:              publicKey
    balance:            int64       // positive = A is owed, negative = B is owed
    sequence:           uint64      // incremented on every balance-mutating operation
    threshold:          uint64      // max abs(balance) before settlement required
    successfulSettlements: uint64   // count, used in threshold growth formula
}
```

Sequence numbers are per-credit-line, starting at 0 when the credit line is established. The peer proposing the balance change increments the sequence and includes it in the operation. Both peers track the same sequence independently.

**Pin Announcement** (stored at k-closest peers to CID hash):

```
PinAnnouncement {
    rootCID:            CID
    selector:           Selector    // Cashew selector describing held subset
    pinnerPublicKey:    publicKey
    expiry:             timestamp   // announcement is invalid after this time
    signature:          bytes       // pinner's signature over (rootCID, selector, expiry)
}
```

Pinners refresh announcements by re-publishing before expiry, paying the announcement fee each time. DHT peers evict expired announcements first, then lowest-priority (lowest key-difficulty × reputation) announcements when storage is full.

**PinOptions** (used in `save`):

```
PinOptions {
    replication:        uint        // number of remote pinners to negotiate with
    duration:           Duration    // how long pinners must store the data
    maxRate:            uint64      // maximum ivy per byte per day the client will pay
}
```

### 10.3 Credit Line Lifecycle

1. **Establish**: When two peers connect, a credit line is created with `balance: 0`, `sequence: 0`, `threshold: baseTrust(otherPeer) * baseThresholdMultiplier`.
2. **Operate**: Each fee-charged operation (response relay, deliveryAck) increments the sequence and adjusts the balance. Both peers track independently.
3. **Reconcile**: Either peer can send `balanceCheck(sequence, balance)` at any time. If views diverge, both exchange operation logs since the last agreed sequence and replay.
4. **Settle**: When `abs(balance) >= threshold`, the creditor stops serving until the debtor settles. Settlement is initiated by the creditor sending `miningChallenge` or by the debtor sending `settlementProof`. The two peers agree on settlement method (PoW or token transfer) at connection time or during the first settlement request.
5. **Grow**: After successful settlement, `successfulSettlements` increments and `threshold` increases per the logarithmic formula.
6. **Decay**: Missed settlement halves the threshold. Two misses reduce to zero. Unreachable peers are suspended; debt is remembered.
7. **Dormant**: If a peer disconnects, the credit line is frozen. If the peer reconnects, it resumes from the last known state.

### 10.4 Protocol Limits

| Limit | Value | Purpose |
|-------|-------|---------|
| Max frame size | 4 MB | Bounds memory per message |
| Max block payload | 4 MB | Bounds single block size |
| Max blocks per response | 4096 | Bounds selector resolution response |
| Max string field | 8 KB | Bounds CID, selector, topic lengths |
| Max pin announcements per CID | 256 | Bounds storage at announcement holders |
| Max neighbors per response | 256 | Bounds findNode/findPins responses |

Multi-block responses from selector resolution (`blocks` message) are bounded by the max blocks per response limit. If a selector matches more blocks than the limit, the provider returns a partial result and the requester issues follow-up requests for the remainder.

### 10.5 Peer Health

Peers detect neighbor liveness via `ping(nonce)` / `pong(nonce)` keepalives. A peer that fails to respond to multiple consecutive pings is considered unreachable — its credit line is frozen (Section 10.3, step 7) and it may be removed from the routing table. The keepalive interval and failure threshold are configurable per node.

Disconnection is detected by TCP connection close or keepalive failure. No explicit disconnect message is needed — the credit line freezes on connection loss and resumes if the peer reconnects.

### 10.6 Forwarding Decision

All DHT-routed messages (`findPins`, `findNode`, `dhtForward`, `pinAnnounce`) follow the same forwarding algorithm. When a peer receives a routed message:

1. **Check if locally handleable**:
   - `dhtForward`: peer has blocks matching the CID and selector → resolve and respond.
   - `findPins`: peer stores pin announcements for this CID → respond with stored announcements.
   - `findNode`: peer has no known peer closer to the target than itself → respond with closest known peers.
   - `pinAnnounce`: peer is in the CID's hash neighborhood → store the announcement and respond with `pinStored`.
2. **Check fee**: If the remaining fee is zero, return `feeExhausted(consumed)`.
3. **Deduct relay fee**: Subtract the peer's relay fee from the remaining fee.
4. **Route**: Forward to the closest known peer toward the routing target. For `dhtForward` with a `target` field, route toward `target.hash`. Otherwise, route toward the CID or target hash in the message.
5. **On response**: Relay the response upstream. The credit line with the upstream peer is adjusted by the relay fee.
6. **On failure**: Relay `dontHave` or `feeExhausted` upstream. No balance change.

---

## 11. Comparison with Related Work

| Property              | Ivy                          | IPFS/BitSwap | Filecoin    | Lightning     |
|-----------------------|------------------------------|--------------|-------------|---------------|
| Sybil resistance      | PoW keys + reputation        | Weak         | Staking     | Channel deposits |
| Settlement cost       | Amortized (credit + mining)  | None (free)  | Per-deal    | Per-channel   |
| Retrieval incentive   | Per-hop credit line margin   | Tit-for-tat  | Retrieval market | Payment routing |
| Storage guarantee     | Pinning contracts            | None         | PoSt proofs | N/A           |
| Trust model           | Bilateral credit lines       | None         | Global      | Bilateral     |
| Routing               | Kademlia DHT                 | Kademlia DHT | On-chain    | Gossip graph  |
| Unit of account       | Computational work           | None         | FIL token   | BTC           |
| Settlement mechanism  | Mining (any PoW chain)       | N/A          | On-chain    | Commitment txs |

---

## 12. Future Work

- **Trust lines**: For large data transfers, a trust-line protocol enables direct peer-to-peer connections between requester and provider, bypassing intermediary bandwidth. Trust lines route introductions through chains of bilateral credit lines using sealed envelopes for privacy, with data flowing directly between endpoints. This is an optimization for when DHT forwarding bandwidth becomes a bottleneck.
- **Reputation portability**: Signed attestations from trusted peers to bootstrap trust with new contacts.
- **Erasure coding**: Split large objects across multiple pinners for resilience without full replication.
- **Key rotation**: A migration protocol where existing trust partners co-sign a key rotation certificate.
- **Credit delegation**: A trusted peer temporarily extends its credit line to a new peer for faster onboarding.

---

## 13. Conclusion

Ivy demonstrates that a peer-to-peer storage network can be economically sustainable and low-latency by overlaying bilateral credit lines onto standard DHT routing. Work-denominated credits provide a universal unit of account grounded in physical reality. Credit lines amortize settlement costs across many transactions, with debtors settling by mining blocks for any compatible PoW blockchain — where every hash is a lottery ticket and merged mining makes productive settlement the norm.

When used as the data backbone for a PoW blockchain, Ivy creates a symbiotic loop: storage usage drives mining demand, mining produces blocks, blocks are stored and served through Ivy, and serving earns fees that offset future storage costs. The blockchain's economic activity funds its own data infrastructure, and the data infrastructure funds the blockchain's security. Gossip is free (peer messages), data is paid (fee-bid retrieval), and full nodes voluntarily pin chain data because it's profitable to serve.

The result is a system where every participant is incentivized to contribute, cheat resistance emerges from local economic relationships rather than global consensus, and the network's economic activity directly funds the security of whichever blockchains its participants choose to mine.
