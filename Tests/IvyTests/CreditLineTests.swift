import Testing
import Foundation
@testable import Ivy
@testable import Tally

@Suite("KeyDifficulty")
struct KeyDifficultyTests {

    @Test("Trailing zero bits computation")
    func testTrailingZeroBits() {
        let bits = KeyDifficulty.trailingZeroBits(of: "test-key")
        #expect(bits >= 0 && bits <= 256)
    }

    @Test("baseTrust returns 0 for low difficulty")
    func testBaseTrustLow() {
        let trust = KeyDifficulty.baseTrust(publicKey: "test-key", minDifficulty: 100, maxDifficulty: 200)
        #expect(trust == 0)
    }

    @Test("baseTrust returns 1.0 for maxDifficulty 0")
    func testBaseTrustMax() {
        let trust = KeyDifficulty.baseTrust(publicKey: "test-key", minDifficulty: 0, maxDifficulty: 1)
        // Any key with >= 1 trailing zero bit gets 1.0
        let bits = KeyDifficulty.trailingZeroBits(of: "test-key")
        if bits >= 1 {
            #expect(trust == 1.0)
        } else {
            #expect(trust == 0.0)
        }
    }

    @Test("baseTrust is monotonic with difficulty")
    func testBaseTrustMonotonic() {
        // Generate many keys and verify higher difficulty → higher baseTrust
        var results: [(String, Int, Double)] = []
        for i in 0..<100 {
            let key = "key-\(i)"
            let bits = KeyDifficulty.trailingZeroBits(of: key)
            let trust = KeyDifficulty.baseTrust(publicKey: key, minDifficulty: 0, maxDifficulty: 32)
            results.append((key, bits, trust))
        }
        let sorted = results.sorted { $0.1 < $1.1 }
        for i in 1..<sorted.count {
            #expect(sorted[i].2 >= sorted[i-1].2)
        }
    }
}

@Suite("CreditLine")
struct CreditLineTests {

    let peerA = PeerID(publicKey: "peer-a")
    let peerB = PeerID(publicKey: "peer-b")

    @Test("New credit line starts at zero balance")
    func testNewCreditLine() {
        let line = CreditLine(peerA: peerA, peerB: peerB, threshold: 50)
        #expect(line.balance == 0)
        #expect(line.sequence == 0)
        #expect(line.threshold == 50)
        #expect(line.successfulSettlements == 0)
        #expect(!line.needsSettlement)
    }

    @Test("Balance adjusts correctly")
    func testBalanceAdjustment() {
        var line = CreditLine(peerA: peerA, peerB: peerB, threshold: 50)
        line.adjustBalance(by: -10)
        #expect(line.balance == -10)
        #expect(line.sequence == 1)

        line.adjustBalance(by: 25)
        #expect(line.balance == 15)
        #expect(line.sequence == 2)
    }

    @Test("Settlement triggers when threshold exceeded")
    func testSettlementTrigger() {
        var line = CreditLine(peerA: peerA, peerB: peerB, threshold: 50)
        line.adjustBalance(by: -49)
        #expect(!line.needsSettlement)

        line.adjustBalance(by: -2)
        #expect(line.needsSettlement)
    }

    @Test("Settlement clears balance and grows threshold")
    func testSettlement() {
        var line = CreditLine(peerA: peerA, peerB: peerB, threshold: 50)
        line.adjustBalance(by: -60)
        #expect(line.needsSettlement)

        line.recordSettlement()
        #expect(line.balance == 0)
        #expect(line.successfulSettlements == 1)
        #expect(line.threshold >= 50)
    }

    @Test("Partial settlement reduces balance")
    func testPartialSettlement() {
        var line = CreditLine(peerA: peerA, peerB: peerB, threshold: 50)
        line.adjustBalance(by: -60)

        line.recordPartialSettlement(workValue: 30)
        #expect(line.balance == -30)
    }

    @Test("Missed settlement halves threshold")
    func testMissedSettlement() {
        var line = CreditLine(peerA: peerA, peerB: peerB, threshold: 100)
        line.recordMissedSettlement()
        #expect(line.threshold == 50)

        line.recordMissedSettlement()
        #expect(line.threshold == 25)
    }

