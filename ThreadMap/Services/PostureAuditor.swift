import Foundation

/// Turns a scan into a list of findings.
///
/// Every rule here reads fields the scanner was already decoding and throwing
/// away. Nothing is probed, poked, or connected to — this is entirely passive
/// interpretation of advertisements the devices broadcast unprompted.
struct PostureAuditor {

    struct Input {
        var topology: Topology
        /// Previous snapshots, newest first. Used for the rules that can only
        /// be answered over time, like leader churn.
        var history: [ScanSnapshot] = []
        var ledger: DeviceLedger = DeviceLedger()
    }

    func audit(_ input: Input) -> [Finding] {
        var findings: [Finding] = []
        findings += unpairedAccessories(input.topology)
        findings += commissionableDevices(input.topology)
        findings += joinableBorderAgents(input.topology)
        findings += ephemeralKeyRouters(input.topology)
        findings += partitionSplits(input.topology)
        findings += detachedRouters(input.topology)
        findings += singleRouterNetworks(input.topology)
        findings += leaderChurn(input.history)
        findings += missingDevices(input.ledger, topology: input.topology)
        findings += unreachableAccessories(input.topology)
        findings += matterFabrics(input.topology)
        findings += multiAdminDevices(input.topology)
        findings += internetGateways(input.topology)
        return findings.ranked
    }

    // MARK: - Matter fabrics

    /// How many parties can operate your Matter devices.
    private func matterFabrics(_ topology: Topology) -> [Finding] {
        let fabrics = topology.matterFabrics
        guard !fabrics.isEmpty else { return [] }
        let breakdown = fabrics.map { "\($0.displayName): \($0.deviceCount) device\($0.deviceCount == 1 ? "" : "s")" }

        return [
            Finding(
                id: "exposure.matter-fabrics",
                severity: fabrics.count > 1 ? .low : .info,
                category: .exposure,
                title: fabrics.count == 1
                    ? "Your Matter devices are on one fabric"
                    : "Your Matter devices span \(fabrics.count) fabrics",
                detail: breakdown.joined(separator: ", ") + ".",
                impact: fabrics.count > 1
                    ? "A Matter fabric is an administrative domain, and whoever holds one has full control of every device on it. More than one fabric means more than one party can operate those devices. That's normal and intended if you deliberately added a second ecosystem — and worth investigating if you didn't."
                    : nil,
                remediation: fabrics.count > 1
                    ? "If a fabric here isn't one you set up, remove the device from that ecosystem's app, or factory-reset and re-commission it."
                    : nil,
                subjects: fabrics.map(\.displayName),
                evidence: "Compressed fabric IDs from the _matter._tcp instance names."
            )
        ]
    }

    /// A single device controlled by several ecosystems at once.
    private func multiAdminDevices(_ topology: Topology) -> [Finding] {
        let shared = topology.multiAdminDevices
        guard !shared.isEmpty else { return [] }
        let described = shared.map { "\($0.device.displayName) (\($0.fabricIDs.count) fabrics)" }

        return [
            Finding(
                id: "exposure.multi-admin",
                severity: .low,
                category: .exposure,
                title: "\(shared.count) device\(shared.count == 1 ? " is" : "s are") shared across ecosystems",
                detail: described.joined(separator: ", ") + ".",
                impact: "Each fabric a device belongs to is a separate controller with full authority over it — it can read state, actuate it, and remove it. Matter is designed to allow this, and it's how you use one lock from both Apple Home and Google Home. It also means revoking one ecosystem's access doesn't revoke another's.",
                remediation: "Review the shared devices in each ecosystem's app and remove any pairing you don't use.",
                subjects: shared.map { $0.device.displayName },
                evidence: "Several _matter._tcp instance names with different compressed fabric IDs resolving to the same host."
            )
        ]
    }

    // MARK: - UPnP

    /// A router advertising UPnP port mapping will let any device on the LAN
    /// open an inbound hole in your firewall without telling you.
    private func internetGateways(_ topology: Topology) -> [Finding] {
        let gateways = topology.upnpDevices.filter(\.isInternetGateway)
        guard !gateways.isEmpty else { return [] }

        return [
            Finding(
                id: "exposure.upnp-igd",
                severity: .medium,
                category: .exposure,
                title: "UPnP port mapping is advertised on your network",
                detail: "\(gateways.map(\.displayName).joined(separator: ", ")) advertise an Internet Gateway Device service.",
                impact: "Any device on your network can ask a UPnP gateway to forward an inbound port from the internet to itself, with no prompt and no log you'd normally see. It's convenient for games and consoles and it's also how a compromised device exposes itself to the outside world.",
                remediation: "If nothing you own needs automatic port forwarding, turn UPnP off in your router's settings and forward ports manually.",
                subjects: gateways.map(\.displayName),
                evidence: "SSDP search target contains InternetGatewayDevice."
            )
        ]
    }

