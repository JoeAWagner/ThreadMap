import XCTest
@testable import ThreadMap

final class DNSMessageTests: XCTestCase {

    func testQueryEncoding() {
        let query = DNSMessage.query(name: "_hap._udp.local")
        let bytes = [UInt8](query)

        XCTAssertEqual(Array(bytes[0..<4]), [0x00, 0x00, 0x00, 0x00])  // ID + flags
        XCTAssertEqual(Array(bytes[4..<6]), [0x00, 0x01])              // one question
        XCTAssertEqual(Array(bytes[6..<12]), [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // 4 '_hap' 4 '_udp' 5 'local' 0, then QTYPE PTR and QCLASS IN.
        let expectedName: [UInt8] = [4] + Array("_hap".utf8) + [4] + Array("_udp".utf8)
            + [5] + Array("local".utf8) + [0]
        XCTAssertEqual(Array(bytes[12..<(12 + expectedName.count)]), expectedName)
        XCTAssertEqual(Array(bytes.suffix(4)), [0x00, 0x0C, 0x00, 0x01])
    }

    /// A realistic response: a PTR whose RDATA uses a compression pointer back
    /// into the answer's own name. Getting this wrong is how you end up with
    /// truncated instance names.
    func testParsesPTRWithCompressionPointer() throws {
        var message: [UInt8] = [
            0x00, 0x00,             // ID
            0x84, 0x00,             // response, authoritative
            0x00, 0x00,             // no questions
            0x00, 0x01,             // one answer
            0x00, 0x00, 0x00, 0x00  // no authority, no additional
        ]
        // Answer name starts at offset 12: _hap._udp.local
        message += [4] + Array("_hap".utf8) + [4] + Array("_udp".utf8) + [5] + Array("local".utf8) + [0]
        message += [0x00, 0x0C]                    // type PTR
        message += [0x00, 0x01]                    // class IN
        message += [0x00, 0x00, 0x00, 0x78]        // TTL
        let target: [UInt8] = [10] + Array("Front Door".utf8) + [0xC0, 0x0C]
        message += [0x00, UInt8(target.count)]     // RDLENGTH
        message += target

        let parsed = try XCTUnwrap(DNSMessage.parse(Data(message)))
        XCTAssertTrue(parsed.isResponse)
        XCTAssertEqual(parsed.records.count, 1)

        let record = try XCTUnwrap(parsed.records.first)
        XCTAssertEqual(record.nameLabels, ["_hap", "_udp", "local"])
        XCTAssertEqual(record.type, DNSMessage.typePTR)
        XCTAssertEqual(record.targetLabels, ["Front Door", "_hap", "_udp", "local"])

        // And the whole point: the instance name comes back out.
        XCTAssertEqual(parsed.instanceNames(forServiceTypes: ["_hap._udp"]), ["Front Door"])
    }

    /// Instance names legitimately contain dots ("Joe's Lamp v1.2"), so they
    /// must be taken as a whole label, never split on ".".
    func testInstanceNameContainingADot() throws {
        var message: [UInt8] = [0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        message += [4] + Array("_hap".utf8) + [4] + Array("_udp".utf8) + [5] + Array("local".utf8) + [0]
        message += [0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78]
        let name = "Lamp v1.2"
        let target: [UInt8] = [UInt8(name.utf8.count)] + Array(name.utf8) + [0xC0, 0x0C]
        message += [0x00, UInt8(target.count)] + target

        let parsed = try XCTUnwrap(DNSMessage.parse(Data(message)))
        XCTAssertEqual(parsed.instanceNames(forServiceTypes: ["_hap._udp"]), ["Lamp v1.2"])
    }

    /// A name that points at itself must terminate, not spin. This is the one
    /// place a malformed packet from an untrusted device could hang the app.
    func testSelfReferentialPointerTerminates() {
        let message: [UInt8] = [
            0x00, 0x00, 0x84, 0x00,
            0x00, 0x00,
            0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0xC0, 0x0C                  // name at offset 12 points to offset 12
        ]
        // The contract is that it returns rather than looping; an empty record
        // list is the correct outcome for an undecodable name.
        let parsed = DNSMessage.parse(Data(message))
        XCTAssertEqual(parsed?.records.count, 0)
    }

    func testRejectsTruncatedMessages() {
        XCTAssertNil(DNSMessage.parse(Data()))
        XCTAssertNil(DNSMessage.parse(Data([0x00, 0x00, 0x84])))
    }

    /// RDLENGTH that runs past the buffer must stop parsing, not read past it.
    func testOversizedRDLengthIsRejected() {
        var message: [UInt8] = [0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        message += [4] + Array("_hap".utf8) + [4] + Array("_udp".utf8) + [5] + Array("local".utf8) + [0]
        message += [0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78]
        message += [0xFF, 0xFF]     // claims 65535 bytes of RDATA
        message += [0x01]

        let parsed = DNSMessage.parse(Data(message))
        XCTAssertEqual(parsed?.records.count, 0)
    }
}
