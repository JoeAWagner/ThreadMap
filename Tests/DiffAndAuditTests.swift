import XCTest
@testable import ThreadMap

final class TopologyDifferTests: XCTestCase {

    private let builder = TopologyBuilder()
    private let differ = TopologyDiffer()

    private func topology(withDoorConfig config: String?, includeLamp: Bool) -> Topology {
        var records = [
            Fixture.record(.hapThread, name: "Front Door",
                           txt: Fixture.txt(["id": "AA:BB:CC:DD:EE:FF", "ci": "6",
                                             "c#": config ?? "1"]),
                           addresses: ["fd11:2233:4455:6677::5"], hostname: "door.local.")
        ]
        if includeLamp {
            records.append(
                Fixture.record(.hapThread, name: "Hall Lamp",
                               txt: Fixture.txt(["id": "11:22:33:44:55:66", "ci": "5"]),
                               addresses: ["fd11:2233:4455:6677::6"], hostname: "lamp.local.")
            )
        }
        return builder.build(.init(records: records))
    }

    func testDetectsDisappearanceAndAppearance() {
        let before = Fixture.snapshot(topology(withDoorConfig: "1", includeLamp: true))
        let after = Fixture.snapshot(topology(withDoorConfig: "1", includeLamp: false))

        let removals = differ.diff(from: before, to: after)
        XCTAssertTrue(removals.contains { $0.kind == .deviceDisappeared && $0.subject == "Hall Lamp" })

        let additions = differ.diff(from: after, to: before)
        XCTAssertTrue(additions.contains { $0.kind == .deviceAppeared && $0.subject == "Hall Lamp" })
    }

    /// A HAP config-number bump is the firmware-update signal. The state number
    /// deliberately isn't reported — it changes constantly and would bury this.
    func testConfigNumberBumpIsReported() {
        let before = Fixture.snapshot(topology(withDoorConfig: "1", includeLamp: false))
        let after = Fixture.snapshot(topology(withDoorConfig: "2", includeLamp: false))

        let changes = differ.diff(from: before, to: after)
        XCTAssertTrue(changes.contains { $0.kind == .deviceReconfigured && $0.subject == "Front Door" })
    }

    /// A shorter browse window can hide a sleepy device all on its own, so the
    /// differ must say so rather than blaming the device.
    func testShorterScanIsCalledOutOnDisappearance() throws {
        let before = Fixture.snapshot(topology(withDoorConfig: "1", includeLamp: true), browseDuration: 15)
        let after = Fixture.snapshot(topology(withDoorConfig: "1", includeLamp: false), browseDuration: 3)

        let change = try XCTUnwrap(
            differ.diff(from: before, to: after).first { $0.kind == .deviceDisappeared }
        )
        XCTAssertTrue(change.detail?.contains("shorter") == true)
    }

    func testIdenticalScansProduceNoChanges() {
        let snapshot = Fixture.snapshot(topology(withDoorConfig: "1", includeLamp: true))
        XCTAssertTrue(differ.diff(from: snapshot, to: snapshot).isEmpty)
    }
}

final class PostureAuditorTests: XCTestCase {

    private let builder = TopologyBuilder()
    private let auditor = PostureAuditor()