    // MARK: - Exposure

    /// HAP status flag bit 0 means the accessory has never been paired. An
    /// accessory in that state accepts a pairing from anyone who can reach it.
    private func unpairedAccessories(_ topology: Topology) -> [Finding] {
        let unpaired = topology.devices.filter { $0.hap?.isUnpaired == true }
        guard !unpaired.isEmpty else { return [] }
        return [
            Finding(
                id: "exposure.unpaired",
                severity: .medium,
                category: .exposure,
                title: "\(unpaired.count) accessory\(unpaired.count == 1 ? " is" : "s are") unpaired and advertising",
                detail: "These accessories are broadcasting that they have never been paired with a controller: \(list(unpaired.map(\.displayName))).",
                impact: "An unpaired HomeKit accessory will accept a pairing from anyone who can reach it on the network — or, for a Thread accessory, anyone within radio range. That's expected while you're setting one up and a problem if it's been that way for days.",
                remediation: "Add them to your home, or factory-reset and unplug the ones you're not using.",
                subjects: unpaired.map(\.displayName),
                evidence: "HAP TXT key `sf`, bit 0 set."
            )
        ]
    }

    /// A Matter device sitting in commissioning mode is offering its setup
    /// window to the network.
    private func commissionableDevices(_ topology: Topology) -> [Finding] {
        let open = topology.devices.filter { device in
            device.protocols.contains(.matterC) && (device.matter?.commissioningMode ?? 0) > 0
        }
        guard !open.isEmpty else { return [] }
        return [
            Finding(
                id: "exposure.commissioning",
                severity: .medium,
                category: .exposure,
                title: "\(open.count) Matter device\(open.count == 1 ? " is" : "s are") in commissioning mode",
                detail: "\(list(open.map(\.displayName))) \(open.count == 1 ? "is" : "are") advertising an open commissioning window.",
                impact: "The commissioning window is meant to stay open for a few minutes during setup. A device left open can be commissioned by anyone who can see it and read its setup code or discriminator.",
                remediation: "Finish adding the device, or power-cycle it to close the window.",
                subjects: open.map(\.displayName),
                evidence: "Matter TXT key `CM` greater than zero on a _matterc._udp record."
            )
        ]
    }

    /// A border agent advertising a joining mode is an entry point into the
    /// Thread network itself, not just one device.
    private func joinableBorderAgents(_ topology: Topology) -> [Finding] {
        let joinable = topology.borderRouters.filter { router in
            guard let mode = router.meshcop?.connectionMode else { return false }
            return mode != .disallowed
        }
        guard !joinable.isEmpty else { return [] }
        let modes = Set(joinable.compactMap { $0.meshcop?.connectionMode?.label })
        return [
            Finding(
                id: "exposure.joinable-border-agent",
                severity: .low,
                category: .exposure,
                title: "\(joinable.count) border router\(joinable.count == 1 ? " is" : "s are") accepting commissioners",
                detail: "\(list(joinable.map(\.displayName))) advertise a border agent connection mode of \(list(Array(modes))).",
                impact: "This is how a commissioner joins new devices to your Thread network, so it's normal on a healthy network — worth knowing about rather than worth panicking over. It does mean the join path is reachable by anything on your Wi-Fi.",
                remediation: "Nothing to do unless you didn't expect it. If a router advertises this and you don't own it, find out whose it is.",
                subjects: joinable.map(\.displayName),
                evidence: "MeshCoP TXT key `sb`, connection-mode bits 0–2."
            )
        ]
    }

