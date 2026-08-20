import Foundation

/// A single difference between two scans.
struct TopologyChange: Identifiable, Hashable, Codable, Sendable {

    enum Kind: String, Codable, Sendable {
        case deviceAppeared, deviceDisappeared, deviceMoved, deviceReconfigured
        case routerAppeared, routerDisappeared, leaderChanged, partitionChanged
        case networkAppeared, networkDisappeared
        case accessoryFirmware, accessoryRoom, reachabilityChanged

        var symbolName: String {
            switch self {
            case .deviceAppeared, .routerAppeared, .networkAppeared: "plus.circle.fill"
            case .deviceDisappeared, .routerDisappeared, .networkDisappeared: "minus.circle.fill"
            case .deviceMoved: "arrow.left.arrow.right.circle.fill"
            case .deviceReconfigured, .accessoryFirmware: "gearshape.circle.fill"
            case .leaderChanged, .partitionChanged: "crown.fill"
            case .accessoryRoom: "house.circle.fill"
            case .reachabilityChanged: "antenna.radiowaves.left.and.right.circle.fill"
            }
        }

        /// Additions read as neutral, removals and reconfigurations as notable.
        var isNoteworthy: Bool {
            switch self {
            case .deviceDisappeared, .routerDisappeared, .networkDisappeared,
                 .partitionChanged, .deviceReconfigured, .accessoryFirmware:
                true
            default:
                false
            }
        }
    }

    var id: String { "\(kind.rawValue)|\(subject)|\(summary)" }
    var kind: Kind
    var subject: String
    var summary: String
    var detail: String?
    var date: Date
}

/// Compares two scans and reports what moved.
///
/// Deliberately conservative about what counts as a change: a HAP state number
/// (`s#`) increments on every characteristic update and would drown the list,
/// so only the config number (`c#`) — which changes when an accessory alters
/// its service definition, typically a firmware update — is reported.
struct TopologyDiffer {

    func diff(from old: ScanSnapshot, to new: ScanSnapshot) -> [TopologyChange] {
        var changes: [TopologyChange] = []
        changes += deviceChanges(old: old, new: new)
        changes += routerChanges(old: old, new: new)
        changes += networkChanges(old: old, new: new)
        changes += accessoryChanges(old: old, new: new)
        return changes.sorted { lhs, rhs in
            if lhs.kind.isNoteworthy != rhs.kind.isNoteworthy { return lhs.kind.isNoteworthy }
            return lhs.subject.localizedCaseInsensitiveCompare(rhs.subject) == .orderedAscending
        }
    }

    // MARK: - Devices

    private func deviceChanges(old: ScanSnapshot, new: ScanSnapshot) -> [TopologyChange] {
        var changes: [TopologyChange] = []
        let oldByKey = Dictionary(old.topology.devices.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
        let newByKey = Dictionary(new.topology.devices.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })

        for (key, device) in newByKey where oldByKey[key] == nil {
            changes.append(
                TopologyChange(kind: .deviceAppeared, subject: device.displayName,
                               summary: "appeared",
                               detail: "First seen on this scan, on \(device.transport.value.label).",
                               date: new.date)
            )
        }

        for (key, device) in oldByKey where newByKey[key] == nil {
            // A shorter browse window finds fewer sleepy devices, so say so
            // rather than reporting a disappearance we may have caused.
            let shorterScan = new.browseDuration < old.browseDuration
            changes.append(
                TopologyChange(kind: .deviceDisappeared, subject: device.displayName,
                               summary: "stopped answering",
                               detail: shorterScan
                                ? "This scan's browse window was shorter than the previous one (\(Int(new.browseDuration))s vs \(Int(old.browseDuration))s), which alone can hide a sleepy device."
                                : "Present in the previous scan, absent from this one.",
                               date: new.date)
            )
        }

        for (key, device) in newByKey {
            guard let previous = oldByKey[key] else { continue }

            if previous.networkID.value != device.networkID.value {
                let from = old.topology.network(previous.networkID.value)?.displayName ?? "no network"
                let to = new.topology.network(device.networkID.value)?.displayName ?? "no network"
                changes.append(
                    TopologyChange(kind: .deviceMoved, subject: device.displayName,
                                   summary: "moved network",
                                   detail: "\(from) → \(to).",
                                   date: new.date)
                )
            }

            if let oldConfig = previous.hap?.configNumber, let newConfig = device.hap?.configNumber,
               newConfig > oldConfig {
                changes.append(
                    TopologyChange(kind: .deviceReconfigured, subject: device.displayName,
                                   summary: "changed its service definition",
                                   detail: "HAP config number \(oldConfig) → \(newConfig). An accessory bumps this when its services change, which almost always means a firmware update.",
                                   date: new.date)
                )
            }

            let oldAddresses = Set(previous.addresses.filter(\.isRoutable).map(\.text))
            let newAddresses = Set(device.addresses.filter(\.isRoutable).map(\.text))
            if !oldAddresses.isEmpty, !newAddresses.isEmpty, oldAddresses.isDisjoint(with: newAddresses) {
                changes.append(
                    TopologyChange(kind: .deviceMoved, subject: device.displayName,
                                   summary: "changed address",
                                   detail: "None of its previous routable addresses are still in use. Normal after a prefix change; unexpected otherwise.",
                                   date: new.date)
                )
            }
        }

        return changes
    }

