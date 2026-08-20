import SwiftUI

struct RootView: View {
    @State private var model = ScannerModel()
    @State private var selection: MapSelection?
    @State private var tab: Tab = .map
    @State private var showSettings = false

    enum Tab: Hashable { case map, inventory, health, activity, diagnostics }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { mapTab }
                .tabItem { Label("Map", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(Tab.map)

            NavigationStack {
                InventoryView(topology: model.topology)
                    .navigationTitle("Devices")
                    .toolbar { scanButton }
            }
            .tabItem { Label("Devices", systemImage: "list.bullet") }
            .tag(Tab.inventory)

            NavigationStack {
                HealthView(findings: model.findings,
                           changes: model.changes,
                           ledger: model.ledger,
                           topology: model.topology,
                           snapshots: model.snapshots,
                           onClearHistory: { await model.clearHistory() })
                    .toolbar { scanButton }
            }
            .tabItem { Label("Health", systemImage: "checkmark.shield") }
            .tag(Tab.health)
            .badge(model.findings.actionableCount)

            NavigationStack {
                ActivityView(log: model.eventLog,
                             onStart: { await model.startEventLog() },
                             onStop: { await model.stopEventLog() })
            }
            .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }
            .tag(Tab.activity)

            NavigationStack {
                DiagnosticsView(topology: model.topology,
                                notices: model.notices,
                                lastScanDate: model.lastScanDate)
                    .toolbar { scanButton }
            }
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            .tag(Tab.diagnostics)
        }
        .task {
            await model.loadHistory()
            if !model.hasScannedOnce { model.scan() }
        }
        .sheet(isPresented: $showSettings) {
            ScanSettingsView(model: model)
                .presentationDetents([.medium])
        }
    }

    private var mapTab: some View {
        ZStack {
            MapView(topology: model.topology, selection: $selection)

            if model.isScanning {
                ScanOverlay(phase: model.phase).transition(.opacity)
            } else if !model.hasScannedOnce && model.topology.isEmpty {
                ContentUnavailableView {
                    Label("No scan yet", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Find the Thread border routers on your Wi-Fi and the devices behind them.")
                } actions: {
                    Button("Scan") { model.scan() }.buttonStyle(.borderedProminent)
                }
                .background(.regularMaterial)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isScanning)
        .navigationTitle("Thread Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Scan settings")
            }
            scanButton
        }
        .sheet(item: $selection) { selection in
            SelectionDetailView(selection: selection, topology: model.topology)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ToolbarContentBuilder
    private var scanButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.isScanning ? model.cancel() : model.scan()
            } label: {
                Image(systemName: model.isScanning ? "stop.circle" : "arrow.clockwise")
            }
            .accessibilityLabel(model.isScanning ? "Stop scanning" : "Scan again")
        }
    }
}

/// Scan depth is a real tradeoff — a longer browse finds sleepy devices, and
/// the deep probes need entitlements not every build has — so it's exposed
/// rather than guessed at.
struct ScanSettingsView: View {
    @Bindable var model: ScannerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Browse window")
                            Spacer()
                            Text("\(Int(model.browseDuration))s").foregroundStyle(.secondary)
                        }
                        Slider(value: $model.browseDuration, in: 2...20, step: 1)
                    }
                } footer: {
                    Text("Battery-powered Thread devices wake only every few seconds. A short scan will miss them and report them as gone — 10 seconds or more before you trust a disappearance.")
                }

                Section {
                    Toggle("Attribute devices to routers", isOn: $model.proxyProbeEnabled)
                } footer: {
                    Text("Sends mDNS queries directly and records which border router answers for each device. Needs the multicast entitlement; turns itself off cleanly without it.")
                }

                Section {
                    Toggle("Enumerate all service types", isOn: $model.serviceTypeEnumerationEnabled)
                } footer: {
                    Text("Asks the network what service types are advertised, including ones this app doesn't inspect. Useful for spotting something you didn't put there.")
                }

                Section {
                    Toggle("Search for UPnP devices", isOn: $model.ssdpEnabled)
                } footer: {
                    Text("SSDP is a different protocol from Bonjour, on a different multicast group. Sonos, Roku, Wemo, smart TVs and printers often announce only there. Also needs the multicast entitlement.")
                }
            }
            .navigationTitle("Scan settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ScanOverlay: View {
    let phase: ScannerModel.Phase

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(phase.label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
