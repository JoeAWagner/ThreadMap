import Foundation

/// Something worth telling the user about their smart home's posture.
///
/// These are deliberately not called "vulnerabilities". Most are states that
/// are perfectly normal for thirty seconds during setup and only interesting
/// because they've persisted — so every finding says what it means, why it
/// matters, and what to do, rather than just flashing a colour.
struct Finding: Identifiable, Hashable, Codable, Sendable {

    enum Severity: Int, Comparable, Codable, Sendable {
        case info = 0, low = 1, medium = 2, high = 3

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .info:   "Note"
            case .low:    "Low"
            case .medium: "Medium"
            case .high:   "High"
            }
        }

        var symbolName: String {
            switch self {
            case .info:   "info.circle"
            case .low:    "exclamationmark.circle"
            case .medium: "exclamationmark.triangle.fill"
            case .high:   "exclamationmark.octagon.fill"
            }
        }
    }

    enum Category: String, Codable, Sendable, CaseIterable {
        case exposure   = "Exposure"
        case meshHealth = "Mesh health"
        case coverage   = "Coverage"
        case hygiene    = "Hygiene"
    }

    /// Stable across scans so the UI can tell "still open" from "new".
    let id: String
    var severity: Severity
    var category: Category
    var title: String
    /// What was observed, in plain language.
    var detail: String
    /// Why it matters. Skipped when the title already says it.
    var impact: String?
    /// What to do about it. Nil when there's nothing actionable.
    var remediation: String?
    /// Display names of what this finding is about.
    var subjects: [String] = []
    /// The exact record field the finding was read from, for the sceptical.
    var evidence: String?
}

extension Array where Element == Finding {
    /// Worst first, then by category, so the top of the list is the top priority.
    var ranked: [Finding] {
        sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var highestSeverity: Finding.Severity? { map(\.severity).max() }

    var actionableCount: Int { filter { $0.severity >= .low }.count }
}
