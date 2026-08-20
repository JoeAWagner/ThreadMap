import Foundation
import Observation

/// Drives a scan, owns the resulting topology, and keeps the history that turns
/// a snapshot into a trend.
@MainActor
@Observable
final class ScannerModel {

    enum Phase: Equatable {
        case idle
        case browsing
        case enumeratingServiceTypes
        case probingProxies
        case readingThreadCredentials
        case readingHomeKit
        case correlating
        case auditing

        var label: String {
            switch self {
            case .idle:                     "Ready"
            case .browsing:                 "Listening for Thread border routers…"
            case .enumeratingServiceTypes:  "Asking what else is on this network…"
            case .probingProxies:           "Finding out which router answers for each device…"
            case .readingThreadCredentials: "Reading stored Thread networks…"
            case .readingHomeKit:           "Reading your HomeKit homes…"
            case .correlating:              "Matching devices to networks…"
            case .auditing:                 "Checking posture and comparing with the last scan…"
            }
        }
    }

    struct Notice: Identifiable, Hashable {
        enum Severity { case info, warning }
        let id = UUID()
        var severity: Severity
        var title: String
        var detail: String
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle
    private(set) var topology = Topology()
    private(set) var findings: [Finding] = []
    private(set) var changes: [TopologyChange] = []
    private(set) var ledger = DeviceLedger()
    private(set) var snapshots: [ScanSnapshot] = []
    private(set) var notices: [Notice] = []
    private(set) var lastScanDate: Date?
    private(set) var hasScannedOnce = false

    let eventLog = HomeKitEventLog()

    var isScanning: Bool { phase != .idle }

    /// Longer browse windows find more sleepy devices, which only wake every
    /// few seconds, at the cost of a slower scan.
    var browseDuration: TimeInterval = 5.0
    /// Raw multicast probing needs an entitlement not every build will have, so
    /// it's separately switchable and fails soft.
    var proxyProbeEnabled = true
    var serviceTypeEnumerationEnabled = true

    // MARK: - Collaborators

    private let scanner = BonjourScanner()
    private let credentials = ThreadCredentialsService()
    private let homeKit = HomeKitService()
    private let builder = TopologyBuilder()
    private let auditor = PostureAuditor()
    private let differ = TopologyDiffer()
    private let prober = MulticastProber()
    private let typeEnumerator = ServiceTypeEnumerator()
    private let history = ScanHistoryStore()
    private var scanTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Pull history off disk before the first scan so the very first result can
    /// already say what changed.
    func loadHistory() async {
        snapshots = await history.loadSnapshots()
        ledger = await history.loadLedger()
        if let latest = snapshots.first, !hasScannedOnce {
            topology = latest.topology
            findings = latest.findings
            lastScanDate = latest.date
        }
    }

    func scan() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            await self?.runScan()
            self?.scanTask = nil
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
    }

    func clearHistory() async {
        await history.deleteAll()
        snapshots = []
        ledger = DeviceLedger()
        changes = []
    }

    // MARK: - The scan

