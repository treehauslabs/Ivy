import Foundation
import Tally

public actor CreditLineLedger {
    private var lines: [PeerID: CreditLine] = [:]
    private let localID: PeerID
    private let baseThresholdMultiplier: UInt64
    private let minDifficulty: Int
    private let maxDifficulty: Int

    public init(localID: PeerID, baseThresholdMultiplier: UInt64 = 100, minDifficulty: Int = 0, maxDifficulty: Int = 32) {
        self.localID = localID
        self.baseThresholdMultiplier = baseThresholdMultiplier
        self.minDifficulty = minDifficulty
        self.maxDifficulty = maxDifficulty
    }

    public func establish(with peer: PeerID) -> CreditLine {
        if let existing = lines[peer] { return existing }
        let trust = KeyDifficulty.baseTrust(publicKey: peer.publicKey, minDifficulty: minDifficulty, maxDifficulty: maxDifficulty)
        let threshold = CreditLine.initialThreshold(baseTrust: trust, multiplier: baseThresholdMultiplier)
        let line = CreditLine(peerA: localID, peerB: peer, threshold: max(threshold, 1))
        lines[peer] = line
        return line
    }

    public func creditLine(for peer: PeerID) -> CreditLine? {
        lines[peer]
    }

    public func chargeForRelay(peer: PeerID, amount: Int64) -> Bool {
        guard var line = lines[peer] else { return false }
        line.adjustBalance(by: -amount)
        lines[peer] = line
        return true
    }

    public func earnFromRelay(peer: PeerID, amount: Int64) {
        guard var line = lines[peer] else { return }
        line.adjustBalance(by: amount)
        lines[peer] = line
    }

    public func needsSettlement(peer: PeerID) -> Bool {
        lines[peer]?.needsSettlement ?? false
    }

    public func recordSettlement(peer: PeerID) {
        guard var line = lines[peer] else { return }
        line.recordSettlement()
        lines[peer] = line
    }

    public func recordPartialSettlement(peer: PeerID, workValue: Int64) {
        guard var line = lines[peer] else { return }
        line.recordPartialSettlement(workValue: workValue)
        lines[peer] = line
    }

    public func recordMissedSettlement(peer: PeerID) {
        guard var line = lines[peer] else { return }
        line.recordMissedSettlement()
        lines[peer] = line
    }

    public func removeLine(for peer: PeerID) -> CreditLine? {
        lines.removeValue(forKey: peer)
    }

    public var allLines: [PeerID: CreditLine] {
        lines
    }

    public func balance(with peer: PeerID) -> Int64 {
        lines[peer]?.balance ?? 0
    }

    public func threshold(for peer: PeerID) -> UInt64 {
        lines[peer]?.threshold ?? 0
    }
}
