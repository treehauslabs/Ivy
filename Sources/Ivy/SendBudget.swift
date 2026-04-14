import Foundation
import Tally

/// Bandwidth allocation that maximizes the node's self-interest.
///
/// Instead of fixed priority categories, bandwidth is allocated proportionally
/// to each peer's economic value: reputation score, credit line health, and
/// whether the message earns fees. High-value peers get more bandwidth;
/// freeloaders get throttled to the minimum.
///
/// Design principles (self-interested node):
/// 1. Fee-earning messages always go through — they directly pay us
/// 2. High-reputation peers get proportionally more bandwidth — they reciprocate
/// 3. Peers at credit limit get minimum bandwidth — they're not paying their way
/// 4. Keepalive/identity always go through — we need the connection alive to earn
actor SendBudget {
    private var peerWindows: [PeerID: PeerWindow] = [:]
    private let baseBytesPerSecond: Int
    private let interval: Duration

    struct PeerWindow {
        var bytesSent: Int
        var windowStart: ContinuousClock.Instant
        var budget: Int // computed from reputation each window
    }

    init(baseBytesPerSecond: Int, interval: Duration = .seconds(1)) {
        self.baseBytesPerSecond = baseBytesPerSecond
        self.interval = interval
    }

    /// Check whether we should send `bytes` to `peer`, given their economic value.
    /// - `earnsFee`: true if this message directly earns us relay fees — always allowed
    /// - `isKeepalive`: true for ping/pong/identify — always allowed (connection maintenance)
    /// - `reputationScore`: peer's Tally reputation (0.0 = untrusted, 1.0+ = excellent)
    /// - `atCreditLimit`: true if peer has exhausted their credit line
    func shouldSend(to peer: PeerID, bytes: Int, earnsFee: Bool, isKeepalive: Bool, reputationScore: Double, atCreditLimit: Bool) -> Bool {
        // Always send fee-earning messages — they pay us directly
        if earnsFee { return true }
        // Always send keepalive — we need connections alive to earn
        if isKeepalive { return true }

        let now = ContinuousClock.now
        var window = peerWindows[peer] ?? PeerWindow(bytesSent: 0, windowStart: now, budget: computeBudget(reputation: reputationScore, atCreditLimit: atCreditLimit))

        // Reset window if expired
        if now - window.windowStart >= interval {
            window.bytesSent = 0
            window.windowStart = now
            window.budget = computeBudget(reputation: reputationScore, atCreditLimit: atCreditLimit)
        }

        guard window.bytesSent + bytes <= window.budget else {
            peerWindows[peer] = window
            return false
        }

        window.bytesSent += bytes
        peerWindows[peer] = window
        return true
    }

    /// Compute per-peer budget from reputation.
    /// - Base: 10% of total for unknown peers (reputation ~0)
    /// - Linear scale: reputation 1.0 = 100% of base budget
    /// - Bonus: reputation >1.0 gets up to 200% (super-contributors)
    /// - Credit limit: peers at limit get only 5% (just enough for keepalive + small messages)
    private func computeBudget(reputation: Double, atCreditLimit: Bool) -> Int {
        if atCreditLimit {
            return max(baseBytesPerSecond / 20, 1024) // 5% floor, minimum 1KB
        }
        // Clamp reputation to [0, 2] range for budget calculation
        let clamped = min(max(reputation, 0.0), 2.0)
        // 10% base + 90% scaled by reputation (at rep=1.0, gets 100%)
        let fraction = 0.1 + 0.9 * min(clamped, 1.0)
        // Bonus for super-contributors: rep 1.0-2.0 adds up to 100% extra
        let bonus = max(clamped - 1.0, 0.0)
        let total = fraction + bonus
        return max(Int(Double(baseBytesPerSecond) * total), 1024)
    }

    func removePeer(_ peer: PeerID) {
        peerWindows.removeValue(forKey: peer)
    }

    func remaining(for peer: PeerID) -> Int {
        guard let window = peerWindows[peer] else { return baseBytesPerSecond }
        return max(window.budget - window.bytesSent, 0)
    }
}
