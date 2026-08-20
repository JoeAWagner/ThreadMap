import Foundation
import Network

/// Sends mDNS queries directly and records **who answered**.
///
/// This is the one piece of the app that gets close to a device→router edge. A
/// Thread device has no radio on your Wi-Fi and cannot answer an mDNS query
/// itself; its records are republished by the advertising proxy on the border
/// router it registered with over SRP. So whichever host's address a response
/// arrives from is a router that is proxying that device.
///
/// That is *not* the same as the device's mesh parent — it says which border
/// router holds its service registration, which is a different and slightly
/// coarser fact. It's still the strongest device-to-router link obtainable
/// without joining the mesh, and it's honest about what it means.
///
/// Requires the `com.apple.developer.networking.multicast` entitlement. Without
/// it the group fails to start and the probe reports that cleanly.
actor MulticastProber {

    struct Attribution: Sendable {
        /// Service instance name → addresses that answered for it.
        var responders: [String: Set<IPAddress>] = [:]
        /// Every address that sent us anything, whether or not we matched it.
        var allResponders: Set<IPAddress> = []
        var failureReason: String?

        var isEmpty: Bool { responders.isEmpty }
    }

    private static let ipv6Group = "ff02::fb"
    private static let ipv4Group = "224.0.0.251"
    private static let port: NWEndpoint.Port = 5353

    /// - Parameter serviceTypes: types in `_name._proto` form to ask about.
    func probe(
        serviceTypes: [String] = [ServiceType.hapThread.rawValue, ServiceType.matter.rawValue],
        duration: TimeInterval = 4.0
    ) async -> Attribution {

        var attribution = Attribution()
        let collector = Collector()
        let queue = DispatchQueue(label: "com.threadmap.mdns")
        var groups: [NWConnectionGroup] = []

        for host in [Self.ipv6Group, Self.ipv4Group] {
            guard let group = makeGroup(host: host, queue: queue, collector: collector, serviceTypes: serviceTypes) else {
                continue
            }
            groups.append(group)
        }

        guard !groups.isEmpty else {
            attribution.failureReason = "Couldn't join the mDNS multicast group. This needs the com.apple.developer.networking.multicast entitlement, which Apple grants on request — the rest of the app works without it."
            return attribution
        }

        // Give the groups a moment to come up before asking anything.
        try? await Task.sleep(for: .milliseconds(400))

        for type in serviceTypes {
            let payload = DNSMessage.query(name: "\(type).local")
            for group in groups {
                group.send(content: payload) { _ in }
            }
            // Two queries a second apart: sleepy devices' proxies sometimes
            // miss the first, and a repeat costs almost nothing.
            try? await Task.sleep(for: .milliseconds(250))
        }

        try? await Task.sleep(for: .seconds(duration))
        for type in serviceTypes {
            let payload = DNSMessage.query(name: "\(type).local")
            groups.forEach { $0.send(content: payload) { _ in } }
        }
        try? await Task.sleep(for: .seconds(1.5))

        groups.forEach { $0.cancel() }

        let (responders, all, failure) = collector.snapshot()
        attribution.responders = responders
        attribution.allResponders = all
        if responders.isEmpty, let failure { attribution.failureReason = failure }
        return attribution
    }

    // MARK: - Group setup

    private func makeGroup(host: String, queue: DispatchQueue,
                           collector: Collector, serviceTypes: [String]) -> NWConnectionGroup? {
        guard let multicast = try? NWMulticastGroup(
            for: [.hostPort(host: NWEndpoint.Host(host), port: Self.port)]
        ) else {
            collector.setFailure("Couldn't create a multicast group for \(host). This usually means the multicast entitlement is missing.")
            return nil
        }

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let group = NWConnectionGroup(with: multicast, using: parameters)

        group.setReceiveHandler(maximumMessageSize: 9_000, rejectOversizedMessages: false) { message, content, _ in
            guard let content,
                  let parsed = DNSMessage.parse(content),
                  parsed.isResponse,
                  let endpoint = message.remoteEndpoint,
                  let responder = Self.address(from: endpoint)
            else { return }

            collector.addResponder(responder)
            for instance in parsed.instanceNames(forServiceTypes: serviceTypes) {
                collector.attribute(instance: instance, to: responder)
            }
        }

        group.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                collector.setFailure("Multicast group failed: \(error.localizedDescription)")
            }
        }

        group.start(queue: queue)
        return group
    }

    private static func address(from endpoint: NWEndpoint) -> IPAddress? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv6(let value):
            return IPAddress(family: .v6, text: stripZone("\(value)"),
                             bytes: [UInt8](value.rawValue), scopeID: 0)
        case .ipv4(let value):
            return IPAddress(family: .v4, text: "\(value)",
                             bytes: [UInt8](value.rawValue), scopeID: 0)
        case .name(let name, _):
            return IPAddressParser.parse(name)
        @unknown default:
            return nil
        }
    }

    private static func stripZone(_ text: String) -> String {
        text.split(separator: "%").first.map(String.init) ?? text
    }

    // MARK: - Collector

    /// Receive handlers fire on the group's queue, so shared state is locked
    /// rather than actor-isolated.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var responders: [String: Set<IPAddress>] = [:]
        private var all: Set<IPAddress> = []
        private var failure: String?

        func attribute(instance: String, to address: IPAddress) {
            lock.lock(); defer { lock.unlock() }
            responders[instance, default: []].insert(address)
        }

        func addResponder(_ address: IPAddress) {
            lock.lock(); defer { lock.unlock() }
            all.insert(address)
        }

        func setFailure(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            if failure == nil { failure = message }
        }

        func snapshot() -> ([String: Set<IPAddress>], Set<IPAddress>, String?) {
            lock.lock(); defer { lock.unlock() }
            return (responders, all, failure)
        }
    }
}
