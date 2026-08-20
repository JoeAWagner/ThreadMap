import SwiftUI

/// The live event log: what the house actually did, in order.
struct ActivityView: View {
    let log: HomeKitEventLog
    let onStart: () async -> Void
    let onStop: () async -> Void

    @State private var showTelemetry = false
    @State private var query = ""
    @State private var isWorking = false

    var body: some View {
        List {
            Section {
                statusRow
            } footer: {
                Text("HomeKit has no background delivery for third-party apps, so events arrive only while this app is open. Left running on a spare device it records continuously; on your phone it captures what happens while you're watching.")
            }

            if log.events.isEmpty {
                ContentUnavailableView("No events yet",
                                       systemImage: "waveform.path.ecg",
                                       description: Text(log.isMonitoring
                                        ? "Watching. Flip a switch or open a door to see it land here."
                                        : "Start monitoring to record state changes."))
            } else {
                ForEach(groupedByDay, id: \.key) { day, events in
                    Section(day) {
                        ForEach(events) { EventRow(event: $0) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search accessories, rooms, values")
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show sensor readings", isOn: $showTelemetry)
                    Button("Clear log", role: .destructive) { log.clear() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var statusRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(log.isMonitoring ? "Monitoring" : "Not monitoring",
                      systemImage: log.isMonitoring ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .font(.subheadline)
                    .foregroundStyle(log.isMonitoring ? .green : .secondary)
                if log.isMonitoring {
                    Text("\(log.subscribedCharacteristics) characteristics subscribed")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let error = log.lastError {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(log.isMonitoring ? "Stop" : "Start") {
                Task {
                    isWorking = true
                    if log.isMonitoring { await onStop() } else { await onStart() }
                    isWorking = false
                }
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
        }
    }

    /// Sensor telemetry is hidden by default — a handful of thermometers would
    /// otherwise bury every door and switch in the list.
    private var filtered: [HomeEvent] {
        log.events.filter { event in
            guard showTelemetry || event.isStateChange else { return false }
            guard !query.isEmpty else { return true }
            return [event.accessoryName, event.roomName ?? "", event.serviceName,
                    event.characteristicName, event.value]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedByDay: [(key: String, value: [HomeEvent])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        let grouped = Dictionary(grouping: filtered) { formatter.string(from: $0.date) }
        // `filtered` is already newest-first, so each group keeps that order and
        // the day keys just need sorting by their first event.
        return grouped
            .sorted { ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast) }
            .map { ($0.key, $0.value) }
    }
}

struct EventRow: View {
    let event: HomeEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.date, format: .dateTime.hour().minute().second())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.accessoryName).font(.subheadline)
                Text(event.summary).font(.caption).foregroundStyle(.primary)
                if let room = event.roomName {
                    Text("\(room) · \(event.serviceName)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
