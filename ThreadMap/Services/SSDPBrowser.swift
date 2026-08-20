import Foundation
import Network

/// Discovers devices over SSDP, the UPnP discovery protocol.
///
/// Everything else in this app speaks mDNS. SSDP is a different plane
/// entirely — a plain-text HTTP-over-UDP exchange on a different multicast
/// group — and a large amount of consumer hardware only ever announces itself
/// there. Adding it roughly doubles what the app can see on a typical home
/// network.
///
/// Two sources of truth are used together: replies to our own `M-SEARCH`, and
/// the unsolicited `NOTIFY ssdp:alive` announcements devices broadcast anyway.
/// The second costs nothing and catches devices that ignore searches.
///
/// Requires the multicast entitlement, like `MulticastProber`, and fails soft
/// without it.
actor SSDPBrowser {

    struct Discovery: Sendable {
        var devices: [UPnPDevice] = []
        var failureReason: String?
    }

    private static let group = "239.255.255.250"
    private static let port: NWEndpoint.Port = 1900

    /// `MX` is the maximum seconds a device may wait before replying — it
    /// staggers responses so they don't collide. Our listen window has to be
    /// comfortably longer than it.
    private static let maximumWait = 3

    func discover(duration: TimeInterval = 6.0, resolveDescriptions: Bool = true) async -> Discovery {
        let collector = Collector()
        let queue = DispatchQueue(label: "com.threadmap.ssdp")

        guard let multicast = try? NWMulticastGroup(
            for: [.hostPort(host: NWEndpoint.Host(Self.group), port: Self.port)]
        ) else {
            return Discovery(devices: [], failureReason: "Couldn't join the SSDP multicast group (239.255.255.250:1900). This needs the com.apple.developer.networking.multicast entitlement.")
        }

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connectionGroup = NWConnectionGroup(with: multicast, using: parameters)

        connectionGroup.setReceiveHandler(maximumMessageSize: 16_000, rejectOversizedMessages: false) { message, content, _ in
            guard let content,
                  let text = String(data: content, encoding: .utf8),
                  let endpoint = message.remoteEndpoint
            else { return }
            collector.ingest(text, from: Self.address(from: endpoint))
        }
        connectionGroup.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                collector.setFailure("SSDP group failed: \(error.localizedDescription)")
            }
        }
        connectionGroup.start(queue: queue)

        try? await Task.sleep(for: .milliseconds(400))

        // `ssdp:all` asks everything to answer. Repeating it once catches
        // devices that dropped the first datagram — SSDP is unreliable by
        // design and a single lost packet means a device you never see.
        for _ in 0..<2 {
            connectionGroup.send(content: Self.searchPayload()) { _ in }
            try? await Task.sleep(for: .milliseconds(700))
        }

        try? await Task.sleep(for: .seconds(duration))
        connectionGroup.cancel()

        var (devices, failure) = collector.snapshot()

        if resolveDescriptions {
            devices = await withTaskGroup(of: UPnPDevice.self, returning: [UPnPDevice].self) { group in
                for device in devices {
                    group.addTask { await Self.describe(device) }
                }
                var resolved: [UPnPDevice] = []
                for await device in group { resolved.append(device) }
                return resolved
            }
        }

        devices.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return Discovery(devices: devices, failureReason: devices.isEmpty ? failure : nil)
    }

    // MARK: - Search

    private static func searchPayload() -> Data {
        let request = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(group):\(port.rawValue)",
            "MAN: \"ssdp:discover\"",
            "MX: \(maximumWait)",
            "ST: ssdp:all",
            "", ""
        ].joined(separator: "\r\n")
        return Data(request.utf8)
    }

    private static func address(from endpoint: NWEndpoint) -> IPAddress? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let value):
            return IPAddress(family: .v4, text: "\(value)", bytes: [UInt8](value.rawValue), scopeID: 0)
        case .ipv6(let value):
            let text = "\(value)".split(separator: "%").first.map(String.init) ?? "\(value)"
            return IPAddress(family: .v6, text: text, bytes: [UInt8](value.rawValue), scopeID: 0)
        case .name(let name, _):
            return IPAddressParser.parse(name)
        @unknown default:
            return nil
        }
    }

    // MARK: - Description fetch

    /// Fetches and parses the device description XML the `LOCATION` header
    /// points at. This is where the name a human would recognise lives — the
    /// SSDP reply itself carries only identifiers.
    private static func describe(_ device: UPnPDevice) async -> UPnPDevice {
        guard let location = device.location else { return device }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        guard let (data, _) = try? await session.data(from: location),
              let parsed = UPnPDescriptionParser.parse(data)
        else { return device }

        var device = device
        device.friendlyName = parsed.friendlyName ?? device.friendlyName
        device.manufacturer = parsed.manufacturer ?? device.manufacturer
        device.modelName = parsed.modelName ?? device.modelName
        device.modelNumber = parsed.modelNumber ?? device.modelNumber
        device.serialNumber = parsed.serialNumber ?? device.serialNumber
        device.deviceType = parsed.deviceType ?? device.deviceType
        if let udn = parsed.udn, !udn.isEmpty { device.id = udn }
        return device
    }

    // MARK: - Collector

    /// SSDP datagrams arrive on the group's queue, so shared state is locked.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var devices: [String: UPnPDevice] = [:]
        private var failure: String?

        /// Both M-SEARCH replies and NOTIFY announcements are header blocks in
        /// the same shape, so one parser handles both.
        func ingest(_ text: String, from address: IPAddress?) {
            let headers = Self.headers(in: text)

            // A `byebye` is a device leaving; recording it as present would be
            // exactly backwards.
            if headers["nts"]?.localizedCaseInsensitiveContains("byebye") == true { return }

            guard let usn = headers["usn"], !usn.isEmpty else { return }
            // USN is `uuid:<udn>::<urn>`; the part before `::` identifies the box.
            let identity = usn.components(separatedBy: "::").first ?? usn
            let target = headers["st"] ?? headers["nt"]

            lock.lock(); defer { lock.unlock() }
            var device = devices[identity] ?? UPnPDevice(id: identity)
            if let target, !target.isEmpty { device.searchTargets.insert(target) }
            if device.server == nil { device.server = headers["server"] }
            if device.location == nil, let location = headers["location"] {
                device.location = URL(string: location)
            }
            if device.address == nil { device.address = address }
            device.lastSeen = .now
            devices[identity] = device
        }

        func setFailure(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            if failure == nil { failure = message }
        }

        func snapshot() -> ([UPnPDevice], String?) {
            lock.lock(); defer { lock.unlock() }
            return (Array(devices.values), failure)
        }

        /// SSDP headers are HTTP-shaped but case-insensitive and loosely
        /// formatted, so normalise keys to lowercase.
        private static func headers(in text: String) -> [String: String] {
            var result: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, result[key] == nil else { continue }
                result[key] = value
            }
            return result
        }
    }
}

