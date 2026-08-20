import SwiftUI

/// Findings and changes — what's worth acting on, and what moved since last time.
struct HealthView: View {
    let findings: [Finding]
    let changes: [TopologyChange]
    let ledger: DeviceLedger
    let topology: Topology
    let snapshots: [ScanSnapshot]
    let onClearHistory: () async -> Void

    @State private var tab: Tab = .findings
    @State private var confirmClear = false

    enum Tab: String, CaseIterable, Identifiable {
        case findings = "Findings"
        case changes = "Changes"
        case timeline = "Timeline"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            switch tab {
            case .findings: findingsList
            case .changes:  changesList
            case .timeline: timelineList
            }
        }
        .navigationTitle("Health")
        .safeAreaInset(edge: .top) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }

    // MARK: - Findings

    private var findingsList: some View {
        List {
            if findings.isEmpty {
                ContentUnavailableView("Nothing flagged",
                                       systemImage: "checkmark.shield",
                                       description: Text("No exposure, mesh-health, or coverage issues in the last scan."))
            }

            ForEach(Finding.Category.allCases, id: \.self) { category in
                let matching = findings.filter { $0.category == category }
                if !matching.isEmpty {
                    Section(category.rawValue) {
                        ForEach(matching) { FindingRow(finding: $0) }
                    }
                }
            }
        }
    }

    // MARK: - Changes

    private var changesList: some View {
        List {
            if changes.isEmpty {
                ContentUnavailableView("No changes",
                                       systemImage: "equal.circle",
                                       description: Text(snapshots.count < 2
                                        ? "Changes appear once there are two scans to compare."
                                        : "Nothing moved since the previous scan."))
            }

            let noteworthy = changes.filter(\.kind.isNoteworthy)
            let routine = changes.filter { !$0.kind.isNoteworthy }

            if !noteworthy.isEmpty {
                Section("Worth a look") {
                    ForEach(noteworthy) { ChangeRow(change: $0) }
                }
            }
            if !routine.isEmpty {
                Section("Routine") {
                    ForEach(routine) { ChangeRow(change: $0) }
                }
            }
        }
    }

    // MARK: - Timeline

    private var timelineList: some View {
        List {
            Section {
                Text("Every device ever seen, with when it was first and last found. This is what makes \"stopped working sometime last week\" answerable.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            let missing = ledger.missing(from: topology)
            if !missing.isEmpty {
                Section("Not in the current scan (\(missing.count))") {
                    ForEach(missing) { LedgerRow(entry: $0, isPresent: false) }
                }
            }

            let present = ledger.entries.values
                .filter { entry in topology.devices.contains { $0.stableKey == entry.key } }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if !present.isEmpty {
                Section("Present (\(present.count))") {
                    ForEach(present) { LedgerRow(entry: $0, isPresent: true) }
                }
            }

            Section("Stored scans (\(snapshots.count))") {
                ForEach(snapshots.prefix(12)) { snapshot in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                        Text(snapshot.summary).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("Clear history", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("Delete all stored scans?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await onClearHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved scan and the device history. Findings that depend on history — missing devices, leader churn — will go quiet until enough new scans build up.")
        }
    }
}

// MARK: - Rows

struct FindingRow: View {
    let finding: Finding
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                labelled("What was seen", finding.detail)
                if let impact = finding.impact { labelled("Why it matters", impact) }
                if let remediation = finding.remediation { labelled("What to do", remediation) }
                if let evidence = finding.evidence {
                    labelled("Evidence", evidence, monospaced: true)
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.severity.symbolName)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).font(.subheadline)
                    Text(finding.severity.label).font(.caption2).foregroundStyle(tint)
                }
            }
        }
    }

    private func labelled(_ title: String, _ body: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(monospaced ? .system(.caption, design: .monospaced) : .footnote)
                .foregroundStyle(monospaced ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color {
        switch finding.severity {
        case .high:   .red
        case .medium: .orange
        case .low:    .yellow
        case .info:   .secondary
        }
    }
}

struct ChangeRow: View {
    let change: TopologyChange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: change.kind.symbolName)
                .foregroundStyle(change.kind.isNoteworthy ? .orange : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(change.subject) \(change.summary)").font(.subheadline)
                if let detail = change.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct LedgerRow: View {
    let entry: DeviceLedger.Entry
    let isPresent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.displayName)
                Spacer()
                if !isPresent {
                    Text(entry.lastSeen, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(isStale ? .orange : .secondary)
                }
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var isStale: Bool { entry.lastSeen < Date.now.addingTimeInterval(-72 * 3600) }

    private var subtitle: String {
        var parts = [entry.kind]
        if let network = entry.lastKnownNetworkName { parts.append(network) }
        parts.append("seen in \(entry.scanCount) scan\(entry.scanCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}