    private func runScan() async {
        notices.removeAll()
        let previous = snapshots.first

        // 1. Browse every service type we know about.
        phase = .browsing
        let scan = await scanner.scan(browseDuration: browseDuration)
        for issue in scan.issues {
            notices.append(Notice(severity: .warning, title: "Discovery problem", detail: issue.message))
        }
        guard !Task.isCancelled else { return finish(.idle) }

        // 2. Ask the network what else it's advertising.
        var advertisedTypes: Set<String> = []
        if serviceTypeEnumerationEnabled {
            phase = .enumeratingServiceTypes
            advertisedTypes = await typeEnumerator.enumerate()
        }
        guard !Task.isCancelled else { return finish(.idle) }

        // 3. Find out who answers mDNS for the Thread devices.
        var attribution = MulticastProber.Attribution()
        if proxyProbeEnabled {
            phase = .probingProxies
            attribution = await prober.probe()
            if let reason = attribution.failureReason {
                notices.append(
                    Notice(severity: .info, title: "Proxy attribution unavailable", detail: reason)
                )
            }
        }
        guard !Task.isCancelled else { return finish(.idle) }

        // 4. Stored Thread networks, for naming.
        phase = .readingThreadCredentials
        var knownNetworks: [ThreadCredentialsService.KnownNetwork] = []
        do {
            knownNetworks = try await credentials.knownNetworks()
        } catch {
            notices.append(
                Notice(severity: .info,
                       title: "Thread network names unavailable",
                       detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            )
        }
        guard !Task.isCancelled else { return finish(.idle) }

        // 5. HomeKit, for names and rooms.
        phase = .readingHomeKit
        let (accessories, authorization) = await homeKit.loadAccessories()
        if !authorization.isUsable {
            notices.append(
                Notice(severity: .warning,
                       title: "HomeKit access is off",
                       detail: "Without it, Thread devices show up as bare Matter node IDs instead of the names you gave them. Turn it on in Settings › Privacy & Security › HomeKit.")
            )
        }
        guard !Task.isCancelled else { return finish(.idle) }

        // 6. Correlate.
        phase = .correlating
        topology = builder.build(
            TopologyBuilder.Input(
                records: scan.records,
                knownNetworks: knownNetworks,
                accessories: accessories,
                proxyAttribution: attribution.responders,
                proxyProbeNote: attribution.failureReason,
                advertisedServiceTypes: advertisedTypes
            )
        )

        // 7. Audit, diff, and persist.
        phase = .auditing
        let scanDate = Date.now
        ledger.record(topology, at: scanDate)
        ledger.prune(now: scanDate)

        findings = auditor.audit(
            PostureAuditor.Input(topology: topology, history: snapshots, ledger: ledger)
        )

        let snapshot = ScanSnapshot(date: scanDate, topology: topology,
                                    findings: findings, browseDuration: browseDuration)
        changes = previous.map { differ.diff(from: $0, to: snapshot) } ?? []

        await history.save(snapshot)
        await history.save(ledger)
        snapshots.insert(snapshot, at: 0)

        addInterpretationNotices()
        lastScanDate = scanDate
        hasScannedOnce = true
        finish(.idle)
    }

    private func finish(_ phase: Phase) {
        self.phase = phase
    }

    // MARK: - Event log

    func startEventLog() async {
        let manager = await homeKit.loadedManager()
        await eventLog.start(using: manager)
    }

    func stopEventLog() async {
        await eventLog.stop()
    }

    // MARK: - Notices

    /// Explains the map's blind spots in place, rather than letting the user
    /// assume an empty area means "nothing there".
    private func addInterpretationNotices() {
        if topology.borderRouters.isEmpty {
            notices.append(
                Notice(severity: .warning,
                       title: "No Thread border routers found",
                       detail: "Border routers announce themselves over Wi-Fi. Make sure this iPhone is on the same Wi-Fi network (not cellular, not a guest VLAN) as your HomePods, Apple TVs, or hubs.")
            )
        }

        let unplaced = topology.threadDevices.filter { $0.networkID.value == nil }
        if !unplaced.isEmpty {
            notices.append(
                Notice(severity: .info,
                       title: "\(unplaced.count) Thread \(unplaced.count == 1 ? "device" : "devices") not placed",
                       detail: "Their addresses don't fall inside any prefix a border router advertises. This is normal for older (Thread 1.3) border routers, which don't publish their routable prefix.")
            )
        }

        let attributed = topology.devices.filter { !$0.proxiedBy.isEmpty }.count
        if attributed > 0 {
            notices.append(
                Notice(severity: .info,
                       title: "\(attributed) device\(attributed == 1 ? "" : "s") attributed to a border router",
                       detail: "A border router answered mDNS on their behalf, so it holds their service registration. That is not the same as being their mesh parent — iOS exposes no API for mesh parentage — but it is a real, observed device-to-router link.")
            )
        }

        let unknownTypes = ServiceTypeEnumerator.unrecognised(Set(topology.advertisedServiceTypes))
        if !unknownTypes.isEmpty {
            let notable = unknownTypes.filter(ServiceTypeEnumerator.isNoteworthy)
            notices.append(
                Notice(severity: notable.isEmpty ? .info : .warning,
                       title: "\(unknownTypes.count) other service type\(unknownTypes.count == 1 ? "" : "s") on this network",
                       detail: notable.isEmpty
                        ? "Listed under Diagnostics. These aren't inspected by this app — they're here so you know what else is advertising."
                        : "Including \(notable.joined(separator: ", ")), which offer remote access. Worth confirming you know what they belong to.")
            )
        }
    }
}
