import Foundation

/// A running record of every device ever seen, keyed by an identity that
/// survives renames and address changes.
///
/// Consecutive-scan diffing alone can't answer "when did this last work?" — it
/// only knows about the previous scan. The ledger carries first-seen and
/// last-seen forward indefinitely, which is what turns "not here" into "gone
/// since Tuesday".
struct DeviceLedger: Codable, Hashable, Sendable {

    struct Entry: Codable, Hashable, Identifiable, Sendable {
        var id: String { key }
        let key: String
        var displayName: String
        var kind: String
        var firstSeen: Date
        var lastSeen: Date
        /// How many scans this device has appeared in. A device seen once might
        /// be a passer-by; one seen fifty times going missing is a real event.
        var scanCount: Int
        var lastKnownNetworkName: String?
        var wasOnThread: Bool

        var isSleeper: Bool { kind.localizedCaseInsensitiveContains("sensor") }
    }

    var entries: [String: Entry] = [:]

    /// Fold a scan into the ledger.
    mutating func record(_ topology: Topology, at date: Date) {
        for device in topology.devices {
            let key = device.stableKey
            let networkName = topology.network(device.networkID.value)?.displayName
            if var existing = entries[key] {
                existing.displayName = device.displayName
                existing.kind = device.kindLabel
                existing.lastSeen = date
                existing.scanCount += 1
                existing.lastKnownNetworkName = networkName ?? existing.lastKnownNetworkName
                existing.wasOnThread = device.isOnThread
                entries[key] = existing
            } else {
                entries[key] = Entry(
                    key: key,
                    displayName: device.displayName,
                    kind: device.kindLabel,
                    firstSeen: date,
                    lastSeen: date,
                    scanCount: 1,
                    lastKnownNetworkName: networkName,
                    wasOnThread: device.isOnThread
                )
            }
        }
    }

    /// Devices in the ledger that the current scan didn't find.
    func missing(from topology: Topology) -> [Entry] {
        let present = Set(topology.devices.map(\.stableKey))
        return entries.values
            .filter { !present.contains($0.key) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Devices appearing for the first time in this scan.
    func newlySeen(in topology: Topology, at date: Date) -> [Entry] {
        topology.devices.compactMap { device in
            guard let entry = entries[device.stableKey], entry.firstSeen == date else { return nil }
            return entry
        }
    }

    /// Drop devices that were seen once, long ago — usually a neighbour's phone
    /// or a device that was briefly in setup mode.
    mutating func prune(olderThan interval: TimeInterval = 60 * 24 * 3600, now: Date = .now) {
        entries = entries.filter { _, entry in
            entry.scanCount > 1 || entry.lastSeen > now.addingTimeInterval(-interval)
        }
    }
}
