import Foundation

/// A Matter fabric: one administrative domain over a set of devices.
///
/// This is the piece of smart-home structure that is genuinely invisible
/// otherwise. A Matter device can be commissioned into several fabrics at
/// once — Apple's, Google's, Amazon's, Home Assistant's — and **each fabric
/// holder has full control of the device**. No consumer app shows you this,
/// but the compressed fabric ID is sitting in plain sight in every
/// `_matter._tcp` instance name, which is formatted `<fabric>-<node>`.
///
/// So: count the distinct fabric IDs and you know how many parties can operate
/// your devices. Find one you can't account for and that's worth investigating.
struct MatterFabric: Identifiable, Hashable, Codable, Sendable {
    /// Compressed fabric ID, 16 uppercase hex characters.
    let id: String
    var deviceIDs: [String] = []
    var deviceNames: [String] = []

    /// True when at least one device on this fabric is also in your HomeKit
    /// home — which identifies this as Apple's fabric.
    var containsHomeKitAccessory: Bool = false

    var shortID: String { "\(id.prefix(4))…\(id.suffix(4))" }

    /// We can name Apple's fabric because HomeKit told us about its devices.
    /// Every other fabric is anonymous by design — Matter deliberately doesn't
    /// broadcast which ecosystem an admin belongs to.
    var displayName: String {
        containsHomeKitAccessory ? "Apple Home fabric" : "Fabric \(shortID)"
    }

    var deviceCount: Int { deviceIDs.count }
}

extension Topology {

    /// Groups the commissioned Matter devices by the fabric they belong to.
    var matterFabrics: [MatterFabric] {
        var byID: [String: MatterFabric] = [:]
        for device in devices {
            guard let fabricID = device.matter?.compressedFabricID, !fabricID.isEmpty else { continue }
            var fabric = byID[fabricID] ?? MatterFabric(id: fabricID)
            fabric.deviceIDs.append(device.id)
            fabric.deviceNames.append(device.displayName)
            if device.homeKitAccessoryID != nil { fabric.containsHomeKitAccessory = true }
            byID[fabricID] = fabric
        }
        return byID.values.sorted { $0.deviceCount > $1.deviceCount }
    }

    /// Devices commissioned into more than one fabric.
    ///
    /// A device advertises one `_matter._tcp` instance *per fabric*, so
    /// multi-admin shows up as several records resolving to the same host. The
    /// builder merges those into one device, keeping every instance name — so
    /// the fabric IDs embedded in those names are the evidence.
    var multiAdminDevices: [(device: MeshDevice, fabricIDs: [String])] {
        devices.compactMap { device in
            let fabricIDs = Set(
                device.instanceNames.compactMap { name -> String? in
                    let parts = name.split(separator: "-")
                    guard parts.count == 2, parts[0].count == 16, parts[1].count == 16 else { return nil }
                    return String(parts[0]).uppercased()
                }
            )
            guard fabricIDs.count > 1 else { return nil }
            return (device, fabricIDs.sorted())
        }
    }
}