    // MARK: - Routers and networks

    private func routerChanges(old: ScanSnapshot, new: ScanSnapshot) -> [TopologyChange] {
        var changes: [TopologyChange] = []
        let oldByID = Dictionary(old.topology.borderRouters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(new.topology.borderRouters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, router) in newByID where oldByID[id] == nil {
            changes.append(
                TopologyChange(kind: .routerAppeared, subject: router.displayName,
                               summary: "joined as a border router",
                               detail: router.hardwareDescription, date: new.date)
            )
        }
        for (id, router) in oldByID where newByID[id] == nil {
            changes.append(
                TopologyChange(kind: .routerDisappeared, subject: router.displayName,
                               summary: "stopped advertising",
                               detail: "It was a border router in the previous scan. If it's still powered, its Thread interface may have detached.",
                               date: new.date)
            )
        }
        for (id, router) in newByID {
            guard let previous = oldByID[id] else { continue }
            if previous.isLeader != router.isLeader, router.isLeader {
                changes.append(
                    TopologyChange(kind: .leaderChanged, subject: router.displayName,
                                   summary: "became the Thread leader",
                                   detail: "The leader assigns router IDs and holds network configuration. Occasional handover is normal; frequent handover is not.",
                                   date: new.date)
                )
            }
            if let oldPartition = previous.meshcop?.partitionID,
               let newPartition = router.meshcop?.partitionID,
               oldPartition != newPartition {
                changes.append(
                    TopologyChange(kind: .partitionChanged, subject: router.displayName,
                                   summary: "changed partition",
                                   detail: "0x\(String(format: "%08X", oldPartition)) → 0x\(String(format: "%08X", newPartition)). The mesh re-formed around this router.",
                                   date: new.date)
                )
            }
        }
        return changes
    }

    private func networkChanges(old: ScanSnapshot, new: ScanSnapshot) -> [TopologyChange] {
        var changes: [TopologyChange] = []
        let oldIDs = Set(old.topology.networks.map(\.id))
        for network in new.topology.networks where !oldIDs.contains(network.id) {
            changes.append(
                TopologyChange(kind: .networkAppeared, subject: network.displayName,
                               summary: "is a new Thread network", detail: nil, date: new.date)
            )
        }
        let newIDs = Set(new.topology.networks.map(\.id))
        for network in old.topology.networks where !newIDs.contains(network.id) {
            changes.append(
                TopologyChange(kind: .networkDisappeared, subject: network.displayName,
                               summary: "is no longer visible",
                               detail: "No border router advertised it on this scan.", date: new.date)
            )
        }
        return changes
    }

    private func accessoryChanges(old: ScanSnapshot, new: ScanSnapshot) -> [TopologyChange] {
        var changes: [TopologyChange] = []
        let oldByID = Dictionary(old.topology.accessories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for accessory in new.topology.accessories {
            guard let previous = oldByID[accessory.id] else { continue }

            if previous.firmwareVersion != accessory.firmwareVersion,
               let from = previous.firmwareVersion, let to = accessory.firmwareVersion {
                changes.append(
                    TopologyChange(kind: .accessoryFirmware, subject: accessory.name,
                                   summary: "firmware changed",
                                   detail: "\(from) → \(to).", date: new.date)
                )
            }
            if previous.roomName != accessory.roomName {
                changes.append(
                    TopologyChange(kind: .accessoryRoom, subject: accessory.name,
                                   summary: "moved room",
                                   detail: "\(previous.roomName ?? "no room") → \(accessory.roomName ?? "no room").",
                                   date: new.date)
                )
            }
            if previous.isReachable != accessory.isReachable {
                changes.append(
                    TopologyChange(kind: .reachabilityChanged, subject: accessory.name,
                                   summary: accessory.isReachable ? "came back online" : "went offline",
                                   detail: nil, date: new.date)
                )
            }
        }
        return changes
    }
}
