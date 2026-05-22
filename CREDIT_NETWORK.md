# Lattice Credit Network
## Peer-to-Peer Service Credit Lines with On-Chain Settlement

**Draft v0.2**

---

## Abstract

Nodes in the Lattice network exchange verifiable services: content retrieval, DHT operations, block relay, and data pinning. Settling each micro-operation on-chain is economically incoherent — the transaction cost exceeds the service value. This paper describes a bilateral credit line protocol that allows two nodes to accumulate a net service balance and settle periodically in a single on-chain Lattice transaction.

The central thesis is that **trust is a resource that compounds**. Nodes that behave reliably earn larger credit extensions from more peers. Over time the network self-organizes into tiers — not by governance or appointment, but as a natural consequence of the trust mechanics. The bilateral layer is the floor of last resort. An emergent tier of high-trust coordinator nodes forms the fast routing layer on top. No single entity controls either layer. The system is fully decentralized.

This paper builds on the existing CreditLine and CreditLineLedger infrastructure already implemented in Tally, and integrates with the existing `relayFee` configuration in Ivy. It is honest about what is ready to build now and what is not.

---

## 1. What Already Exists

Before proposing anything, it is worth being precise about the current state.

**Built and working:**
- `CreditLine` struct — balance, threshold, sequence counter, settlement history, `needsSettlement`, `debtPressure`, `availableCapacity`
- `CreditLineLedger` actor — `establish`, `chargeForRelay`, `earnFromRelay`, `recordSettlement`, `recordMissedSettlement`, `recordPartialSettlement`
- `relayFee: UInt64 = 0` in `IvyConfig` — the price hook exists, defaults to free
- `baseThresholdMultiplier: UInt64 = 100` — threshold calibrated by key difficulty via `KeyDifficulty.baseTrust`
- `hasCreditCapacity(peer:)` in Ivy — blocks serving when debt exceeds threshold
- `settleWithCreditors` call site in `LatticeNode+Mining.swift` — called after every mined block

**Deliberately disabled:**
- `settleWithCreditors` body is empty: *"Settlement disabled — Ivy ledger API not available in current Ivy version"*
- `relayFee` defaults to 0, making all relay free and credit lines inert

**Not built:**
- Signed checkpoints (mutually-agreed balance proofs)
- Settlement message protocol
- On-chain settlement transaction construction
- Multi-hop routing

The gap is not design — the Ivy whitepaper covers the P2P mechanics in detail. The gap is the settlement layer that converts accumulated balances into on-chain transactions.

---

## 2. The Credit Line Mechanism

Every pair of connected nodes maintains a `CreditLine`. Services rendered adjust the running balance:

```
chargeForRelay(peer, amount)   // I consumed a service from peer
earnFromRelay(peer, amount)    // peer consumed a service from me
```

The balance is the net position. Positive: peer owes me. Negative: I owe peer.

