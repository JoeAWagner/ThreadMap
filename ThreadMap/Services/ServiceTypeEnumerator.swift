import Foundation
import dnssd

/// Enumerates every Bonjour service *type* being advertised on the link.
///
/// Ordinary browsing requires you to already know what to look for, which means
/// anything you didn't think of stays invisible. DNS-SD has a meta-query for
/// exactly this — browsing `_services._dns-sd._udp` returns the service types
/// in use rather than instances of one type. It's how you find out your network
/// is running something you never configured.
///
/// Note: enumerating a type is not the same as browsing it. iOS's Local Network
/// privacy model only lets an app browse types declared in `NSBonjourServices`,
/// so an unexpected type shows up in this list and then needs a deliberate
/// Info.plist addition before its instances can be inspected.
final class ServiceTypeEnumerator: Sendable {

    private let queue = DispatchQueue(label: "com.threadmap.metaquery", qos: .utility)

    private final class Box {
        var types: Set<String> = []
        var resumed = false
        var continuation: CheckedContinuation<Void, Never>?

        func finish() {
            guard !resumed else { return }
            resumed = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// - Returns: type strings in `_name._proto` form, e.g. `_hap._tcp`.
    func enumerate(duration: TimeInterval = 3.0) async -> Set<String> {
        let box = Box()
        var ref: DNSServiceRef?

        let callback: DNSServiceBrowseReply = { _, _, _, errorCode, serviceName, regtype, _, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            guard errorCode == kDNSServiceErr_NoError,
                  let serviceName, let regtype else { return }

            // In a meta-query reply the roles shift: `serviceName` carries the
            // discovered type's name (`_hap`) and `regtype` its transport
            // (`_tcp.local.`).
            let name = String(cString: serviceName)
            let proto = String(cString: regtype).split(separator: ".").first.map(String.init) ?? ""
            guard !name.isEmpty, !proto.isEmpty else { return }
            box.types.insert("\(name).\(proto)")
        }

        let context = Unmanaged.passRetained(box).toOpaque()
        let err = DNSServiceBrowse(&ref, 0, 0, "_services._dns-sd._udp", "local.", callback, context)
        guard err == kDNSServiceErr_NoError, let ref else {
            Unmanaged<Box>.fromOpaque(context).release()
            return []
        }
        DNSServiceSetDispatchQueue(ref, queue)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                box.continuation = cont
                self.queue.asyncAfter(deadline: .now() + duration) { box.finish() }
            }
        }

        return queue.sync {
            DNSServiceRefDeallocate(ref)
            let types = box.types
            Unmanaged<Box>.fromOpaque(context).release()
            return types
        }
    }

    /// Types found on the network that the app doesn't currently inspect.
    static func unrecognised(_ discovered: Set<String>) -> [String] {
        let known = Set(ServiceType.allCases.map(\.rawValue))
        return discovered.subtracting(known).sorted()
    }

    /// A short, human explanation for the types people are most likely to see,
    /// so the list isn't just cryptic strings.
    static func annotation(for type: String) -> String? {
        switch type {
        case "_companion-link._tcp": return "Apple device-to-device link (Handoff, Continuity)"
        case "_rdlink._tcp", "_sleep-proxy._udp": return "Apple networking service"
        case "_googlecast._tcp": return "Google Cast — Chromecast, Nest displays and speakers"
        case "_androidtvremote2._tcp": return "Android TV remote"
        case "_spotify-connect._tcp": return "Spotify Connect endpoint"
        case "_printer._tcp", "_ipp._tcp", "_ipps._tcp", "_pdl-datastream._tcp": return "Network printer"
        case "_smb._tcp", "_afpovertcp._tcp": return "File sharing"
        case "_ssh._tcp", "_sftp-ssh._tcp": return "SSH — a device accepting remote shell logins"
        case "_workstation._tcp": return "Generic host announcement"
        case "_http._tcp", "_https._tcp": return "Web server — often a device's local config page"
        case "_amzn-wplay._tcp", "_amazonecho-remote._tcp": return "Amazon Echo device"
        case "_sonos._tcp": return "Sonos speaker"
        case "_hue._tcp": return "Philips Hue bridge"
        case "_esphomelib._tcp": return "ESPHome device"
        case "_homekit._tcp": return "HomeKit setup service"
        case "_nvstream._tcp": return "NVIDIA GameStream"
        case "_dosvc._tcp": return "Windows Delivery Optimization"
        default: return nil
        }
    }

    /// Types worth a second look on a home network.
    static func isNoteworthy(_ type: String) -> Bool {
        ["_ssh._tcp", "_sftp-ssh._tcp", "_telnet._tcp", "_smb._tcp",
         "_afpovertcp._tcp", "_vnc._tcp", "_rfb._tcp", "_adb._tcp"].contains(type)
    }
}
