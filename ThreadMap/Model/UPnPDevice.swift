import Foundation

/// A device found over SSDP/UPnP rather than mDNS.
///
/// This is an entirely separate discovery plane. Sonos, Roku, Wemo, most smart
/// TVs, printers, NAS boxes and a lot of older IoT announce themselves here and
/// nowhere else — they are simply invisible to a Bonjour-only scan.
struct UPnPDevice: Identifiable, Hashable, Codable, Sendable {
    /// The UDN from the device description, or the USN we first saw it under.
    var id: String
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var modelNumber: String?
    var serialNumber: String?
    /// e.g. `urn:schemas-upnp-org:device:MediaRenderer:1`
    var deviceType: String?
    /// The `SERVER` header, which usually names the OS and product.
    var server: String?
    /// Where the description XML lives.
    var location: URL?
    var address: IPAddress?
    /// Every search target this host answered under.
    var searchTargets: Set<String> = []
    var lastSeen: Date = .now

    var displayName: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        if let modelName, !modelName.isEmpty { return modelName }
        if let host = location?.host { return host }
        return id
    }

    var subtitle: String {
        [manufacturer, modelName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// An Internet Gateway Device is your router advertising UPnP port
    /// mapping — any device on the LAN can then open a hole in the firewall
    /// without asking you.
    var isInternetGateway: Bool {
        let targets = searchTargets.joined(separator: " ") + " " + (deviceType ?? "")
        return targets.localizedCaseInsensitiveContains("InternetGatewayDevice")
            || targets.localizedCaseInsensitiveContains("WANConnectionDevice")
    }

    var symbolName: String {
        let type = (deviceType ?? "") + " " + (modelName ?? "")
        if isInternetGateway { return "network.badge.shield.half.filled" }
        if type.localizedCaseInsensitiveContains("MediaRenderer") { return "hifispeaker.fill" }
        if type.localizedCaseInsensitiveContains("MediaServer") { return "externaldrive.connected.to.line.below" }
        if type.localizedCaseInsensitiveContains("Printer") { return "printer.fill" }
        if type.localizedCaseInsensitiveContains("Basic") { return "shippingbox" }
        return "rectangle.connected.to.line.below"
    }
}
