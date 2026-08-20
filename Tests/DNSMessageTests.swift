import XCTest
@testable import ThreadMap

final class DNSMessageTests: XCTestCase {

    // MARK: - Fixture builders
    //
    // Built imperatively rather than as `[0x00] + Array("x".utf8) + [0x01]`
    // chains: a long `+` chain of untyped integer literals mixed with
    // `Array(String.utf8)` is the classic case that makes Swift's type checker
    // give up with "unable to type-check this expression in reasonable time".

    /// Encodes a domain name as length-prefixed labels, terminated by a zero.
    private func encodedName(_ labels: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in labels {
            let utf8 = Array(label.utf8)
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        return bytes
    }

    /// A response header declaring one answer and no questions.
    private func responseHeader(answers: UInt16 = 1) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0x00, 0x00])                     // transaction ID
        bytes.append(contentsOf: [0x84, 0x00])                     // response, authoritative
        bytes.append(contentsOf: [0x00, 0x00])                     // no questions
        bytes.append(UInt8(answers >> 8))
        bytes.append(UInt8(answers & 0xFF))
        bytes.append(contentsOf: [0x00, 0x00])                     // no authority
        bytes.append(contentsOf: [0x00, 0x00])                     // no additional
        return bytes
    }

    /// Type PTR, class IN, a TTL — the fixed part of every answer we build.
    private func ptrRecordPreamble() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0x00, 0x0C])                     // type PTR
        bytes.append(contentsOf: [0x00, 0x01])                     // class IN
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x78])         // TTL
        return bytes
    }

    /// A full response whose single PTR answer points at `instance`, with the
    /// service name compressed back to the answer's own name at offset 12.
    private func ptrResponse(instance: String) -> Data {
        var message = responseHeader()
        message.append(contentsOf: encodedName(["_hap", "_udp", "local"]))
        message.append(contentsOf: ptrRecordPreamble())

        var target: [UInt8] = []
        let utf8 = Array(instance.utf8)
        target.append(UInt8(utf8.count))
        target.append(contentsOf: utf8)
        target.append(contentsOf: [0xC0, 0x0C])                    // pointer to offset 12

        message.append(0x00)
        message.append(UInt8(target.count))                        // RDLENGTH
        message.append(contentsOf: target)
        return Data(message)
    }

    // MARK: - Query

    func testQueryEncoding() {
        let query = DNSMessage.query(name: "_hap._udp.local")
        let bytes = [UInt8](query)

        XCTAssertEqual(Array(bytes[0..<4]), [0x00, 0x00, 0x00, 0x00])   // ID + flags
        XCTAssertEqual(Array(bytes[4..<6]), [0x00, 0x01])               // one question
        XCTAssertEqual(Array(bytes[6..<12]), [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        let expectedName = encodedName(["_hap", "_udp", "local"])
        XCTAssertEqual(Array(bytes[12..<(12 + expectedName.count)]), expectedName)
        XCTAssertEqual(Array(bytes.suffix(4)), [0x00, 0x0C, 0x00, 0x01]) // QTYPE PTR, QCLASS IN
    }

    // MARK: - Parsing

    /// A realistic response: a PTR whose RDATA uses a compression pointer back
    /// into the answer's own name. Getting this wrong truncates instance names.
    func testParsesPTRWithCompressionPointer() throws {
        let parsed = try XCTUnwrap(DNSMessage.parse(ptrResponse(instance: "Front Door")))

        XCTAssertTrue(parsed.isResponse)
        XCTAssertEqual(parsed.records.count, 1)

        let record = try XCTUnwrap(parsed.records.first)
        XCTAssertEqual(record.nameLabels, ["_hap", "_udp", "local"])
        XCTAssertEqual(record.type, DNSMessage.typePTR)
        XCTAssertEqual(record.targetLabels, ["Front Door", "_hap", "_udp", "local"])

        // And the whole point: the instance name comes back out.
        XCTAssertEqual(parsed.instanceNames(forServiceTypes: ["_hap._udp"]), ["Front Door"])
    }

    /// Instance names legitimately contain dots ("Lamp v1.2"), so they must be
    /// taken as a whole label, never split on ".".
    func testInstanceNameContainingADot() throws {
        let parsed = try XCTUnwrap(DNSMessage.parse(ptrResponse(instance: "Lamp v1.2")))
        XCTAssertEqual(parsed.instanceNames(forServiceTypes: ["_hap._udp"]), ["Lamp v1.2"])
    }

    /// A name that points at itself must terminate, not spin. This is the one
    /// place a malformed packet from an untrusted device could hang the app.
    func testSelfReferentialPointerTerminates() {
        var message = responseHeader()
        message.append(contentsOf: [0xC0, 0x0C])   // name at offset 12 points to offset 12

        // An empty record list is the correct outcome for an undecodable name;
        // the contract being tested is that it returns at all.
        let parsed = DNSMessage.parse(Data(message))
        XCTAssertEqual(parsed?.records.count, 0)
    }

    func testRejectsTruncatedMessages() {
        XCTAssertNil(DNSMessage.parse(Data()))
        XCTAssertNil(DNSMessage.parse(Data([0x00, 0x00, 0x84])))
    }

    /// RDLENGTH running past the buffer must stop parsing, not read past it.
    func testOversizedRDLengthIsRejected() {
        var message = responseHeader()
        message.append(contentsOf: encodedName(["_hap", "_udp", "local"]))
        message.append(contentsOf: ptrRecordPreamble())
        message.append(contentsOf: [0xFF, 0xFF])   // claims 65535 bytes of RDATA
        message.append(0x01)

        let parsed = DNSMessage.parse(Data(message))
        XCTAssertEqual(parsed?.records.count, 0)
    }
}
