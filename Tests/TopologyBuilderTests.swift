import XCTest
@testable import ThreadMap

final class TopologyBuilderTests: XCTestCase {

    private let builder = TopologyBuilder()

    // MARK: - Transport classification

    /// HAP over CoAP/UDP is only used on Thread. This is the one transport call
    /// the app makes with certainty, so it must not degrade to a guess.
    func testHAPOverUDPIsObservedThread() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.hapThread, name: "Front Door", txt: Fixture.txt(["ci": "6", "sf": "0"]),
                           addresses: ["fd11:2233:4455:6677::5"])
        ]))

        let device = try XCTUnwrap(topology.devices.first)
        XCTAssertEqual(device.transport.value, .thread)
        XCTAssertEqual(device.transport.confidence, .observed)
    }

    /// Thread is IPv6-only, so an IPv4 address settles it the other way.
    func testIPv4MeansNotThread() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.matter, name: "8FC7772401CD0696-0000000012344321",
                           addresses: ["192.168.1.40"])
        ]))

        let device = try XCTUnwrap(topology.devices.first)
        XCTAssertEqual(device.transport.value, .wifiOrEthernet)
        XCTAssertEqual(device.transport.confidence, .derived)
        XCTAssertNil(device.networkID.value)
    }

    // MARK: - Network placement

    /// The strongest placement rule: the device's address falls inside a prefix
    /// a border router says it routes.
    func testDeviceIsPlacedByOMRPrefixMatch() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "Living Room Apple TV",
                           txt: Fixture.borderAgentTXT(),
                           addresses: ["192.168.1.10"], hostname: "apple-tv.local."),
            Fixture.record(.hapThread, name: "Front Door",
                           txt: Fixture.txt(["ci": "6", "sf": "0"]),
                           addresses: ["fd11:2233:4455:6677::5"], hostname: "door.local.")
        ]))

        let device = try XCTUnwrap(topology.devices.first)
        XCTAssertEqual(device.networkID.confidence, .derived)
        XCTAssertEqual(topology.network(device.networkID.value)?.name, "Home Thread")
        XCTAssertTrue(device.networkID.reason.contains("fd11"))
    }

    /// An address outside every advertised prefix, with two networks visible,
    /// must stay unplaced rather than being guessed onto one.
    func testAmbiguousDeviceIsNotGuessed() throws {
        let secondAgent = Fixture.borderAgentTXT(
            networkName: "Garage Thread",
            extendedPANID: [0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22],
            borderAgentID: Array(repeating: 0xCD, count: 16),
            omrPrefix: [64, 0xFD, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33]
        )
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "Apple TV", txt: Fixture.borderAgentTXT(),
                           addresses: ["192.168.1.10"], hostname: "a.local."),
            Fixture.record(.meshcop, name: "HomePod", txt: secondAgent,
                           addresses: ["192.168.1.11"], hostname: "b.local."),
            Fixture.record(.hapThread, name: "Orphan", txt: Fixture.txt(["ci": "10"]),
                           addresses: ["fd55:5555:5555:5555::9"], hostname: "c.local.")
        ]))

        let device = try XCTUnwrap(topology.devices.first { $0.displayName == "Orphan" })
        XCTAssertNil(device.networkID.value)
        XCTAssertEqual(device.networkID.confidence, .unknown)
        XCTAssertEqual(topology.networks.count, 2)
    }

    // MARK: - Border routers

    func testBorderRouterStateIsSurfaced() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "Living Room Apple TV",
                           txt: Fixture.borderAgentTXT(),
                           addresses: ["192.168.1.10"], hostname: "apple-tv.local.")
        ]))

        let router = try XCTUnwrap(topology.borderRouters.first)
        XCTAssertTrue(router.isLeader)
        XCTAssertTrue(router.isAttached)
        XCTAssertTrue(router.isPrimaryBackboneRouter)
        XCTAssertEqual(router.vendorName, "Apple Inc.")
        XCTAssertEqual(router.hardwareDescription, "Apple Inc. Apple TV")
    }

    /// A router whose MeshCoP instance name is a bare hex blob gets its name
    /// from a co-located AirPlay record — and keeps its hardware identity
    /// alongside, rather than one replacing the other.
    ///
    /// Vendor + model is accurate and useless when you own three Apple TVs;
    /// the AirPlay name is the one you chose. Both are shown, so neither is
    /// lost.
    func testContextRecordNamesAnAnonymousRouterAndKeepsHardware() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "A1B2C3D4E5F60718",
                           txt: Fixture.borderAgentTXT(),
                           addresses: ["192.168.1.10"], hostname: "hub.local."),
            Fixture.record(.airplay, name: "Kitchen HomePod",
                           addresses: ["192.168.1.10"], hostname: "hub.local.")
        ]))

        let router = try XCTUnwrap(topology.borderRouters.first)
        XCTAssertEqual(router.displayName, "Kitchen HomePod", "the name you'd recognise wins")
        XCTAssertEqual(router.hardwareDescription, "Apple Inc. Apple TV", "the hardware identity survives")
        XCTAssertEqual(router.advertisedInstanceName, "A1B2C3D4E5F60718", "and so does what Thread actually said")
        XCTAssertTrue(router.isShowingBorrowedName)
        XCTAssertTrue(router.alternateNames.contains("Kitchen HomePod"))
    }

    /// The reverse: a router that names itself readably keeps its own name.
    /// Borrowing is a fallback, not a preference.
    func testReadableMeshcopNameIsNotOverridden() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "Living Room Apple TV",
                           txt: Fixture.borderAgentTXT(),
                           addresses: ["192.168.1.10"], hostname: "hub.local."),
            Fixture.record(.airplay, name: "Something Else",
                           addresses: ["192.168.1.10"], hostname: "hub.local.")
        ]))

        let router = try XCTUnwrap(topology.borderRouters.first)
        XCTAssertEqual(router.displayName, "Living Room Apple TV")
        XCTAssertFalse(router.isShowingBorrowedName)
    }

    /// With no other service to borrow from, vendor + model is still better
    /// than a hex blob.
    func testFallsBackToVendorAndModelWithoutAContextRecord() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "A1B2C3D4E5F60718",
                           txt: Fixture.borderAgentTXT(),
                           addresses: ["192.168.1.10"], hostname: "hub.local.")
        ]))

        let router = try XCTUnwrap(topology.borderRouters.first)
        XCTAssertEqual(router.displayName, "Apple Inc. Apple TV")
    }

    // MARK: - Identity

    /// `stableKey` has to survive the rename that `displayName` doesn't, or
    /// history reports phantom disappearances.
    func testStableKeyPrefersBurnedInIdentifiers() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.hapThread, name: "Front Door 4C2A",
                           txt: Fixture.txt(["id": "AA:BB:CC:DD:EE:FF", "ci": "6"]),
                           addresses: ["fd11:2233:4455:6677::5"], hostname: "door.local.")
        ]))

        let device = try XCTUnwrap(topology.devices.first)
        XCTAssertEqual(device.stableKey, "hap:AA:BB:CC:DD:EE:FF")
    }

    /// The exact join key between the network view and HomeKit's view.
    func testMatterNodeIDMatchesHomeKitAccessory() throws {
        let accessory = HomeKitAccessory(
            id: UUID(), name: "Hallway Lamp", homeName: "Home", roomName: "Hallway",
            manufacturer: "Acme", model: "L1", firmwareVersion: "1.0",
            category: "Lightbulb", isReachable: true, isBridged: false, bridgeName: nil,
            matterNodeIDHex: "0000000012344321"
        )
        let topology = builder.build(.init(
            records: [Fixture.record(.matter, name: "8FC7772401CD0696-0000000012344321",
                                     addresses: ["fd11:2233:4455:6677::9"])],
            accessories: [accessory]
        ))

        let device = try XCTUnwrap(topology.devices.first)
        XCTAssertEqual(device.homeKitAccessoryID, accessory.id)
        // And the hex instance name gets replaced by the name you actually gave it.
        XCTAssertEqual(device.displayName, "Hallway Lamp")
    }

    /// Proxy attribution is a registration relationship, and only counts when
    /// the responder is a router we actually found.
    func testProxyAttributionMatchesResponderToRouter() throws {
        let topology = builder.build(.init(
            records: [
                Fixture.record(.meshcop, name: "Apple TV", txt: Fixture.borderAgentTXT(),
                               addresses: ["192.168.1.10"], hostname: "a.local."),
                Fixture.record(.hapThread, name: "Front Door", txt: Fixture.txt(["ci": "6"]),
                               addresses: ["fd11:2233:4455:6677::5"], hostname: "d.local.")
            ],
            proxyAttribution: ["Front Door": [Fixture.address("192.168.1.10")]]
        ))

        let device = try XCTUnwrap(topology.devices.first)
        let router = try XCTUnwrap(topology.borderRouters.first)
        XCTAssertEqual(device.proxiedBy, [router.id])
        XCTAssertNotNil(device.proxyEvidence)
    }

    func testUnmatchedResponderIsReportedNotSilentlyDropped() throws {
        let topology = builder.build(.init(
            records: [Fixture.record(.hapThread, name: "Front Door",
                                     txt: Fixture.txt(["ci": "6"]),
                                     addresses: ["fd11:2233:4455:6677::5"], hostname: "d.local.")],
            proxyAttribution: ["Front Door": [Fixture.address("192.168.1.99")]]
        ))

        let device = try XCTUnwrap(topology.devices.first)
        XCTAssertTrue(device.proxiedBy.isEmpty)
        XCTAssertNotNil(device.proxyEvidence)
    }
}
