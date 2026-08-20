import XCTest
@testable import ThreadMap

final class IPv6PrefixTests: XCTestCase {

    func testMeshcopWireEncoding() throws {
        // One length byte, then only the significant prefix bytes.
        let prefix = try XCTUnwrap(
            IPv6Prefix(meshcopEncoded: Data([64, 0xFD, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]))
        )
        XCTAssertEqual(prefix.length, 64)
        XCTAssertTrue(prefix.contains(Fixture.address("fd11:2233:4455:6677::1")))
        XCTAssertFalse(prefix.contains(Fixture.address("fd11:2233:4455:6678::1")))
    }

    func testTruncatedWireEncodingIsRejected() {
        // Claims 64 bits but supplies four bytes.
        XCTAssertNil(IPv6Prefix(meshcopEncoded: Data([64, 0xFD, 0x11, 0x22, 0x33])))
        XCTAssertNil(IPv6Prefix(meshcopEncoded: Data()))
    }

    /// Prefix lengths that don't land on a byte boundary are where naive
    /// implementations quietly match too much.
    func testNonByteAlignedPrefix() throws {
        let prefix = try XCTUnwrap(IPv6Prefix(string: "fd11:2233:4455:6670::/60"))

        // Byte 7 is 0x77; masked with 0xF0 that's 0x70, which matches.
        XCTAssertTrue(prefix.contains(Fixture.address("fd11:2233:4455:6677::1")))
        // Byte 7 is 0x87; masked that's 0x80, which does not.
        XCTAssertFalse(prefix.contains(Fixture.address("fd11:2233:4455:6687::1")))
    }

    /// Every prefix length, not just the one that happened to be written
    /// first: the masking arithmetic is where an off-by-one or a type
    /// inference slip turns into a crash rather than a wrong answer.
    func testAllPrefixLengthsMaskWithoutTrapping() throws {
        let inside = Fixture.address("fd11:2233:4455:6677:8899:aabb:ccdd:eeff")
        for length in 0...128 {
            let prefix = try XCTUnwrap(
                IPv6Prefix(bytes: inside.bytes, length: length),
                "failed to build a /\(length) prefix"
            )
            XCTAssertTrue(prefix.contains(inside), "a prefix built from an address must contain it (/\(length))")
        }
    }

    /// Flipping the last bit inside the prefix must push an address out of it.
    func testPrefixExcludesAddressDifferingInsidePrefix() throws {
        let base = Fixture.address("fd11:2233:4455:6677::1")
        let prefix = try XCTUnwrap(IPv6Prefix(bytes: base.bytes, length: 60))

        // Byte 7 of the prefix is 0x70 once masked; 0x87 masks to 0x80.
        XCTAssertFalse(prefix.contains(Fixture.address("fd11:2233:4455:6687::1")))
        XCTAssertTrue(prefix.contains(Fixture.address("fd11:2233:4455:667f::9")))
    }

    func testIPv4NeverMatchesAnIPv6Prefix() throws {
        let prefix = try XCTUnwrap(IPv6Prefix(string: "fd11:2233:4455:6677::/64"))
        XCTAssertFalse(prefix.contains(Fixture.address("192.168.1.40")))
    }

    func testAddressClassification() {
        XCTAssertTrue(Fixture.address("fe80::1").isLinkLocal)
        XCTAssertFalse(Fixture.address("fe80::1").isRoutable)

        XCTAssertTrue(Fixture.address("fd11:2233::1").isUniqueLocal)
        XCTAssertTrue(Fixture.address("fd11:2233::1").isRoutable)

        XCTAssertTrue(Fixture.address("2001:db8::1").isGlobalUnicast)
        XCTAssertEqual(Fixture.address("192.168.1.40").family, .v4)
    }

    /// A scoped link-local address is common in mDNS replies and must still parse.
    func testZoneIdentifierIsTolerated() {
        XCTAssertNotNil(IPAddressParser.parse("fe80::1%en0"))
        XCTAssertEqual(IPAddressParser.parse("fe80::1%en0")?.family, .v6)
    }

    func testHostnamesAreNotAddresses() {
        XCTAssertNil(IPAddressParser.parse("apple-tv.local"))
    }
}
