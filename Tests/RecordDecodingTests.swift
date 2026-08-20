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

final class UPnPDescriptionParserTests: XCTestCase {

    /// A UPnP description can nest embedded devices whose names would otherwise
    /// overwrite the root device's — the root is the one you actually want.
    func testTakesRootDeviceNotEmbeddedOne() throws {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>Living Room</friendlyName>
            <manufacturer>Sonos, Inc.</manufacturer>
            <modelName>Sonos One</modelName>
            <UDN>uuid:RINCON-000E58</UDN>
            <deviceList>
              <device>
                <friendlyName>Embedded Should Not Win</friendlyName>
                <modelName>Embedded Model</modelName>
              </device>
            </deviceList>
          </device>
        </root>
        """
        let parsed = try XCTUnwrap(UPnPDescriptionParser.parse(Data(xml.utf8)))

        XCTAssertEqual(parsed.friendlyName, "Living Room")
        XCTAssertEqual(parsed.manufacturer, "Sonos, Inc.")
        XCTAssertEqual(parsed.modelName, "Sonos One")
        XCTAssertEqual(parsed.udn, "uuid:RINCON-000E58")
    }

    func testMalformedXMLIsRejected() {
        XCTAssertNil(UPnPDescriptionParser.parse(Data("<root><device>".utf8)))
    }
}

final class MatterFabricTests: XCTestCase {

    private let builder = TopologyBuilder()

    /// The whole point: counting distinct fabrics tells you how many parties
    /// can control your devices.
    func testGroupsDevicesByFabric() {
        let topology = builder.build(.init(records: [
            Fixture.record(.matter, name: "AAAAAAAAAAAAAAAA-0000000000000001",
                           addresses: ["fd11:2233:4455:6677::1"], hostname: "a.local."),
            Fixture.record(.matter, name: "AAAAAAAAAAAAAAAA-0000000000000002",
                           addresses: ["fd11:2233:4455:6677::2"], hostname: "b.local."),
            Fixture.record(.matter, name: "BBBBBBBBBBBBBBBB-0000000000000003",
                           addresses: ["fd11:2233:4455:6677::3"], hostname: "c.local.")
        ]))

        let fabrics = topology.matterFabrics
        XCTAssertEqual(fabrics.count, 2)
        XCTAssertEqual(fabrics.first?.deviceCount, 2, "fabrics sort by device count")
    }

    /// A device commissioned into two ecosystems advertises one instance per
    /// fabric, both resolving to the same host — which is how multi-admin
    /// becomes visible at all.
    func testDetectsMultiAdminDevice() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.matter, name: "AAAAAAAAAAAAAAAA-0000000000000001",
                           addresses: ["fd11:2233:4455:6677::1"], hostname: "lock.local."),
            Fixture.record(.matter, name: "BBBBBBBBBBBBBBBB-0000000000000001",
                           addresses: ["fd11:2233:4455:6677::1"], hostname: "lock.local.")
        ]))

        XCTAssertEqual(topology.devices.count, 1, "same host means one device, two registrations")
        let shared = try XCTUnwrap(topology.multiAdminDevices.first)
        XCTAssertEqual(shared.fabricIDs, ["AAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBB"])
    }

    func testSingleFabricIsNotFlaggedAsShared() {
        let topology = builder.build(.init(records: [
            Fixture.record(.matter, name: "AAAAAAAAAAAAAAAA-0000000000000001",
                           addresses: ["fd11:2233:4455:6677::1"], hostname: "a.local.")
        ]))
        XCTAssertTrue(topology.multiAdminDevices.isEmpty)
    }
}
