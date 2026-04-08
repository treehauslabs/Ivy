import Foundation
import Tally

public struct CreditLine: Sendable {
    public let peerA: PeerID
    public let peerB: PeerID
    public private(set) var balance: Int64
    public private(set) var sequence: UInt64
    public private(set) var threshold: UInt64
    public private(set) var successfulSettlements: UInt64

    public init(peerA: PeerID, peerB: PeerID, threshold: UInt64) {
        self.peerA = peerA
        self.peerB = peerB
        self.balance = 0
        self.sequence = 0
        self.threshold = threshold
        self.successfulSettlements = 0
    }

    public static func initialThreshold(baseTrust: Double, multiplier: UInt64 = 100) -> UInt64 {
        UInt64(baseTrust * Double(multiplier))
    }

    public var needsSettlement: Bool {
        UInt64(abs(balance)) >= threshold
    }

    public var availableCapacity: Int64 {
        Int64(threshold) - abs(balance)
    }

    public mutating func adjustBalance(by amount: Int64) {
        balance += amount
        sequence += 1
    }

    public mutating func recordSettlement() {
        balance = 0
        successfulSettlements += 1
        let initial = threshold / UInt64(1 + log2(Double(successfulSettlements)))
        threshold = initial * UInt64(1 + log2(Double(successfulSettlements + 1)))
    }

    public mutating func recordPartialSettlement(workValue: Int64) {
        if balance > 0 {
            balance = max(0, balance - workValue)
        } else {
            balance = min(0, balance + workValue)
        }
        sequence += 1
    }

    public mutating func recordMissedSettlement() {
        threshold = threshold / 2
    }

    public mutating func freeze() -> CreditLine {
        self
    }
}