When `|balance| >= threshold`, the debtor settles. The threshold starts small (calibrated to the peer's key difficulty) and grows logarithmically with successful settlements:

```
threshold = initialThreshold × (1 + log₂(successfulSettlements + 1))
```

This is the compounding property of trust. A long-standing peer with a history of reliable settlement earns a larger credit extension. Trust builds gradually and is easier to lose than to gain — a missed settlement halves the threshold immediately.

`debtPressure` provides graduated throttling before the hard cutoff. A peer approaching its limit receives progressively less bandwidth, not a sudden stop.

**No changes are needed to this layer.** It is correct as designed.

---

## 3. The Unit of Account

Bilateral balances require a common denomination. Two options exist.

**Option A — Work-denominated units (ivy)**

As described in the Ivy whitepaper: 1 ivy = 2^16 expected SHA256 evaluations. The unit is anchored to physical computation, universally verifiable without a price oracle, and compatible with mining-as-settlement.

Advantages: stable in service terms, no token required to participate, new nodes can settle by mining.

Disadvantages: requires defining and communicating a new unit, more complex for users to reason about.

**Option B — Lattice tokens**

Use the chain's native token directly. `relayFee` is already denominated in token units.

Advantages: simpler, integrates naturally with on-chain settlement, no new unit to explain.

Disadvantages: price volatility changes the meaning of credit limits in service terms. A credit limit that covers 100MB of data today may cover 10MB or 1000MB tomorrow depending on token price and miner fee-setting. New nodes with no token balance cannot settle debts until they earn tokens through mining or receive a faucet allocation.

**This paper does not resolve this choice.** It is a protocol-level commitment with real consequences. The work-denominated model solves the bootstrap problem more cleanly; the token model is simpler to implement. The decision should be made explicitly before Phase 1 implementation begins.

---

## 4. Settlement: What Needs to Be Built

Settlement is the missing piece. The `CreditLineLedger` tracks balances locally but has no mechanism for two peers to agree on the balance or for one to pay the other.

### 4.1 The Agreement Problem

If Node A thinks B owes it 85 tokens and Node B thinks it owes 82 tokens, who is right? Both maintain their balances locally. Without a reconciliation mechanism, settlement cannot proceed.

**Signed checkpoints** resolve this. Periodically — every N operations or T seconds — one peer proposes a signed balance:

```
BalanceCheckpoint {
    balance:    Int64     // positive = remote owes local
    sequence:   UInt64    // must match remote's view
    timestamp:  Int64
    signature:  Data      // signed by proposer's key
}
```

The remote peer verifies the balance matches its local ledger and countersigns. Both parties now hold a mutually-agreed proof at that sequence number.

If sequences diverge, both exchange operation logs since the last agreed checkpoint and replay to convergence. The last mutually-signed checkpoint is the recoverable amount if the peer disappears.

The existing `sequence` counter in `CreditLine` is already the right foundation for this.

### 4.2 Settlement Protocol

When `needsSettlement` is true, the debtor initiates:

1. **Propose** — debtor sends a signed `SettlementProposal` referencing the last mutually-signed checkpoint
2. **Countersign** — creditor verifies balance, adds its signature
3. **Submit** — debtor sends an on-chain Lattice transaction paying the net amount to the creditor's address

The on-chain transaction is a standard `AccountAction`:

```
AccountAction(owner: debtorAddress,   delta: -settlementAmount)
AccountAction(owner: creditorAddress, delta: +settlementAmount)
```

A `generalAction` records the settlement nonce to prevent replay.

### 4.3 Settlement Chain

Settlement can happen on any chain both parties agree to at connection time. Default is the Nexus chain. A `CreditOffer` message exchanged at connection establishment includes a `settlementChain: String` field. High-volume node pairs can negotiate settlement on a faster or cheaper child chain.

### 4.4 New Messages Required

Three additions to the Ivy message protocol, all implementable over the existing `peerMessage` topic mechanism:

| Message | Direction | Purpose |
|---------|-----------|---------|
| `creditOffer` | At connect, both directions | Exchange max credit, settlement chain |
| `balanceCheckpoint` | Either peer, periodic | Signed balance proof |
| `settlementProposal` | Debtor → creditor | Initiate on-chain settlement |

No changes to the wire protocol format. These are new topics on the existing `peerMessage` channel.

### 4.5 Default Enforcement

There is no way to force on-chain settlement. The only weapons are:
- Stop serving the peer (`hasCreditCapacity` already implements this)
- Reduce future credit (`recordMissedSettlement` halves threshold)
- Reputation loss in Tally

**This is a real limitation.** The maximum extractable value per identity is bounded by the credit threshold, calibrated to key difficulty. For the system to be self-sustaining, defaulting must be unprofitable: the one-time gain from defaulting must be less than the expected future revenue from the relationship.

With `minPeerKeyBits = 24`, generating an identity costs ~2^24 SHA256 operations (~1 minute). If `base_credit` is large relative to the cost of generating a new identity, Sybil attacks are profitable. Either `minPeerKeyBits` must be high, `base_credit` must be low, or collateral is required for credit lines above a minimum. This parameter must be tuned before enabling credit on mainnet.

---

## 5. Trust as a Resource That Compounds

The most important thing to understand about this system is not the mechanics — it is what the mechanics produce.

Every node starts with a credit line calibrated to its key difficulty. As it builds a history of reliable service and settlement, thresholds grow. Peers extend more credit because the node has proven it is reliable. The node can now serve more traffic, earn more fees, and extend credit to its own peers. Trust compounds.

Over time the network self-organizes into a natural hierarchy — not because anyone designed it that way, but because trust flows toward nodes that have demonstrated reliability at scale.

```
Small node A ──┐
Small node B ──┤──► Coordinator X ──┬──► Coordinator Z ──► Small node F
Small node C ──┘                    └──► Coordinator Y ──► Small node G
Small node D ──┬──► Coordinator Y ──┘
Small node E ──┘
```

**Coordinators are not appointed.** They emerge because they have earned large credit lines from many peers through a history of reliable service and settlement. Any node can become a coordinator. No permission required.

### 5.1 This Is Not Centralization

Centralization means a single entity controls the system. What emerges here is **stratification** — nodes self-organize into tiers based on trust and capability. The key properties that keep it decentralized:

- Any node can become a coordinator by earning trust with many peers
- Any node can route through any coordinator it has a trust line with
- Any node can bypass coordinators and use direct bilateral settlement
- No coordinator can prevent two nodes from establishing a direct trust line
- A coordinator that behaves badly loses its trust lines and its coordinator status

The topology resembles the internet's backbone/ISP/end-node hierarchy, or the financial system's central bank/commercial bank/consumer hierarchy. Neither of those is centralized. They are hierarchical by trust and capability, not by control.

The bilateral settlement layer is the **floor of last resort**. Every node can always transact directly with every peer it is connected to, regardless of whether any coordinator exists. Coordinators are a **performance optimization**, not a dependency.

### 5.2 The Meaningful Question

The right question is not "is there hierarchy?" — there will always be hierarchy in any efficient network. The right question is **"can the hierarchy be captured?"**

- Can one coordinator block all payments? No — others exist and new ones can form
- Can coordinators collude to exclude a node? Only if the node cannot find any coordinator willing to route — at which point it falls back to direct bilateral settlement
- Can a single entity shut down the whole system? No — the bilateral layer works without any coordinators

The answer to all three is no. The system is decentralized.

### 5.3 Analogy to Existing Systems

This pattern is not novel — it is how every efficient trust network operates:

- **Banking**: Central banks → commercial banks → consumers. Nobody appointed JPMorgan as a hub; it became one by earning the trust of millions of counterparties over time.
- **Internet routing**: Backbone providers → ISPs → end nodes. Tier 1 providers are not appointed; they emerged because their networks became reliable enough that everyone else wanted to peer with them.
- **Lightning Network**: Large hubs emerged not because anyone chose them, but because they maintained liquidity and uptime. Nodes route through them because they work.

The difference here: in those systems, becoming a hub requires capital (liquidity, infrastructure). In the Lattice credit network, the primary requirement is *demonstrated reliability over time*. Capital (collateral, token balance) matters less than behavior.

---

## 6. Multi-Hop Routing

With coordinators established, routing payments between nodes with no direct relationship becomes practical.

A wants to pay C for a service. A has a trust line with coordinator X. C has a trust line with coordinator X. The payment routes A → X → C:

```
A draws down credit line with X
X draws down credit line with C
C delivers service to A
```

X earns a routing fee for intermediating. A pays slightly more than the raw service cost. C receives the net fee.

**What keeps X honest?** X's credit lines with both A and C. If X fails to route correctly:
- A records a missed settlement with X → X's threshold halves
- C records a failed payment from X → C's threshold for X shrinks
- X loses its reputation as a reliable coordinator

The economic cost of misbehavior is proportional to X's coordinator status. A coordinator with many large trust lines has the most to lose from a single failure. This is why coordinators are incentivized to be reliable — their credit capacity is their business.

### 6.1 Atomicity: The Known Problem

The routing above has no atomic lock. If X pays C but A refuses to pay X, X is exposed. This is the same problem Lightning solved with HTLCs.

**The pragmatic response**: atomicity matters less when:
1. The amounts are small relative to the trust line threshold
2. Both A and X have a history of reliable settlement
3. Misbehavior is costly for A (threshold reduction, reputation loss)

For the coordinator tier — nodes with large trust lines and long settlement histories — this exposure is acceptable. A coordinator will not burn its relationship with X over the routing fee for one CAS fetch.

For large transfers between strangers, the exposure is real and atomicity would be required. That is Phase 3, and it requires protocol primitives that do not exist yet. Phase 2 covers the coordinator-mediated routing for the common case.

---

## 7. What This System Does Not Do

**It does not guarantee data delivery.** Credit lines pay for service attempts. CID mismatch is detectable via cashew self-authentication, but the credit adjustment for a failed delivery is a social convention, not a protocol enforcement.

**It does not provide payment privacy.** Relay nodes see fee bids on messages they forward. Spending patterns are visible to direct peers. This is comparable to IPFS.

**It does not solve the bootstrap token problem for token-denominated settlement.** New nodes have no tokens until they mine or receive an allocation. If `relayFee > 0`, they cannot settle debts. Either `relayFee = 0` by default (current state), faucets provide bootstrap tokens, or the work-denominated settlement model is used.

**It does not replace on-chain consensus for large one-off transfers.** Credit lines accumulate many micro-payments into one settlement. For large single transfers, direct on-chain payment is simpler and more reliable.

---

## 8. Implementation Phases

### Phase 1 — Bilateral settlement (ready to build)

1. **Signed checkpoints** — `BalanceCheckpoint` struct and exchange protocol. Self-contained. 2–3 days.
2. **Settlement protocol** — `CreditOffer`, `SettlementProposal` message types, on-chain transaction construction for Nexus settlement. 1–2 weeks.
3. **Testnet validation** — set `relayFee > 0` on testnet nodes, validate end-to-end.
4. **Unit of account decision** — work-denominated ivy vs. Lattice tokens. Must be made before Phase 1 ships.

### Phase 2 — Coordinator-mediated routing

Coordinator nodes emerge naturally from Phase 1 as high-trust nodes build large credit lines. Routing through coordinators is simply chaining two bilateral settlements. No new protocol required — just path-finding logic that identifies which connected coordinator has a trust line with the target node. Buildable once Phase 1 is stable.

### Phase 3 — Full atomic routing (not yet)

HTLC-equivalent atomicity for routing between untrusted parties. Requires smart contract capabilities or a dedicated settlement chain. Not currently buildable on Lattice. Long-term future work.

---

## 9. Relationship to Existing Documents

This paper supersedes the settlement-related sections of `P2P_ECONOMIC_MODEL.md` and provides the implementation roadmap missing from `WHITEPAPER.md`. The core DHT economics, per-hop charging model, and pinning contract design in `WHITEPAPER.md` remain correct and are not duplicated here.

The central addition is the **stratified trust network** framing — explaining why the coordinator tier is not a centralization compromise but the natural emergent structure of any compounding trust system, and why that structure is consistent with full decentralization.

---

## 10. Open Questions

1. **Unit of account**: Work-denominated ivy or Lattice tokens? See §3.
2. **Base credit calibration**: What is the right `base_credit` such that defaulting is unprofitable relative to key generation cost?
3. **Checkpoint frequency**: More frequent checkpoints reduce dispute exposure but add message overhead. What is the right interval?
4. **Coordinator incentives**: Should coordinators earn a protocol-level routing fee, or is it negotiated bilaterally? Bilateral negotiation is simpler and more flexible.
5. **Settlement chain for coordinators**: Should high-volume coordinator pairs settle on a fast child chain rather than Nexus? The `settlementChain` field in `CreditOffer` supports this, but the child chain infrastructure must exist.
