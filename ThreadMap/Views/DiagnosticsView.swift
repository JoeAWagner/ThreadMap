import SwiftUI

/// Raw evidence. Everything the map claims is derived from what's shown here,
/// so this screen is what you check when a placement looks wrong.
struct DiagnosticsView: View {
    let topology: Topology
    let notices: [ScannerModel.Notice]
    let lastScanDate: Date?

    var body: some View {
        List {
            if !notices.isEmpty {
                Section("Notices") {
                    ForEach(notices) { notice in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(notice.title,
                                  systemImage: notice.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(notice.severity == .warning ? .orange : .secondary)
                            Text(notice.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Summary") {
                LabeledContent("Thread networks", value: "\(topology.networks.count)")
                LabeledContent("Border routers", value: "\(topology.borderRouters.count)")
                LabeledContent("Thread devices", value: "\(topology.threadDevices.count)")
                LabeledContent("IP devices", value: "\(topology.offMeshDevices.count)")
                LabeledContent("HomeKit accessories", value: "\(topology.accessories.count)")
                if let lastScanDate {
                    LabeledContent("Last scan", value: lastScanDate.formatted(date: .omitted, time: .standard))
                }
            }

            Section {
                Text("""
                What this app can see: border routers announce themselves over Wi-Fi with a MeshCoP record naming their Thread network, and border routers republish their Thread devices' service records onto Wi-Fi. That's how devices appear here at all.

                It can also see which border router answers mDNS for a given device, which identifies the router holding that device's service registration. That's a real device-to-router relationship, and the closest thing available — but it is not the device's mesh parent.

                What no iOS app can see: the mesh links inside a Thread network — which device is a router or an end device, which parent it attached to, link quality, hop count, or the neighbour table. Those live inside the border router and Apple's private daemons, and there is no public API for them.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("Scope")
            }

            if !topology.advertisedServiceTypes.isEmpty {
                let unrecognised = ServiceTypeEnumerator.unrecognised(Set(topology.advertisedServiceTypes))
                Section {
                    ForEach(topology.advertisedServiceTypes, id: \.self) { type in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(type).font(.system(.footnote, design: .monospaced))
                                if ServiceTypeEnumerator.isNoteworthy(type) {
                                    Tag(text: "Remote access", color: .orange)
                                } else if !unrecognised.contains(type) {
                                    Tag(text: "Inspected", color: .green)
                                }
                            }
                            if let note = ServiceTypeEnumerator.annotation(for: type) {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Service types on this network (\(topology.advertisedServiceTypes.count))")
                } footer: {
                    Text("Found by browsing _services._dns-sd._udp, the DNS-SD meta-query — it returns the service types in use rather than instances of a type you already guessed. \(unrecognised.count) of these aren't inspected by this app. Anything you don't recognise is worth chasing down.")
                }
            }

            if let note = topology.proxyProbeNote {
                Section("Proxy attribution") {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !topology.unmatchedRecords.isEmpty {
                Section("Unclassified records (\(topology.unmatchedRecords.count))") {
                    ForEach(topology.unmatchedRecords) { record in
                        RawRecordRow(record: record)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}

struct RawRecordRow: View {
    let record: ServiceRecord

    var body: some View {
        DisclosureGroup {
            if let hostname = record.hostname {
                LabeledContent("Host", value: hostname).font(.footnote)
            }
            LabeledContent("Port", value: "\(record.port)").font(.footnote)
            ForEach(record.txt.keys.sorted(), id: \.self) { key in
                LabeledContent(key, value: display(record.txt[key] ?? Data()))
                    .font(.system(.caption, design: .monospaced))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.instanceName).font(.subheadline)
                Text(record.type.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Thread packs binary into TXT values, so fall back to hex when the bytes
    /// aren't printable rather than showing mojibake.
    private func display(_ data: Data) -> String {
        if data.isEmpty { return "(empty)" }
        if let text = String(data: data, encoding: .utf8),
           text.allSatisfy({ $0.isASCII && !$0.isNewline && $0.asciiValue.map { $0 >= 32 } == true }) {
            return text
        }
        return "0x" + data.map { String(format: "%02X", $0) }.joined()
    }
}
