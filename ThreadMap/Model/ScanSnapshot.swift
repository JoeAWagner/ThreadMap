import Foundation

/// One scan, frozen, for history and diffing.
struct ScanSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    var topology: Topology
    var findings: [Finding]
    /// How long the browse window was, since a short scan legitimately finds
    /// fewer sleepy devices and shouldn't be read as devices going missing.
    var browseDuration: TimeInterval

    init(id: UUID = UUID(), date: Date = .now, topology: Topology,
         findings: [Finding] = [], browseDuration: TimeInterval) {
        self.id = id
        self.date = date
        self.topology = topology
        self.findings = findings
        self.browseDuration = browseDuration
    }

    var summary: String {
        "\(topology.borderRouters.count) routers · \(topology.threadDevices.count) Thread · \(topology.offMeshDevices.count) IP"
    }
}