    /// Thread 1.4's ephemeral PSKc lets a commissioner attach with a short-lived
    /// code instead of the network's long-term key.
    private func ephemeralKeyRouters(_ topology: Topology) -> [Finding] {
        let routers = topology.borderRouters.filter { $0.meshcop?.supportsEphemeralKey == true }
        guard !routers.isEmpty else { return [] }
        return [
            Finding(
                id: "exposure.epskc",
                severity: .info,
                category: .exposure,
                title: "Ephemeral key commissioning is supported",
                detail: "\(list(routers.map(\.displayName))) advertise support for ephemeral PSKc (ePSKc).",
                impact: nil,
                remediation: nil,
                subjects: routers.map(\.displayName),
                evidence: "MeshCoP TXT key `sb`, bit 11."
            )
        ]
    }

    // MARK: - Mesh health

    /// Routers that agree on the network but disagree on the partition are, by
    /// definition, no longer talking to each other.
    private func partitionSplits(_ topology: Topology) -> [Finding] {
        var findings: [Finding] = []
        for network in topology.networks {
            let attached = topology.borderRouters(on: network.id).filter(\.isAttached)
            let partitions = Set(attached.compactMap { $0.meshcop?.partitionID })
            guard partitions.count > 1 else { continue }

            let breakdown = attached.compactMap { router -> String? in
                guard let partition = router.meshcop?.partitionID else { return nil }
                return "\(router.displayName) → 0x\(String(format: "%08X", partition))"
            }
            findings.append(
                Finding(
                    id: "mesh.partition-split.\(network.id)",
                    severity: .high,
                    category: .meshHealth,
                    title: "\(network.displayName) has split into \(partitions.count) partitions",
                    detail: "Routers on this network report different partition IDs: \(breakdown.joined(separator: ", ")).",
                    impact: "A Thread network that partitions has physically divided in two. Devices on one partition cannot reach devices or routers on the other, so automations spanning the split will silently fail even though every device looks online.",
                    remediation: "Usually a radio-range problem: a router lost contact with the rest of the mesh. Check that the routers are powered, on the same Thread network, and within range of each other. Partitions normally merge on their own once contact is restored.",
                    subjects: attached.map(\.displayName),
                    evidence: "MeshCoP TXT key `pt` differs across routers sharing extended PAN ID \(network.extendedPANID ?? "—")."
                )
            )
        }
        return findings
    }

    private func detachedRouters(_ topology: Topology) -> [Finding] {
        let detached = topology.borderRouters.filter { router in
            guard let status = router.meshcop?.interfaceStatus else { return false }
            return status != .active
        }
        guard !detached.isEmpty else { return [] }
        return [
            Finding(
                id: "mesh.detached-routers",
                severity: .medium,
                category: .meshHealth,
                title: "\(detached.count) border router\(detached.count == 1 ? " is" : "s are") not attached to Thread",
                detail: "\(list(detached.map(\.displayName))) are advertising a border agent but report their Thread interface as not attached.",
                impact: "The hardware is on your Wi-Fi and willing to route, but it isn't currently part of the mesh, so it's carrying none of your Thread traffic.",
                remediation: "Usually resolves on its own. If it persists, restart the router — for a HomePod or Apple TV, unplug it for ten seconds.",
                subjects: detached.map(\.displayName),
                evidence: "MeshCoP TXT key `sb`, interface-status bits 3–4."
            )
        ]
    }

    /// One router means one point of failure for every Thread device you own.
    private func singleRouterNetworks(_ topology: Topology) -> [Finding] {
        var findings: [Finding] = []
        for network in topology.networks where !network.isSynthetic {
            let routers = topology.borderRouters(on: network.id)
            let devices = topology.devices(on: network.id)
            guard routers.count == 1, devices.count >= 3 else { continue }
            findings.append(
                Finding(
                    id: "mesh.single-router.\(network.id)",
                    severity: .low,
                    category: .meshHealth,
                    title: "\(network.displayName) has one border router for \(devices.count) devices",
                    detail: "Only \(routers[0].displayName) is serving this network.",
                    impact: "Every Thread device here reaches the rest of your home through that one box. If it reboots or loses power, all \(devices.count) go dark until it comes back — and devices far from it have no alternate path.",
                    remediation: "Any HomePod mini, Apple TV 4K (Wi-Fi + Ethernet), or recent Nest hub adds a second border router just by being plugged in.",
                    subjects: [routers[0].displayName],
                    evidence: nil
                )
            )
        }
        return findings
    }

