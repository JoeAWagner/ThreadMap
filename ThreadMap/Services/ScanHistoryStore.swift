import Foundation

/// Persists scans so the app can answer questions about time.
///
/// Snapshots go to Application Support as individual JSON files named by
/// timestamp, so a corrupt write costs one scan rather than the whole history.
/// The ledger is a single file because it's a running aggregate.
actor ScanHistoryStore {

    /// Enough history for leader-churn detection and a readable timeline
    /// without letting Application Support grow without bound.
    private let maximumSnapshots = 40

    private let directory: URL
    private let ledgerURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        directory = base.appendingPathComponent("ThreadMap/Scans", isDirectory: true)
        ledgerURL = base.appendingPathComponent("ThreadMap/ledger.json", isDirectory: false)
    }

    // MARK: - Snapshots

    /// Newest first.
    func loadSnapshots() -> [ScanSnapshot] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ScanSnapshot.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    func save(_ snapshot: ScanSnapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = String(format: "%.0f", snapshot.date.timeIntervalSince1970) + ".json"
            try encoder.encode(snapshot).write(to: directory.appendingPathComponent(name), options: .atomic)
            prune()
        } catch {
            // History is a convenience, not the product. A failed write must
            // never take a scan down with it.
            print("ScanHistoryStore: could not save snapshot — \(error.localizedDescription)")
        }
    }

    private func prune() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let jsonURLs = urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard jsonURLs.count > maximumSnapshots else { return }
        for url in jsonURLs.dropFirst(maximumSnapshots) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    // MARK: - Ledger

    func loadLedger() -> DeviceLedger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? decoder.decode(DeviceLedger.self, from: data)
        else { return DeviceLedger() }
        return ledger
    }

    func save(_ ledger: DeviceLedger) {
        do {
            try FileManager.default.createDirectory(
                at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        } catch {
            print("ScanHistoryStore: could not save ledger — \(error.localizedDescription)")
        }
    }
}
