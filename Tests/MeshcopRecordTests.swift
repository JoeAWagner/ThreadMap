import XCTest
@testable import ThreadMap

final class MeshcopRecordTests: XCTestCase {

    /// The `sb` state bitmap is the highest-risk decode in the app: it's a
    /// packed 32-bit field and a wrong bit offset would silently mislabel every
    /// router's role forever, with no visible symptom. This test pins the
    /// layout in one place, so if it turns out to disagree with a real router,
    /// there's exactly one thing to change.
    ///
    /// 0x0FB1 = 0000 1111 1011 0001
    ///   bits 0–2  = 001 → connection mode PSKc
    ///   bits 3–4  = 10  → interface active
    ///   bits 5–6  = 01  → availability high
    ///   bit  7    = 1   → backbone router active
    ///   bit  8    = 1   → backbone router primary
    ///   bits 9–10 = 11  → Thread role leader
    ///   bit  11   = 1   → ephemeral key supported
    func testStateBitmapDecoding() {
        let record = MeshcopRecord(txt: Fixture.borderAgentTXT(stateBitmap: [0x00, 0x00, 0x0F, 0xB1]))

        XCTAssertEqual(record.rawStateBitmap, 0x0FB1)
        XCTAssertEqual(record.connectionMode, .pskc)
        XCTAssertEqual(record.interfaceStatus, .active)
        XCTAssertEqual(record.availability, .high)
        XCTAssertEqual(record.isBackboneRouterActive, true)
        XCTAssertEqual(record.isPrimaryBackboneRouter, true)
        XCTAssertEqual(record.threadRole, .leader)
        XCTAssertEqual(record.supportsEphemeralKey, true)
    }

    /// A router that isn't joinable and isn't attached — the other end of the
    /// range, so a zero bitmap can't accidentally read as "healthy leader".
    func testEmptyStateBitmap() {
        let record = MeshcopRecord(txt: Fixture.borderAgentTXT(stateBitmap: [0x00, 0x00, 0x00, 0x00]))

        XCTAssertEqual(record.connectionMode, .disallowed)
        XCTAssertEqual(record.interfaceStatus, .notInitialized)
        XCTAssertEqual(record.isBackboneRouterActive, false)
        XCTAssertEqual(record.threadRole, .disabledOrDetached)
        XCTAssertEqual(record.supportsEphemeralKey, false)
    }

    /// Binary TXT values must survive as hex, not be mangled through UTF-8.
    func testBinaryIdentifiersDecodeAsHex() {
        let record = MeshcopRecord(txt: Fixture.borderAgentTXT())

        XCTAssertEqual(record.extendedPANID, "1A2B3C4D5E6F7081")
        XCTAssertEqual(record.borderAgentID, String(repeating: "AB", count: 16))
        XCTAssertEqual(record.partitionID, 0x12345678)
        XCTAssertEqual(record.networkName, "Home Thread")
        XCTAssertEqual(record.threadVersion, "1.4.0")
    }

    func testOMRPrefixDecoding() throws {
        let record = MeshcopRecord(txt: Fixture.borderAgentTXT())
        let prefix = try XCTUnwrap(record.omrPrefix)

        XCTAssertEqual(prefix.length, 64)
        XCTAssertTrue(prefix.contains(Fixture.address("fd11:2233:4455:6677::1")))
    }

    /// Thread 1.3 routers don't publish `omr` at all; that must not be an error.
    func testMissingOMRPrefixIsNil() {
        let record = MeshcopRecord(txt: Fixture.borderAgentTXT(omrPrefix: nil))
        XCTAssertNil(record.omrPrefix)
        XCTAssertNotNil(record.extendedPANID)
    }
}
