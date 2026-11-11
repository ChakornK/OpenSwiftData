import Foundation
import ParityContracts

// Writes and loads `APICoverageReport` as canonical JSON (sorted keys,
// slash-unescaped) via `CanonicalJSON.encode`.

public enum ReportEmitter {
    /// Encodes `report` to canonical JSON and writes it atomically to `url`.
    public static func emit(_ report: APICoverageReport, to url: URL) throws {
        let data = try CanonicalJSON.encode(report)
        try data.write(to: url, options: .atomic)
    }

    /// Loads and decodes an `APICoverageReport` from `url`.
    public static func load(from url: URL) throws -> APICoverageReport {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(APICoverageReport.self, from: data)
    }
}
