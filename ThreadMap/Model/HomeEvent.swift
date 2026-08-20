import Foundation

/// One characteristic change, as it happened.
///
/// Together these form something no smart-home app really offers: an ordered,
/// timestamped record of what your house actually did, rather than what its
/// current state is.
struct HomeEvent: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var date: Date
    var accessoryName: String
    var accessoryID: UUID
    var roomName: String?
    var serviceName: String
    /// Localised characteristic name, e.g. "Power State", "Current Position".
    var characteristicName: String
    /// The HomeKit characteristic type UUID string, for filtering.
    var characteristicType: String
    /// Rendered value, units included.
    var value: String
    /// Previous rendered value, when we had one.
    var previousValue: String?
    /// Discrete states (on/off, locked/unlocked, open/closed) read as events;
    /// continuously varying sensor readings are telemetry and get filtered out
    /// of the default view so they don't bury the things that matter.
    var isStateChange: Bool

    init(id: UUID = UUID(), date: Date = .now, accessoryName: String, accessoryID: UUID,
         roomName: String?, serviceName: String, characteristicName: String,
         characteristicType: String, value: String, previousValue: String?, isStateChange: Bool) {
        self.id = id
        self.date = date
        self.accessoryName = accessoryName
        self.accessoryID = accessoryID
        self.roomName = roomName
        self.serviceName = serviceName
        self.characteristicName = characteristicName
        self.characteristicType = characteristicType
        self.value = value
        self.previousValue = previousValue
        self.isStateChange = isStateChange
    }

    var summary: String {
        if let previousValue, previousValue != value {
            return "\(characteristicName): \(previousValue) → \(value)"
        }
        return "\(characteristicName): \(value)"
    }
}
