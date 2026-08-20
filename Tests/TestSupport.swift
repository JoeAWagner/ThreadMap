import Foundation
@testable import ThreadMap

/// Builders for the fixtures the tests share.
enum Fixture {

    static func txt(_ pairs: [String: Any]) -> [String: Data] {
        var result: [String: Data] = [:]
        for (key, value) in pairs {
            switch value {
            case let data as Data:     result[key] = data
            case let string as String: result[key] = Data(string.utf8)
            case let bytes as [UInt8]: result[key] = Data(bytes)
            default:                   result[key] = Data(String(describing: value).utf8)
            }
        }
        return result
    }

    static func address(_ text: String) -> IPAddress {
        guard let parsed = IPAddressParser.parse(text) else {
            fatalError("Fixture.address given a non-numeric address: \(text)")
        }
        return parsed
    }

    static func record(
        _ type: ServiceType,
        name: String,
        txt: [String: Data] = [:],
        addresses: [String] = [],
        hostname: String? = nil
    ) -> ServiceRecord {
        ServiceRecord(
            type: type,
            instanceName: name,
            domain: "local.",
            hostname: hostname,
            port: 5540,
            addresses: addresses.map(address),
            txt: txt,
            lastSeen: .now
        )
    }

    /// A border agent advertising a Thread 1.4 network with an OMR prefix.
    static func borderAgentTXT(
        networkName: String = "Home Thread",
        extendedPANID: [UInt8] = [0x1A, 0x2B, 0x3C, 0x4D, 0x5E, 0x6F, 0x70, 0x81],
        borderAgentID: [UInt8] = Array(repeating: 0xAB, count: 16),
        stateBitmap: [UInt8] = [0x00, 0x00, 0x0F, 0xB1],
        partitionID: [UInt8] = [0x12, 0x34, 0x56, 0x78],
        omrPrefix: [UInt8]? = [64, 0xFD, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]
    ) -> [String: Data] {
        var values: [String: Any] = [
            "rv": "1",
            "tv": "1.4.0",
            "nn": networkName,
            "xp": Data(extendedPANID),
            "id": Data(borderAgentID),
            "sb": Data(stateBitmap),
            "pt": Data(partitionID),
            "vn": "Apple Inc.",
            "mn": "Apple TV"
        ]
        if let omrPrefix { values["omr"] = Data(omrPrefix) }
        return txt(values)
    }

    static func snapshot(_ topology: Topology, date: Date = .now, browseDuration: TimeInterval = 5) -> ScanSnapshot {
        ScanSnapshot(date: date, topology: topology, findings: [], browseDuration: browseDuration)
    }
}