    /// Two routers agreeing on the network but disagreeing on the partition
    /// means the mesh has physically split — the highest-severity finding, and
    /// the one nothing else surfaces.
    func testPartitionSplitIsDetected() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "Apple TV",
                           txt: Fixture.borderAgentTXT(partitionID: [0x11, 0x11, 0x11, 0x11]),
                           addresses: ["192.168.1.10"], hostname: "a.local."),
            Fixture.record(.meshcop, name: "HomePod",
                           txt: Fixture.borderAgentTXT(borderAgentID: Array(repeating: 0xCD, count: 16),
                                                       partitionID: [0x22, 0x22, 0x22, 0x22]),
                           addresses: ["192.168.1.11"], hostname: "b.local.")
        ]))

        let findings = auditor.audit(.init(topology: topology))
        let split = try XCTUnwrap(findings.first { $0.id.hasPrefix("mesh.partition-split") })
        XCTAssertEqual(split.severity, .high)
        XCTAssertNotNil(split.remediation)
        XCTAssertEqual(findings.ranked.first?.id, split.id, "highest severity should sort first")
    }

    /// Routers sharing a partition are healthy and must not be flagged.
    func testMatchingPartitionsAreNotFlagged() {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "Apple TV", txt: Fixture.borderAgentTXT(),
                           addresses: ["192.168.1.10"], hostname: "a.local."),
            Fixture.record(.meshcop, name: "HomePod",
                           txt: Fixture.borderAgentTXT(borderAgentID: Array(repeating: 0xCD, count: 16)),
                           addresses: ["192.168.1.11"], hostname: "b.local.")
        ]))

        let findings = auditor.audit(.init(topology: topology))
        XCTAssertFalse(findings.contains { $0.id.hasPrefix("mesh.partition-split") })
    }

    func testUnpairedAccessoryIsFlagged() throws {
        let topology = builder.build(.init(records: [
            Fixture.record(.hapThread, name: "New Bulb",
                           txt: Fixture.txt(["ci": "5", "sf": "1"]),
                           addresses: ["fd11:2233:4455:6677::7"], hostname: "bulb.local.")
        ]))

        let finding = try XCTUnwrap(
            auditor.audit(.init(topology: topology)).first { $0.id == "exposure.unpaired" }
        )
        XCTAssertEqual(finding.severity, .medium)
        XCTAssertTrue(finding.subjects.contains("New Bulb"))
        XCTAssertNotNil(finding.evidence)
    }

    func testCleanNetworkProducesNoActionableFindings() {
        let topology = builder.build(.init(records: [
            Fixture.record(.meshcop, name: "Apple TV",
                           txt: Fixture.borderAgentTXT(stateBitmap: [0x00, 0x00, 0x06, 0x10]),
                           addresses: ["192.168.1.10"], hostname: "a.local."),
            Fixture.record(.meshcop, name: "HomePod",
                           txt: Fixture.borderAgentTXT(borderAgentID: Array(repeating: 0xCD, count: 16),
                                                       stateBitmap: [0x00, 0x00, 0x06, 0x10]),
                           addresses: ["192.168.1.11"], hostname: "b.local."),
            Fixture.record(.hapThread, name: "Front Door",
                           txt: Fixture.txt(["ci": "6", "sf": "0"]),
                           addresses: ["fd11:2233:4455:6677::5"], hostname: "d.local.")
        ]))

        XCTAssertEqual(auditor.audit(.init(topology: topology)).actionableCount, 0)
    }
}

final class DeviceLedgerTests: XCTestCase {

    private let builder = TopologyBuilder()

    private func topology(includeLamp: Bool) -> Topology {
        var records = [
            Fixture.record(.hapThread, name: "Front Door",
                           txt: Fixture.txt(["id": "AA:BB:CC:DD:EE:FF", "ci": "6"]),
                           addresses: ["fd11:2233:4455:6677::5"], hostname: "door.local.")
        ]
        if includeLamp {
            records.append(
                Fixture.record(.hapThread, name: "Hall Lamp",
                               txt: Fixture.txt(["id": "11:22:33:44:55:66", "ci": "5"]),
                               addresses: ["fd11:2233:4455:6677::6"], hostname: "lamp.local.")
            )
        }
        return builder.build(.init(records: records))
    }

    func testTracksFirstAndLastSeen() throws {
        var ledger = DeviceLedger()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let later = first.addingTimeInterval(3600)

        ledger.record(topology(includeLamp: true), at: first)
        ledger.record(topology(includeLamp: true), at: later)

        let entry = try XCTUnwrap(ledger.entries["hap:11:22:33:44:55:66"])
        XCTAssertEqual(entry.firstSeen, first)
        XCTAssertEqual(entry.lastSeen, later)
        XCTAssertEqual(entry.scanCount, 2)
    }

    func testMissingDevicesAreReported() {
        var ledger = DeviceLedger()
        ledger.record(topology(includeLamp: true), at: Date(timeIntervalSince1970: 1_000_000))

        let missing = ledger.missing(from: topology(includeLamp: false))
        XCTAssertEqual(missing.map(\.displayName), ["Hall Lamp"])
    }

    /// A device renamed between scans must not read as one leaving and another
    /// arriving — that's the whole reason stableKey exists.
    func testRenameDoesNotLookLikeADisappearance() {
        var ledger = DeviceLedger()
        let original = builder.build(.init(records: [
            Fixture.record(.hapThread, name: "Front Door",
                           txt: Fixture.txt(["id": "AA:BB:CC:DD:EE:FF", "ci": "6"]),
                           addresses: ["fd11:2233:4455:6677::5"], hostname: "door.local.")
        ]))
        let renamed = builder.build(.init(records: [
            Fixture.record(.hapThread, name: "Porch Door 9F1C",
                           txt: Fixture.txt(["id": "AA:BB:CC:DD:EE:FF", "ci": "6"]),
                           addresses: ["fd11:2233:4455:6677::5"], hostname: "door.local.")
        ]))

        ledger.record(original, at: .now)
        XCTAssertTrue(ledger.missing(from: renamed).isEmpty)
    }
}