    /// The Thread leader should be stable. A leader that keeps moving means the
    /// mesh keeps re-forming.
    private func leaderChurn(_ history: [ScanSnapshot]) -> [Finding] {
        let recent = Array(history.prefix(10))
        guard recent.count >= 4 else { return [] }

        var byNetwork: [String: [String]] = [:]
        // Oldest first so the sequence reads forwards.
        for snapshot in recent.reversed() {
            for network in snapshot.topology.networks {
                guard let leader = snapshot.topology.borderRouters(on: network.id).first(where: \.isLeader) else { continue }
                byNetwork[network.id, default: []].append(leader.id)
            }
        }

        return byNetwork.compactMap { networkID, leaders in
            let changes = zip(leaders, leaders.dropFirst()).filter { pair in pair.0 != pair.1 }.count
            guard changes >= 2 else { return nil }
            return Finding(
                id: "mesh.leader-churn.\(networkID)",
                severity: .medium,
                category: .meshHealth,
                title: "Thread leader changed \(changes) times in the last \(leaders.count) scans",
                detail: "The leader role moved between routers repeatedly.",
                impact: "The leader assigns router IDs and holds the network's configuration. A leader that keeps changing means routers are repeatedly losing contact and re-electing — the usual cause of Thread devices that drop out and come back for no visible reason.",
                remediation: "Look for a router that's marginal on range or intermittently powered. Moving one border router closer to the others often settles it.",
                subjects: [],
                evidence: "Leader role from MeshCoP `sb` bits 9–10 across \(leaders.count) stored scans."
            )
        }
    }

    // MARK: - Coverage

    /// The single most useful thing history buys you.
    private func missingDevices(_ ledger: DeviceLedger, topology: Topology) -> [Finding] {
        let present = Set(topology.devices.map(\.stableKey))
        let missing = ledger.entries.values
            .filter { !present.contains($0.key) && $0.scanCount >= 2 }
            .sorted { $0.lastSeen > $1.lastSeen }
        guard !missing.isEmpty else { return [] }

        let described = missing.prefix(8).map { entry in
            "\(entry.displayName) (last seen \(entry.lastSeen.formatted(.relative(presentation: .named))))"
        }
        let stale = missing.filter { $0.lastSeen < Date.now.addingTimeInterval(-72 * 3600) }

        return [
            Finding(
                id: "coverage.missing-devices",
                severity: stale.isEmpty ? .low : .medium,
                category: .coverage,
                title: "\(missing.count) device\(missing.count == 1 ? "" : "s") seen before \(missing.count == 1 ? "is" : "are") missing now",
                detail: described.joined(separator: ", ") + (missing.count > 8 ? ", and \(missing.count - 8) more." : "."),
                impact: stale.isEmpty
                    ? "They were here on an earlier scan and didn't answer this one. Sleepy battery devices legitimately miss scans, so treat a single absence as noise."
                    : "\(stale.count) of them haven't answered in over three days, which is longer than a sleepy device's polling interval. That usually means a flat battery, a device out of range, or one that's been removed.",
                remediation: "Run a longer scan first to rule out a sleepy device that was between wake-ups. If it stays missing, check the battery.",
                subjects: missing.map(\.displayName),
                evidence: "Absent from the current scan; present in \(missing.map(\.scanCount).max() ?? 0) earlier scans."
            )
        ]
    }

    private func unreachableAccessories(_ topology: Topology) -> [Finding] {
        let unreachable = topology.accessories.filter { !$0.isReachable }
        guard !unreachable.isEmpty else { return [] }
        return [
            Finding(
                id: "hygiene.unreachable",
                severity: .low,
                category: .hygiene,
                title: "\(unreachable.count) HomeKit accessory\(unreachable.count == 1 ? " is" : "s are") not responding",
                detail: "\(list(unreachable.map(\.name))) are in your home but HomeKit can't reach them.",
                impact: "HomeKit and the network agree these are offline, so this isn't a discovery artefact.",
                remediation: "Check power and range. If an accessory has been unreachable for a while, remove it from the Home app rather than leaving a dead entry behind.",
                subjects: unreachable.map(\.name),
                evidence: "HMAccessory.isReachable is false."
            )
        ]
    }

    // MARK: - Helpers

    /// "A", "A and B", "A, B and C", "A, B, C and 4 others".
    private func list(_ items: [String], limit: Int = 4) -> String {
        guard !items.isEmpty else { return "none" }
        if items.count == 1 { return items[0] }
        if items.count <= limit {
            return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
        return items.prefix(limit).joined(separator: ", ") + " and \(items.count - limit) others"
    }
}
