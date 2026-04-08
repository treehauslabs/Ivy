import Testing
import Foundation
@testable import Ivy
import NIOCore

@Suite("STUN Response Parsing")
struct STUNParsingTests {

    @Test("Parse XOR-MAPPED-ADDRESS IPv4")
    func testXorMappedAddress() {
        var buf = buildSTUNResponse(attrType: 0x0020, xorMapped: true, ip: "203.0.113.5", port: 4001)
        let addr = STUNResponseHandler.parseResponse(&buf)
        #expect(addr != nil)
        #expect(addr?.host == "203.0.113.5")
        #expect(addr?.port == 4001)
    }

    @Test("Parse MAPPED-ADDRESS IPv4")
    func testMappedAddress() {
        var buf = buildSTUNResponse(attrType: 0x0001, xorMapped: false, ip: "192.168.1.1", port: 8080)
        let addr = STUNResponseHandler.parseResponse(&buf)
        #expect(addr != nil)
        #expect(addr?.host == "192.168.1.1")
        #expect(addr?.port == 8080)
    }

    @Test("Invalid magic cookie returns nil")
    func testBadMagic() {
        var buf = ByteBuffer()
        buf.writeInteger(UInt16(0x0101), endianness: .big)
        buf.writeInteger(UInt16(0), endianness: .big)
        buf.writeInteger(UInt32(0xDEADBEEF), endianness: .big)
        buf.writeRepeatingByte(0, count: 12)
        #expect(STUNResponseHandler.parseResponse(&buf) == nil)
    }

    @Test("Truncated response returns nil")
    func testTruncated() {
        var buf = ByteBuffer()
        buf.writeBytes([0x01, 0x01, 0x00])
        #expect(STUNResponseHandler.parseResponse(&buf) == nil)
    }

    private func buildSTUNResponse(attrType: UInt16, xorMapped: Bool, ip: String, port: UInt16) -> ByteBuffer {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        let ipNum = UInt32(parts[0]) << 24 | UInt32(parts[1]) << 16 | UInt32(parts[2]) << 8 | UInt32(parts[3])

        let magic: UInt32 = 0x2112A442

        let xPort: UInt16 = xorMapped ? (port ^ 0x2112) : port
        let xAddr: UInt32 = xorMapped ? (ipNum ^ magic) : ipNum

        var attrBuf = ByteBuffer()
        attrBuf.writeInteger(attrType, endianness: .big)
        attrBuf.writeInteger(UInt16(8), endianness: .big)
        attrBuf.writeInteger(UInt8(0))
        attrBuf.writeInteger(UInt8(0x01))
        attrBuf.writeInteger(xPort, endianness: .big)
        attrBuf.writeInteger(xAddr, endianness: .big)

        var buf = ByteBuffer()
        buf.writeInteger(UInt16(0x0101), endianness: .big)
        buf.writeInteger(UInt16(attrBuf.readableBytes), endianness: .big)
        buf.writeInteger(magic, endianness: .big)
        buf.writeRepeatingByte(0, count: 12)
        buf.writeBuffer(&attrBuf)

        return buf
    }
}

@Suite("ObservedAddress")
struct ObservedAddressTests {

    @Test("Equality")
    func testEquality() {
        let a = ObservedAddress(host: "1.2.3.4", port: 4001)
        let b = ObservedAddress(host: "1.2.3.4", port: 4001)
        let c = ObservedAddress(host: "1.2.3.4", port: 4002)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Hashing")
    func testHashing() {
        let a = ObservedAddress(host: "1.2.3.4", port: 4001)
        let b = ObservedAddress(host: "1.2.3.4", port: 4001)
        var set: Set<ObservedAddress> = [a]
        set.insert(b)
        #expect(set.count == 1)
    }
}

@Suite("PeerEndpoint Hashable")
struct PeerEndpointHashableTests {

    @Test("PeerEndpoint in Set")
    func testPeerEndpointSet() {
        let a = PeerEndpoint(publicKey: "k1", host: "1.2.3.4", port: 4001)
        let b = PeerEndpoint(publicKey: "k1", host: "1.2.3.4", port: 4001)
        var set: Set<PeerEndpoint> = [a]
        set.insert(b)
        #expect(set.count == 1)
    }
}
