import Foundation

/// A Thread network, identified by its extended PAN ID. Everything else —
/// border routers, devices, credentials — hangs off one of these.
struct ThreadNetwork: Identifiable, Hashable, Codable, Sendable {
    /// Extended PAN ID as 16 uppercase hex characters, or a synthetic ID when
    /// we know a network exists but never learned its XPAN.
    let id: String
    var name: String?
    var extendedPANID: String?
    var channel: UInt8?
    var panID: String?
    var threadVersion: String?
    /// True when the ThreadNetwork framework handed us stored credentials for
    /// this network (meaning this iPhone can commission onto it).
    var hasStoredCredentials: Bool = false
    var borderRouterIDs: [String] = []
    var deviceIDs: [String] = []
    /// OMR prefixes advertised by this network's border routers.
    var omrPrefixes: [IPv6Prefix] = []

    var isSynthetic: Bool { extendedPANID == nil }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let xp = extendedPANID { return "Thread network \(xp.prefix(4))…\(xp.suffix(4))" }
        return "Unidentified Thread network"
    }
}

/// A Thread Border Router: an Apple TV, HomePod, Nest/Echo hub, eero, or an
/// OpenThread box. Discovered purely from its own MeshCoP advertisement.
struct BorderRouter: Identifiable, Hashable, Codable, Sendable {
    /// Border agent ID when present, otherwise the service instance name.
    let id: String
    var displayName: String
    var vendorName: String?
    var modelName: String?
    var borderAgentID: String?
    var networkID: String?
    var addresses: [IPAddress] = []
    var hostname: String?
    var meshcop: MeshcopRecord?
    var advertisedTypes: Set<ServiceType> = []
    var lastSeen: Date = .now
    /// The HomeKit accessory we believe this hardware corresponds to, if any.
    var homeKitAccessoryID: UUID?
    /// Names this host publishes under other service types — an Apple TV's
    /// AirPlay name, a Nest hub's Cast name. A MeshCoP record alone often can't
    /// tell you which box in the house you're looking at; this can.
    var alternateNames: [String] = []
    /// Model string from a co-located `_device-info._tcp` record.
    var deviceInfoModel: String?

    var isLeader: Bool { meshcop?.threadRole == .leader }
    var isPrimaryBackboneRouter: Bool { meshcop?.isPrimaryBackboneRouter == true }
    var isAttached: Bool { meshcop?.interfaceStatus == .active }

    /// Vendor + model, e.g. "Apple Apple TV". Falls back to the instance name.
    var hardwareDescription: String {
        let parts = [vendorName, modelName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? displayName : parts.joined(separator: " ")
    }
}

/// Anything on the map that isn't a border router: a bulb, lock, sensor, plug.
struct MeshDevice: Identifiable, Hashable, Codable, Sendable {
    enum Transport: String, Hashable, Codable, Sendable {
        case thread, wifiOrEthernet, unknown

        var label: String {
            switch self {
            case .thread:         "Thread"
            case .wifiOrEthernet: "Wi-Fi / Ethernet"
            case .unknown:        "Unknown"
            }
        }
    }

    let id: String
    var displayName: String
    var transport: Attributed<Transport>
    /// Which Thread network we believe it sits on, and why.
    var networkID: Attributed<String?>
    var protocols: Set<ServiceType> = []
    /// The mDNS instance names this device advertises under. Kept because
    /// `displayName` gets overwritten with the friendlier HomeKit name, and
    /// proxy attribution has to match on what was actually on the wire.
    var instanceNames: [String] = []
    var addresses: [IPAddress] = []
    var hostname: String?
    var matter: MatterRecord?
    var hap: HAPRecord?
    var homeKitAccessoryID: UUID?
    var lastSeen: Date = .now
    /// Border routers observed answering mDNS queries on this device's behalf.
    /// A Thread device can't answer for itself on Wi-Fi, so whoever did is
    /// running the advertising proxy it registered with.
    var proxiedBy: [String] = []
    var proxyEvidence: String?

    var isSleepy: Bool { matter?.looksSleepy ?? false }
    var isOnThread: Bool { transport.value == .thread }

    var kindLabel: String {
        if let hap, hap.categoryIdentifier != nil { return hap.categoryName }
        if let name = matter?.deviceName, !name.isEmpty { return name }
        return "Device"
    }

    /// Identity that survives across scans.
    ///
    /// `id` is derived from the mDNS instance name, which changes whenever an
    /// accessory renames itself or Bonjour re-disambiguates a collision. For
    /// history and diffing we need something stabler, so prefer identifiers
    /// burned into the device: its HAP device ID, then its Matter node ID.
    var stableKey: String {
        if let deviceID = hap?.deviceID, !deviceID.isEmpty { return "hap:\(deviceID)" }
        if let node = matter?.nodeIDHex, !node.isEmpty { return "matter:\(node)" }
        if let hostname, !hostname.isEmpty { return "host:\(hostname)" }
        return "instance:\(id)"
    }
}

/// A HomeKit accessory as HomeKit itself sees it. Kept separate from
/// `MeshDevice` because HomeKit knows names and rooms but nothing about radios,
/// while mDNS knows radios but not names — the join between them is the app's
/// main job.
struct HomeKitAccessory: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var homeName: String
    var roomName: String?
    var manufacturer: String?
    var model: String?
    var firmwareVersion: String?
    var category: String
    var isReachable: Bool
    var isBridged: Bool
    var bridgeName: String?
    /// Present only for Matter accessories; 16 hex chars, uppercase.
    var matterNodeIDHex: String?
    var serviceCount: Int = 0
}

/// The whole picture, rebuilt from scratch after every scan pass.
struct Topology: Hashable, Codable, Sendable {
    var networks: [ThreadNetwork] = []
    var borderRouters: [BorderRouter] = []
    var devices: [MeshDevice] = []
    var accessories: [HomeKitAccessory] = []
    /// Service records we saw but could not place, kept for the raw view.
    var unmatchedRecords: [ServiceRecord] = []
    /// Devices found over SSDP/UPnP — an entirely separate discovery plane from
    /// mDNS, and where a lot of consumer hardware exclusively lives.
    var upnpDevices: [UPnPDevice] = []
    /// Every service type the DNS-SD meta-query found on the link, including
    /// ones this app doesn't inspect.
    var advertisedServiceTypes: [String] = []
    /// Why proxy attribution produced nothing, when it produced nothing.
    var proxyProbeNote: String?
    var generatedAt: Date = .now

    func network(_ id: String?) -> ThreadNetwork? {
        guard let id else { return nil }
        return networks.first { $0.id == id }
    }

    func borderRouters(on networkID: String) -> [BorderRouter] {
        borderRouters.filter { $0.networkID == networkID }
    }

    func devices(on networkID: String) -> [MeshDevice] {
        devices.filter { $0.networkID.value == networkID }
    }

    var threadDevices: [MeshDevice] { devices.filter(\.isOnThread) }
    var offMeshDevices: [MeshDevice] { devices.filter { !$0.isOnThread } }

    func accessory(_ id: UUID?) -> HomeKitAccessory? {
        guard let id else { return nil }
        return accessories.first { $0.id == id }
    }

    var isEmpty: Bool {
        networks.isEmpty && borderRouters.isEmpty && devices.isEmpty && accessories.isEmpty
    }
}