/// Pulls the handful of fields we care about out of a UPnP device description.
///
/// Only the *root* device's fields are taken. A description can nest embedded
/// devices, and their names would otherwise overwrite the parent's.
final class UPnPDescriptionParser: NSObject, XMLParserDelegate {

    struct Description {
        var friendlyName: String?
        var manufacturer: String?
        var modelName: String?
        var modelNumber: String?
        var serialNumber: String?
        var deviceType: String?
        var udn: String?
    }

    /// Not named `description`: this subclasses NSObject, which already has a
    /// `description: String`, and shadowing it is a compile error.
    private var result = Description()
    private var currentElement = ""
    private var currentText = ""
    private var deviceDepth = 0

    static func parse(_ data: Data) -> Description? {
        let delegate = UPnPDescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        currentElement = elementName
        currentText = ""
        if elementName == "device" { deviceDepth += 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        defer {
            if elementName == "device" { deviceDepth -= 1 }
            currentText = ""
        }
        // Depth 1 is the root device; anything deeper is an embedded device.
        guard deviceDepth == 1 else { return }
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        switch elementName {
        case "friendlyName":  if result.friendlyName == nil { result.friendlyName = value }
        case "manufacturer":  if result.manufacturer == nil { result.manufacturer = value }
        case "modelName":     if result.modelName == nil { result.modelName = value }
        case "modelNumber":   if result.modelNumber == nil { result.modelNumber = value }
        case "serialNumber":  if result.serialNumber == nil { result.serialNumber = value }
        case "deviceType":    if result.deviceType == nil { result.deviceType = value }
        case "UDN":           if result.udn == nil { result.udn = value }
        default: break
        }
    }
}
