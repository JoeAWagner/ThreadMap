import XCTest
@testable import ThreadMap

final class MatterRecordTests: XCTestCase {

    /// The operational instance name is the only place a commissioned Matter
    /// node's identity appears — and the node ID half is our exact join key to
    /// HomeKit's `matterNodeID`.
    func testOperationalInstanceNameSplit() {
        let record = MatterRecord(
            instanceName: "8FC7772401CD0696-0000000012344321",
            txt: Fixture.txt(["SII": "5000", "SAI": "300", "ICD": "0"])
        )

        XCTAssertEqual(record.compressedFabricID, "8FC7772401CD0696")
        XCTAssertEqual(record.nodeIDHex, "0000000012344321")
        XCTAssertEqual(record.nodeID, 0x12344321)
    }

    /// Commissionable instance names are random and carry no identity.
    func testCommissionableInstanceNameYieldsNoIdentity() {
        let record = MatterRecord(
            instanceName: "DD200C20D25AE5F7",
            txt: Fixture.txt(["D": "3840", "CM": "1", "VP": "4937+8", "DN": "Front Lamp"])
        )

        XCTAssertNil(record.compressedFabricID)
        XCTAssertNil(record.nodeIDHex)
        XCTAssertEqual(record.discriminator, 3840)
        XCTAssertEqual(record.commissioningMode, 1)
        XCTAssertEqual(record.vendorID, 4937)
        XCTAssertEqual(record.productID, 8)
        XCTAssertEqual(record.deviceName, "Front Lamp")
    }

    /// Matter encodes every TXT value as ASCII, including numbers — decoding
    /// them as big-endian binary the way Thread does would produce nonsense.
    func testNumericValuesAreASCIINotBinary() {
        let record = MatterRecord(instanceName: "x", txt: Fixture.txt(["SII": "5000"]))
        XCTAssertEqual(record.sessionIdleIntervalMS, 5000)
    }

    func testSleepyDetection() {
        let lit = MatterRecord(instanceName: "x", txt: Fixture.txt(["ICD": "1"]))
        XCTAssertEqual(lit.icdMode, .longIdle)
        XCTAssertTrue(lit.looksSleepy)

        let mains = MatterRecord(instanceName: "x", txt: Fixture.txt(["SII": "100"]))
        XCTAssertFalse(mains.looksSleepy)
    }
}

final class HAPRecordTests: XCTestCase {

    /// Status flag bit 0 set means "never paired" — the finding that matters
    /// most, so it gets a test in both directions.
    func testUnpairedFlag() {
        let unpaired = HAPRecord(txt: Fixture.txt(["sf": "1", "ci": "5", "md": "Bulb"]))
        XCTAssertEqual(unpaired.isUnpaired, true)

        let paired = HAPRecord(txt: Fixture.txt(["sf": "0", "ci": "5"]))
        XCTAssertEqual(paired.isUnpaired, false)

        let unknown = HAPRecord(txt: Fixture.txt(["ci": "5"]))
        XCTAssertNil(unknown.isUnpaired)
    }

    func testCategoryNames() {
        XCTAssertEqual(HAPRecord(txt: Fixture.txt(["ci": "5"])).categoryName, "Lightbulb")
        XCTAssertEqual(HAPRecord(txt: Fixture.txt(["ci": "6"])).categoryName, "Door Lock")
        XCTAssertEqual(HAPRecord(txt: Fixture.txt(["ci": "10"])).categoryName, "Sensor")
        XCTAssertEqual(HAPRecord(txt: Fixture.txt([:])).categoryName, "Accessory")
    }

    func testConfigNumberParsing() {
        let record = HAPRecord(txt: Fixture.txt(["c#": "7", "s#": "1", "id": "AA:BB:CC:DD:EE:FF"]))
        XCTAssertEqual(record.configNumber, 7)
        XCTAssertEqual(record.deviceID, "AA:BB:CC:DD:EE:FF")
    }
}
