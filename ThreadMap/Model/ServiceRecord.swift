import Foundation

/// The Bonjour service types we browse for. Each one has to be listed in
/// `NSBonjourServices` in Info.plist or iOS silently returns nothing.
enum ServiceType: String, CaseIterable, Codable, Sendable {
    /// Thread Border Router MeshCoP border agent. This is the single most
    /// valuable record on the network: it names the Thread network, its
    /// extended PAN ID, the border agent ID, and the router's state.
    case meshcop     = "_meshcop._udp"
    /// Border agent reachable over an encrypted (ePSKc) channel, Thread 1.4+.
    case meshcopE    = "_meshcop-e._tcp"
    /// Thread Radio Encapsulation Link — only border routers advertise it.
    case trel        = "_trel._udp"
    /// Commissioned Matter node. Instance name is `<fabric>-<nodeid>`.
    case matter      = "_matter._tcp"
    /// Matter device in commissioning mode (not yet paired).
    case matterC     = "_matterc._udp"
    /// A Matter *commissioner* advertising that it can add devices to a fabric —
    /// an Apple TV, a Nest Hub, an Echo. Seeing one you don't recognise means
    /// something on your network is offering to commission your devices.
    case matterD     = "_matterd._udp"
    /// HomeKit accessory over Thread (HAP-over-CoAP/UDP).
    case hapThread   = "_hap._udp"
    /// HomeKit accessory over Wi-Fi/Ethernet (HAP-over-IP/TCP).
    case hapIP       = "_hap._tcp"

    // MARK: Context types
    //
    // These say nothing about Thread, but they're published by the same hosts
    // and carry the names people actually recognise. A MeshCoP record might
    // identify a border router only as `1A2B3C4D`; an AirPlay record on the
    // same host says "Living Room Apple TV".

    /// Apple's model/OS record — the best single source of "what is this box".
    case deviceInfo    = "_device-info._tcp"
    case airplay       = "_airplay._tcp"
    case raop          = "_raop._tcp"
    case companionLink = "_companion-link._tcp"
    /// Google/Nest hubs, many of which are also Thread border routers.
    case googlecast    = "_googlecast._tcp"
    case homeKitSetup  = "_homekit._tcp"
    case hue           = "_hue._tcp"
    case esphome       = "_esphomelib._tcp"
    /// Cast groups and zones.
    case googlezone    = "_googlezone._tcp"
    case androidTV     = "_androidtvremote2._tcp"
    /// Amazon Whisperplay — Fire TV and friends.
    case amazonWPlay   = "_amzn-wplay._tcp"
    case amazonEcho    = "_amazonecho-remote._tcp"
    case sonos         = "_sonos._tcp"
    case spotify       = "_spotify-connect._tcp"
    case nanoleaf      = "_nanoleafapi._tcp"
    case shelly        = "_shelly._tcp"

    var displayName: String {
        switch self {
        case .meshcop:       "Thread Border Agent"
        case .meshcopE:      "Border Agent (ePSKc)"
        case .trel:          "Thread Radio Link"
        case .matter:        "Matter node"
        case .matterC:       "Matter (commissionable)"
        case .matterD:       "Matter commissioner"
        case .hapThread:     "HomeKit over Thread"
        case .hapIP:         "HomeKit over IP"
        case .deviceInfo:    "Device info"
        case .airplay:       "AirPlay"
        case .raop:          "AirPlay audio"
        case .companionLink: "Apple companion link"
        case .googlecast:    "Google Cast"
        case .homeKitSetup:  "HomeKit setup"
        case .hue:           "Philips Hue bridge"
        case .esphome:       "ESPHome"
        case .googlezone:    "Google Cast zone"
        case .androidTV:     "Android TV / Google TV"
        case .amazonWPlay:   "Amazon Fire device"
        case .amazonEcho:    "Amazon Echo"
        case .sonos:         "Sonos"
        case .spotify:       "Spotify Connect"
        case .nanoleaf:      "Nanoleaf"
        case .shelly:        "Shelly"
        }
    }

    /// Types that indicate the advertiser is itself a border router.
    static var borderRouterTypes: [ServiceType] { [.meshcop, .meshcopE, .trel] }
    /// Types that indicate an end device we want on the map.
    static var deviceTypes: [ServiceType] { [.matter, .matterC, .hapThread, .hapIP] }
    /// Types used only to put a human-readable name on hardware we found some
    /// other way. They never create a node on the map by themselves.
    static var contextTypes: [ServiceType] {
        [.deviceInfo, .airplay, .raop, .companionLink, .googlecast, .homeKitSetup,
         .hue, .esphome, .googlezone, .androidTV, .amazonWPlay, .amazonEcho,
         .sonos, .spotify, .nanoleaf, .shelly]
    }

    /// Types that indicate the advertiser can commission devices onto a Matter
    /// fabric. Not a device on the map, but worth knowing about.
    static var commissionerTypes: [ServiceType] { [.matterD] }
}

/// One resolved mDNS service instance, straight off the wire.
struct ServiceRecord: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(type.rawValue)|\(instanceName)" }

    let type: ServiceType
    /// The service instance name, e.g. `Front Door 1A2B` or `8FC7…-0000000012345678`.
    let instanceName: String
    let domain: String
    /// `.local` hostname the SRV record points at.
    var hostname: String?
    var port: UInt16
    var addresses: [IPAddress]
    /// Raw TXT key/value pairs. Values are kept as `Data` because several
    /// Thread keys (`xp`, `id`, `sb`) are binary, not text.
    var txt: [String: Data]
    /// When we last saw an advertisement for this instance.
    var lastSeen: Date

    func txtString(_ key: String) -> String? {
        guard let data = txt[key] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func txtHex(_ key: String) -> String? {
        guard let data = txt[key] else { return nil }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    func txtUInt(_ key: String) -> UInt64? {
        guard let data = txt[key], !data.isEmpty, data.count <= 8 else { return nil }
        // Thread TXT integers are big-endian binary; Matter's are ASCII decimal.
        if let s = String(data: data, encoding: .utf8), let n = UInt64(s), data.allSatisfy({ (0x30...0x39).contains($0) }) {
            return n
        }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    var routableAddresses: [IPAddress] { addresses.filter(\.isRoutable) }
}