    @Test("Available capacity decreases with balance")
    func testAvailableCapacity() {
        var line = CreditLine(peerA: peerA, peerB: peerB, threshold: 100)
        #expect(line.availableCapacity == 100)

        line.adjustBalance(by: -30)
        #expect(line.availableCapacity == 70)

        line.adjustBalance(by: -70)
        #expect(line.availableCapacity == 0)
    }

    @Test("initialThreshold from baseTrust")
    func testInitialThreshold() {
        let threshold = CreditLine.initialThreshold(baseTrust: 0.5, multiplier: 100)
        #expect(threshold == 50)

        let zero = CreditLine.initialThreshold(baseTrust: 0.0, multiplier: 100)
        #expect(zero == 0)

        let full = CreditLine.initialThreshold(baseTrust: 1.0, multiplier: 100)
        #expect(full == 100)
    }
}

@Suite("CreditLineLedger")
struct CreditLineLedgerTests {

    @Test("Establish credit line on connect")
    func testEstablish() async {
        let local = PeerID(publicKey: "local-peer")
        let remote = PeerID(publicKey: "remote-peer")
        let ledger = CreditLineLedger(localID: local)

        let line = await ledger.establish(with: remote)
        #expect(line.balance == 0)
        #expect(line.threshold >= 1)
    }

    @Test("Charge and earn adjust balance")
    func testChargeAndEarn() async {
        let local = PeerID(publicKey: "local-peer")
        let remote = PeerID(publicKey: "remote-peer")
        let ledger = CreditLineLedger(localID: local)

        _ = await ledger.establish(with: remote)
        let charged = await ledger.chargeForRelay(peer: remote, amount: 5)
        #expect(charged)

        let balance = await ledger.balance(with: remote)
        #expect(balance == -5)

        await ledger.earnFromRelay(peer: remote, amount: 3)
        let newBalance = await ledger.balance(with: remote)
        #expect(newBalance == -2)
    }

    @Test("Settlement clears debt")
    func testSettlement() async {
        let local = PeerID(publicKey: "local-peer")
        let remote = PeerID(publicKey: "remote-peer")
        let ledger = CreditLineLedger(localID: local, baseThresholdMultiplier: 10)

        _ = await ledger.establish(with: remote)
        _ = await ledger.chargeForRelay(peer: remote, amount: 15)

        let needs = await ledger.needsSettlement(peer: remote)
        #expect(needs)

        await ledger.recordSettlement(peer: remote)
        let balance = await ledger.balance(with: remote)
        #expect(balance == 0)
    }
}

@Suite("Economic Message Serialization")
struct EconomicMessageTests {

    @Test("findPins roundtrip")
    func testFindPinsRoundtrip() {
        let msg = Message.findPins(cid: "QmRoot123", fee: 100)
        let decoded = Message.deserialize(msg.serialize())
        if case .findPins(let cid, let fee) = decoded {
            #expect(cid == "QmRoot123")
            #expect(fee == 100)
        } else {
            Issue.record("Expected findPins")
        }
    }

    @Test("pins roundtrip")
    func testPinsRoundtrip() {
        let msg = Message.pins(announcements: [
            (publicKey: "pk1", selector: "/"),
            (publicKey: "pk2", selector: "/photos")
        ])
        let decoded = Message.deserialize(msg.serialize())
        if case .pins(let announcements) = decoded {
            #expect(announcements.count == 2)
            #expect(announcements[0].publicKey == "pk1")
            #expect(announcements[0].selector == "/")
            #expect(announcements[1].selector == "/photos")
        } else {
            Issue.record("Expected pins")
        }
    }

    @Test("pinAnnounce roundtrip")
    func testPinAnnounceRoundtrip() {
        let sig = Data([1, 2, 3, 4])
        let msg = Message.pinAnnounce(rootCID: "QmRoot", selector: "/", publicKey: "myKey", expiry: 999999, signature: sig, fee: 50)
        let decoded = Message.deserialize(msg.serialize())
        if case .pinAnnounce(let root, let sel, let pk, let exp, let s, let fee) = decoded {
            #expect(root == "QmRoot")
            #expect(sel == "/")
            #expect(pk == "myKey")
            #expect(exp == 999999)
            #expect(s == sig)
            #expect(fee == 50)
        } else {
            Issue.record("Expected pinAnnounce")
        }
    }

