import Testing
import Foundation
@testable import Ivy
import Tally

@Suite("BoundedSet")
struct BoundedSetTests {

    @Test("Respects capacity")
    func testCapacity() {
        var set = BoundedSet<Int>(capacity: 10)
        for i in 0..<20 {
            set.insert(i)
        }
        #expect(set.count <= 10)
    }

    @Test("Contains works after eviction")
    func testContainsAfterEviction() {
        var set = BoundedSet<Int>(capacity: 5)
        for i in 0..<5 { set.insert(i) }
        #expect(set.contains(4))
        for i in 5..<10 { set.insert(i) }
        #expect(set.contains(9))
        #expect(set.count <= 5)
    }

    @Test("Duplicate insert returns false")
    func testDuplicateInsert() {
        var set = BoundedSet<String>(capacity: 10)
        let first = set.insert("hello")
        let second = set.insert("hello")
        #expect(first == true)
        #expect(second == false)
        #expect(set.count == 1)
    }

    @Test("Empty set")
    func testEmpty() {
        let set = BoundedSet<Int>(capacity: 100)
        #expect(set.isEmpty)
        #expect(set.count == 0)
    }

    @Test("RemoveAll clears")
    func testRemoveAll() {
        var set = BoundedSet<Int>(capacity: 10)
        for i in 0..<5 { set.insert(i) }
        set.removeAll()
        #expect(set.isEmpty)
    }

    @Test("Eviction removes oldest entries")
    func testEvictsOldest() {
        var set = BoundedSet<Int>(capacity: 4)
        set.insert(1)
        set.insert(2)
        set.insert(3)
        set.insert(4)
        set.insert(5)
        #expect(set.contains(5))
        #expect(!set.contains(1))
    }
}

@Suite("BoundedDictionary")
struct BoundedDictionaryTests {

    @Test("Respects capacity")
    func testCapacity() {
        var dict = BoundedDictionary<Int, String>(capacity: 5)
        for i in 0..<10 {
            dict[i] = "value-\(i)"
        }
        #expect(dict.count <= 5)
    }

    @Test("Get and set")
    func testGetSet() {
        var dict = BoundedDictionary<String, Int>(capacity: 10)
        dict["a"] = 1
        dict["b"] = 2
        #expect(dict["a"] == 1)
        #expect(dict["b"] == 2)
        #expect(dict["c"] == nil)
    }

    @Test("Update existing key doesn't count as new")
    func testUpdateExisting() {
        var dict = BoundedDictionary<String, Int>(capacity: 3)
        dict["a"] = 1
        dict["b"] = 2
        dict["c"] = 3
        dict["a"] = 100
        #expect(dict.count == 3)
        #expect(dict["a"] == 100)
    }

    @Test("Remove value")
    func testRemoveValue() {
        var dict = BoundedDictionary<String, Int>(capacity: 10)
        dict["a"] = 1
        let removed = dict.removeValue(forKey: "a")
        #expect(removed == 1)
        #expect(dict["a"] == nil)
    }

    @Test("Set to nil removes")
    func testSetNilRemoves() {
        var dict = BoundedDictionary<String, Int>(capacity: 10)
        dict["a"] = 1
        dict["a"] = nil
        #expect(dict["a"] == nil)
        #expect(dict.count == 0)
    }

    @Test("RemoveAll where predicate")
    func testRemoveAllWhere() {
        var dict = BoundedDictionary<Int, Int>(capacity: 100)
        for i in 0..<10 { dict[i] = i }
        dict.removeAll { key, _ in key % 2 == 0 }
        #expect(dict.count == 5)
        #expect(dict[1] == 1)
        #expect(dict[0] == nil)
    }

    @Test("Max function works")
    func testMax() {
        var dict = BoundedDictionary<String, Int>(capacity: 10)
        dict["a"] = 1
        dict["b"] = 5
        dict["c"] = 3
        let best = dict.max(by: { $0.value < $1.value })
        #expect(best?.key == "b")
        #expect(best?.value == 5)
    }
}

@Suite("Message Validation")
struct MessageValidationTests {

    @Test("Oversized string rejected")
    func testOversizedString() {
        var buf = Data()
        buf.appendUInt8(2)
        let longString = String(repeating: "x", count: Int(MessageLimits.maxStringLength) + 1)
        let bytes = Data(longString.utf8)
        buf.appendUInt16(UInt16(bytes.count))
        buf.append(bytes)
        let msg = Message.deserialize(buf)
        #expect(msg == nil)
    }

