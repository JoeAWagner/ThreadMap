import Foundation
import HomeKit
import Observation

/// Subscribes to every notifying characteristic in the home and records changes.
///
/// **Limitation worth stating plainly:** HomeKit has no background delivery mode
/// for third-party apps. Characteristic notifications arrive while this app is
/// running and stop when iOS suspends it, so this is a live monitor, not a
/// black-box recorder. Left in the foreground on a spare iPad or a Mac
/// Catalyst build it works continuously; on your phone it captures whatever
/// happens while you're watching.
@MainActor
@Observable
final class HomeKitEventLog {

    private(set) var events: [HomeEvent] = []
    private(set) var isMonitoring = false
    private(set) var subscribedCharacteristics = 0
    private(set) var lastError: String?

    /// Bounded so a long-running session can't grow without limit.
    private let maximumEvents = 3_000
    /// A busy home can emit dozens of updates a second; rewriting the whole log
    /// each time would thrash the disk for no benefit.
    private let persistInterval: TimeInterval = 5
    private var lastPersist: Date = .distantPast
    private var persistPending = false

    private var manager: HMHomeManager?
    private var observer: AccessoryObserver?
    private var lastValues: [String: String] = [:]
    private var accessoryIndex: [ObjectIdentifier: (id: UUID, name: String, room: String?)] = [:]
    private let storeURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        storeURL = base.appendingPathComponent("ThreadMap/events.json", isDirectory: false)
        events = Self.load(from: storeURL)
    }

    // MARK: - Control

    func start(using manager: HMHomeManager) async {
        guard !isMonitoring else { return }
        self.manager = manager

        let observer = AccessoryObserver()
        observer.onUpdate = { [weak self] accessory, service, characteristic in
            Task { @MainActor in
                self?.record(accessory: accessory, service: service, characteristic: characteristic)
            }
        }
        self.observer = observer

        var subscribed = 0
        for home in manager.homes {
            for accessory in home.accessories {
                accessory.delegate = observer
                accessoryIndex[ObjectIdentifier(accessory)] = (
                    accessory.uniqueIdentifier, accessory.name, accessory.room?.name
                )
                for service in accessory.services {
                    for characteristic in service.characteristics where Self.supportsNotification(characteristic) {
                        do {
                            try await characteristic.enableNotification(true)
                            subscribed += 1
                        } catch {
                            // An accessory that's offline or refuses the
                            // subscription shouldn't stop the other 200.
                            continue
                        }
                    }
                }
            }
        }

        subscribedCharacteristics = subscribed
        isMonitoring = subscribed > 0
        if subscribed == 0 {
            lastError = "No accessories accepted an event subscription. That usually means HomeKit access is off, or nothing in this home reports state changes."
        }
    }

    func stop() async {
        guard let manager else { return }
        for home in manager.homes {
            for accessory in home.accessories {
                accessory.delegate = nil
                for service in accessory.services {
                    for characteristic in service.characteristics where Self.supportsNotification(characteristic) {
                        try? await characteristic.enableNotification(false)
                    }
                }
            }
        }
        isMonitoring = false
        subscribedCharacteristics = 0
        observer = nil
    }

    func clear() {
        events.removeAll()
        lastValues.removeAll()
        persist(force: true)
    }

    // MARK: - Recording

    private func record(accessory: HMAccessory, service: HMService, characteristic: HMCharacteristic) {
        let identity = accessoryIndex[ObjectIdentifier(accessory)]
            ?? (accessory.uniqueIdentifier, accessory.name, accessory.room?.name)

        let rendered = Self.render(characteristic)
        let key = "\(identity.id.uuidString)|\(characteristic.uniqueIdentifier.uuidString)"
        let previous = lastValues[key]

        // HomeKit re-delivers the same value on reconnects; a repeat isn't an event.
        guard previous != rendered else { return }
        lastValues[key] = rendered

        let event = HomeEvent(
            accessoryName: identity.name,
            accessoryID: identity.id,
            roomName: identity.room,
            serviceName: service.name,
            characteristicName: characteristic.localizedDescription,
            characteristicType: characteristic.characteristicType,
            value: rendered,
            previousValue: previous,
            isStateChange: Self.isDiscreteState(characteristic)
        )

        events.insert(event, at: 0)
        if events.count > maximumEvents { events.removeLast(events.count - maximumEvents) }
        persist()
    }

    // MARK: - Characteristic helpers

    private static func supportsNotification(_ characteristic: HMCharacteristic) -> Bool {
        characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification)
    }

    /// Booleans and enumerated states are events; a temperature that drifts by
    /// 0.1° every thirty seconds is telemetry.
    private static func isDiscreteState(_ characteristic: HMCharacteristic) -> Bool {
        if characteristic.value is Bool { return true }
        guard let format = characteristic.metadata?.format else { return false }
        switch format {
        case HMCharacteristicMetadataFormatBool, HMCharacteristicMetadataFormatString:
            return true
        case HMCharacteristicMetadataFormatUInt8:
            // Small unsigned ranges are enumerations — lock state, door state,
            // security system target state.
            if let max = characteristic.metadata?.maximumValue?.doubleValue, max <= 4 { return true }
            return false
        default:
            return false
        }
    }

    private static func render(_ characteristic: HMCharacteristic) -> String {
        guard let value = characteristic.value else { return "—" }

        if let flag = value as? Bool { return flag ? "On" : "Off" }
        if let number = value as? NSNumber {
            let units = unitSuffix(characteristic.metadata?.units)
            if characteristic.metadata?.format == HMCharacteristicMetadataFormatBool {
                return number.boolValue ? "On" : "Off"
            }
            let double = number.doubleValue
            let text = double == double.rounded()
                ? String(Int(double))
                : String(format: "%.1f", double)
            return units.isEmpty ? text : "\(text)\(units)"
        }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    private static func unitSuffix(_ units: String?) -> String {
        switch units ?? "" {
        case HMCharacteristicMetadataUnitsCelsius:    "°C"
        case HMCharacteristicMetadataUnitsFahrenheit: "°F"
        case HMCharacteristicMetadataUnitsPercentage: "%"
        case HMCharacteristicMetadataUnitsArcDegree:  "°"
        case HMCharacteristicMetadataUnitsSeconds:    " s"
        case HMCharacteristicMetadataUnitsLux:        " lx"
        default: ""
        }
    }

    // MARK: - Persistence

    private func persist(force: Bool = false) {
        guard force || Date.now.timeIntervalSince(lastPersist) >= persistInterval else {
            schedulePersist()
            return
        }
        lastPersist = .now
        persistPending = false
        let snapshot = Array(events.prefix(maximumEvents))
        let url = storeURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                print("HomeKitEventLog: could not persist events — \(error.localizedDescription)")
            }
        }
    }

    /// Make sure a trailing burst still reaches disk once it goes quiet.
    private func schedulePersist() {
        guard !persistPending else { return }
        persistPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.persist(force: true)
        }
    }

    private static func load(from url: URL) -> [HomeEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let events = try? decoder.decode([HomeEvent].self, from: data)
        else { return [] }
        return events
    }
}

/// Un-isolated delegate shim, for the same reason `HomeKitService` uses one.
private final class AccessoryObserver: NSObject, HMAccessoryDelegate, @unchecked Sendable {
    var onUpdate: ((HMAccessory, HMService, HMCharacteristic) -> Void)?

    func accessory(_ accessory: HMAccessory, service: HMService,
                   didUpdateValueFor characteristic: HMCharacteristic) {
        onUpdate?(accessory, service, characteristic)
    }
}