    @Test("pinStored roundtrip")
    func testPinStoredRoundtrip() {
        let msg = Message.pinStored(rootCID: "QmStored")
        let decoded = Message.deserialize(msg.serialize())
        if case .pinStored(let root) = decoded {
            #expect(root == "QmStored")
        } else {
            Issue.record("Expected pinStored")
        }
    }

    @Test("feeExhausted roundtrip")
    func testFeeExhaustedRoundtrip() {
        let msg = Message.feeExhausted(consumed: 42)
        let decoded = Message.deserialize(msg.serialize())
        if case .feeExhausted(let consumed) = decoded {
            #expect(consumed == 42)
        } else {
            Issue.record("Expected feeExhausted")
        }
    }

    @Test("directOffer roundtrip")
    func testDirectOfferRoundtrip() {
        let msg = Message.directOffer(cid: "QmBig", host: "1.2.3.4", port: 4001, size: 1_000_000, timeout: 30)
        let decoded = Message.deserialize(msg.serialize())
        if case .directOffer(let cid, let host, let port, let size, let timeout) = decoded {
            #expect(cid == "QmBig")
            #expect(host == "1.2.3.4")
            #expect(port == 4001)
            #expect(size == 1_000_000)
            #expect(timeout == 30)
        } else {
            Issue.record("Expected directOffer")
        }
    }

    @Test("deliveryAck roundtrip")
    func testDeliveryAckRoundtrip() {
        let msg = Message.deliveryAck(requestId: 12345)
        let decoded = Message.deserialize(msg.serialize())
        if case .deliveryAck(let rid) = decoded {
            #expect(rid == 12345)
        } else {
            Issue.record("Expected deliveryAck")
        }
    }

    @Test("balanceCheck roundtrip")
    func testBalanceCheckRoundtrip() {
        let msg = Message.balanceCheck(sequence: 97, balance: -42)
        let decoded = Message.deserialize(msg.serialize())
        if case .balanceCheck(let seq, let bal) = decoded {
            #expect(seq == 97)
            #expect(bal == -42)
        } else {
            Issue.record("Expected balanceCheck")
        }
    }

    @Test("balanceLog roundtrip")
    func testBalanceLogRoundtrip() {
        let msg = Message.balanceLog(fromSequence: 10, operations: [
            (sequence: 11, amount: -5, requestId: 100),
            (sequence: 12, amount: 3, requestId: 101)
        ])
        let decoded = Message.deserialize(msg.serialize())
        if case .balanceLog(let from, let ops) = decoded {
            #expect(from == 10)
            #expect(ops.count == 2)
            #expect(ops[0].amount == -5)
            #expect(ops[1].amount == 3)
        } else {
            Issue.record("Expected balanceLog")
        }
    }

    @Test("peerMessage roundtrip")
    func testPeerMessageRoundtrip() {
        let payload = Data("hello world".utf8)
        let msg = Message.peerMessage(topic: "mempool", payload: payload)
        let decoded = Message.deserialize(msg.serialize())
        if case .peerMessage(let topic, let p) = decoded {
            #expect(topic == "mempool")
            #expect(p == payload)
        } else {
            Issue.record("Expected peerMessage")
        }
    }

    @Test("dhtForward with fee and target roundtrip")
    func testDhtForwardWithFeeRoundtrip() {
        let target = Data([0xAB, 0xCD])
        let msg = Message.dhtForward(cid: "QmTest", ttl: 7, fee: 50, target: target, selector: "/photos")
        let decoded = Message.deserialize(msg.serialize())
        if case .dhtForward(let cid, let ttl, let fee, let t, let sel) = decoded {
            #expect(cid == "QmTest")
            #expect(ttl == 7)
            #expect(fee == 50)
            #expect(t == target)
            #expect(sel == "/photos")
        } else {
            Issue.record("Expected dhtForward with fee and target")
        }
    }

    @Test("dhtForward backward compatible (no fee/target)")
    func testDhtForwardBackwardCompat() {
        let msg = Message.dhtForward(cid: "QmOld", ttl: 3)
        let decoded = Message.deserialize(msg.serialize())
        if case .dhtForward(let cid, let ttl, let fee, let target, let sel) = decoded {
            #expect(cid == "QmOld")
            #expect(ttl == 3)
            #expect(fee == 0)
            #expect(target == nil)
            #expect(sel == nil)
        } else {
            Issue.record("Expected dhtForward")
        }
    }
}