    @Test("Neighbors count capped")
    func testNeighborsCountCapped() {
        var buf = Data()
        buf.appendUInt8(6)
        buf.appendUInt16(UInt16(MessageLimits.maxNeighborCount) + 1)
        let msg = Message.deserialize(buf)
        #expect(msg == nil)
    }

    @Test("Valid neighbors within limit passes")
    func testValidNeighborsPass() {
        let peers = (0..<3).map { PeerEndpoint(publicKey: "k\($0)", host: "1.2.3.4", port: UInt16($0 + 1000)) }
        let msg = Message.neighbors(peers)
        let decoded = Message.deserialize(msg.serialize())
        if case .neighbors(let p) = decoded {
            #expect(p.count == 3)
        } else {
            Issue.record("Expected neighbors")
        }
    }

    @Test("HolepunchConnect addrs capped")
    func testHolepunchAddrsCapped() {
        var buf = Data()
        buf.appendUInt8(14)
        buf.appendUInt16(UInt16(MessageLimits.maxHolepunchAddrs) + 1)
        let msg = Message.deserialize(buf)
        #expect(msg == nil)
    }

    @Test("CompactBlock txCIDs capped")
    func testCompactBlockCapped() {
        var buf = Data()
        buf.appendUInt8(22)
        buf.appendUInt32(16)
        buf.append(Data(repeating: 0, count: 16))
        let hcid = Data("h".utf8)
        buf.appendUInt16(UInt16(hcid.count))
        buf.append(hcid)
        buf.appendUInt16(UInt16(MessageLimits.maxTxCIDCount) + 1)
        let msg = Message.deserialize(buf)
        #expect(msg == nil)
    }

    @Test("Frame size limit enforced")
    func testFrameSizeLimit() {
        #expect(MessageLimits.maxFrameSize == 4 * 1024 * 1024)
        #expect(MessageLimits.maxFrameSize < 64 * 1024 * 1024)
    }
}

@Suite("PeerHealthMonitor")
struct PeerHealthMonitorTests {

    @Test("Track and check peer")
    func testTrackPeer() async {
        let tally = Tally(config: .default)
        let monitor = PeerHealthMonitor(
            config: PeerHealthConfig(keepaliveInterval: .seconds(10), staleTimeout: .seconds(30)),
            tally: tally,
            onStale: { _ in }
        )

        let peer = PeerID(publicKey: "monitor-test-peer")
        await monitor.trackPeer(peer)

        let isStale = await monitor.isStale(peer)
        #expect(!isStale)
    }

    @Test("Untracked peer is stale")
    func testUntrackedIsStale() async {
        let tally = Tally(config: .default)
        let monitor = PeerHealthMonitor(
            config: .default,
            tally: tally,
            onStale: { _ in }
        )

        let peer = PeerID(publicKey: "unknown-peer")
        let isStale = await monitor.isStale(peer)
        #expect(isStale)
    }

    @Test("Record activity refreshes timestamp")
    func testRecordActivity() async {
        let tally = Tally(config: .default)
        let monitor = PeerHealthMonitor(
            config: .default,
            tally: tally,
            onStale: { _ in }
        )

        let peer = PeerID(publicKey: "active-peer")
        await monitor.trackPeer(peer)
        await monitor.recordActivity(from: peer)

        let isStale = await monitor.isStale(peer)
        #expect(!isStale)
    }

    @Test("Remove peer")
    func testRemovePeer() async {
        let tally = Tally(config: .default)
        let monitor = PeerHealthMonitor(
            config: .default,
            tally: tally,
            onStale: { _ in }
        )

        let peer = PeerID(publicKey: "removable-peer")
        await monitor.trackPeer(peer)
        await monitor.removePeer(peer)

        let count = await monitor.trackedPeerCount
        #expect(count == 0)
    }

    @Test("Tracked peer count")
    func testTrackedCount() async {
        let tally = Tally(config: .default)
        let monitor = PeerHealthMonitor(
            config: .default,
            tally: tally,
            onStale: { _ in }
        )

        for i in 0..<5 {
            await monitor.trackPeer(PeerID(publicKey: "p-\(i)"))
        }
        let count = await monitor.trackedPeerCount
        #expect(count == 5)
    }
}

@Suite("IvyLogger")
struct IvyLoggerTests {

    @Test("NullLogger does not crash")
    func testNullLogger() {
        let logger = NullLogger()
        logger.debug("test")
        logger.info("test")
        logger.warning("test")
        logger.error("test")
    }

    @Test("LogLevel ordering")
    func testLogLevelOrdering() {
        #expect(IvyLogLevel.debug < IvyLogLevel.info)
        #expect(IvyLogLevel.info < IvyLogLevel.warning)
        #expect(IvyLogLevel.warning < IvyLogLevel.error)
    }
}
