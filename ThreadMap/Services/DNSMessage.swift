import Foundation

/// Just enough DNS wire format to build an mDNS query and read the answers.
///
/// `NWBrowser` and `dnssd` both hide the responder's address, which is the one
/// thing we need for proxy attribution — so for that one job we speak the
/// protocol directly. This is a reader, not a resolver: it decodes names
/// (including compression pointers) and PTR targets, and skips everything else.
enum DNSMessage {

    struct Record {
        /// Labels of the record's owner name, undotted.
        var nameLabels: [String]
        var type: UInt16
        /// For PTR records, the labels of the name in RDATA.
        var targetLabels: [String]?

        var name: String { nameLabels.joined(separator: ".") }
        var target: String? { targetLabels?.joined(separator: ".") }
    }

    struct Message {
        var isResponse: Bool
        var records: [Record]

        /// Service instance names this message talks about, in DNS-SD terms:
        /// the first label of a PTR target, or of a record owner name that sits
        /// under a service type.
        func instanceNames(forServiceTypes types: [String]) -> Set<String> {
            var names: Set<String> = []
            for record in records {
                if let target = record.targetLabels, target.count >= 3, let first = target.first {
                    let suffix = target.dropFirst().prefix(2).joined(separator: ".")
                    if types.contains(suffix) { names.insert(first) }
                }
                if record.nameLabels.count >= 3, let first = record.nameLabels.first {
                    let suffix = record.nameLabels.dropFirst().prefix(2).joined(separator: ".")
                    if types.contains(suffix) { names.insert(first) }
                }
            }
            return names
        }
    }

    static let typePTR: UInt16 = 12

    // MARK: - Building

    /// A standard multicast DNS query. The response goes to the multicast group
    /// rather than back to us directly, which is what lets us see every
    /// responder rather than only the fastest one.
    static func query(name: String, type: UInt16 = typePTR) -> Data {
        var data = Data()
        data.append(contentsOf: [0x00, 0x00])              // transaction ID (0 for mDNS)
        data.append(contentsOf: [0x00, 0x00])              // flags: standard query
        data.append(contentsOf: [0x00, 0x01])              // one question
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00,   // no answers, no authority
                                 0x00, 0x00])              // no additional
        data.append(encode(name: name))
        data.append(contentsOf: [UInt8(type >> 8), UInt8(type & 0xFF)])
        data.append(contentsOf: [0x00, 0x01])              // class IN
        return data
    }

    private static func encode(name: String) -> Data {
        var data = Data()
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8).prefix(63)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0x00)
        return data
    }

    // MARK: - Parsing

    static func parse(_ data: Data) -> Message? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }

        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let isResponse = (flags & 0x8000) != 0
        let counts = (0..<4).map { index -> Int in
            let offset = 4 + index * 2
            return Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
        }
        let (questions, answers, authorities, additionals) = (counts[0], counts[1], counts[2], counts[3])

        var cursor = 12
        for _ in 0..<questions {
            guard let (_, next) = readName(bytes, at: cursor) else { return nil }
            cursor = next + 4                                   // qtype + qclass
            guard cursor <= bytes.count else { return nil }
        }

        var records: [Record] = []
        for _ in 0..<(answers + authorities + additionals) {
            guard let (labels, afterName) = readName(bytes, at: cursor) else { break }
            var offset = afterName
            guard offset + 10 <= bytes.count else { break }

            let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let rdLength = Int(UInt16(bytes[offset + 8]) << 8 | UInt16(bytes[offset + 9]))
            offset += 10
            guard offset + rdLength <= bytes.count else { break }

            var target: [String]?
            if type == typePTR {
                // RDATA may use a compression pointer back into the header, so
                // decode it against the whole message rather than the slice.
                target = readName(bytes, at: offset)?.0
            }
            records.append(Record(nameLabels: labels, type: type, targetLabels: target))
            offset += rdLength
            cursor = offset
        }

        return Message(isResponse: isResponse, records: records)
    }

    /// Decodes a possibly-compressed domain name.
    /// - Returns: the labels, and the offset just past the name *in the record
    ///   stream* — for a compressed name that's past the pointer, not past the
    ///   data it points at.
    private static func readName(_ bytes: [UInt8], at start: Int) -> ([String], Int)? {
        var labels: [String] = []
        var cursor = start
        var next: Int?
        // A malformed or hostile packet can point a name at itself; cap the
        // work rather than looping forever.
        var jumps = 0

        while cursor < bytes.count {
            let length = bytes[cursor]

            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { return nil }
                let pointer = Int(UInt16(length & 0x3F) << 8 | UInt16(bytes[cursor + 1]))
                if next == nil { next = cursor + 2 }
                guard pointer < bytes.count, jumps < 16 else { return nil }
                jumps += 1
                cursor = pointer
                continue
            }

            if length == 0 {
                return (labels, next ?? cursor + 1)
            }

            let from = cursor + 1
            let to = from + Int(length)
            guard to <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[from..<to], as: UTF8.self))
            cursor = to
        }
        return nil
    }
}
