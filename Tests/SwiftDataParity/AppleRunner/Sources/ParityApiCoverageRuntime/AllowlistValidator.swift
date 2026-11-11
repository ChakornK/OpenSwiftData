import Foundation
import ParityContracts

// Loads and validates the API coverage allowlist. Validates each entry's
// fields, rejects stale/duplicate entries and entries that allowlist already-
// covered symbols, and annotates uncovered symbols with the allowlist fields.

public struct AllowlistFile: Codable {
    public let symbols: [AllowlistEntry]

    public init(symbols: [AllowlistEntry]) {
        self.symbols = symbols
    }
}

public enum AllowlistValidator {
    /// Loads the allowlist from `url`. Non-throwing: a missing file is an empty
    /// allowlist (no issues); a decode failure yields an empty allowlist with one
    /// load issue. The caller treats `loadIssues` as `validationIssues`.
    public static func loadEntries(from url: URL) -> (entries: [AllowlistEntry], loadIssues: [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], [])
        }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(AllowlistFile.self, from: data).symbols, [])
        } catch {
            return ([], ["allowlist: \(error)"])
        }
    }

    /// Validates `entries` against `result` and annotates uncovered symbols
    /// with the matching entry's allowlist fields. Returns the rebuilt
    /// `SymbolRecord`s, any validation issues, and whether the allowlist is
    /// valid. Issue message templates are fixed for determinism.
    public static func validate(
        entries: [AllowlistEntry],
        against result: CoverageResult,
        evaluationDate: EvaluationDate
    ) -> AllowlistValidation {
        let formatter = Self.expirationFormatter
        var issues: [String] = []
        var seen = Set<String>()
        var annotations: [String: AllowlistAnnotation] = [:]

        for entry in entries {
            let fqn = entry.fullyQualifiedName
            if !PermittedReasonCategories.all.contains(entry.reasonCategory) {
                issues.append("\(fqn): invalid reasonCategory '\(entry.reasonCategory)'")
            }
            if entry.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(fqn): rationale must not be empty")
            }
            guard let url = URL(string: entry.issueURL), url.scheme == "https" else {
                issues.append("\(fqn): issueURL must be HTTPS")
                continue
            }
            _ = url
            let parsedExpiration = formatter.date(from: entry.expiration)
            guard let expirationDate = parsedExpiration, expirationDate >= evaluationDate.foundationDate else {
                issues.append("\(fqn): invalid or expired expiration '\(entry.expiration)'")
                continue
            }
            // Non-stale: at least one symbol in the surface matches by
            // (fullyQualifiedName, kind when present).
            let matchingSymbols = result.surface.symbols.filter { matches(entry: entry, symbol: $0) }
            if matchingSymbols.isEmpty {
                issues.append("\(fqn): stale entry (no matching API_Symbol)")
            }
            // Non-duplicate: track (fqn, kind?) pairs.
            let dedupeKey = "\(fqn)#\(entry.kind ?? "")"
            if !seen.insert(dedupeKey).inserted {
                issues.append("\(fqn): duplicate allowlist entry")
            }
            // Not-allowlisting-covered: no matching SymbolRecord is covered.
            let coveredMatch = result.symbols.contains { record in
                record.fullyQualifiedName == fqn
                    && (entry.kind == nil || entry.kind == record.kind)
                    && record.covered
            }
            if coveredMatch {
                issues.append("\(fqn): entry allowlists a covered symbol")
            }
            // Stash an annotation for any matching uncovered symbol. Multiple
            // entries may match the same symbol; the last one wins (rare and
            // flagged as duplicate above).
            for symbol in matchingSymbols {
                let key = "\(symbol.fullyQualifiedName)#\(symbol.kind.rawValue)"
                annotations[key] = AllowlistAnnotation(
                    reasonCategory: entry.reasonCategory,
                    rationale: entry.rationale,
                    issueURL: entry.issueURL
                )
            }
        }

        let annotated = result.symbols.map { record -> SymbolRecord in
            let key = "\(record.fullyQualifiedName)#\(record.kind)"
            guard let annotation = annotations[key], !record.covered else {
                return record
            }
            return SymbolRecord(
                kind: record.kind,
                displayName: record.displayName,
                fullyQualifiedName: record.fullyQualifiedName,
                sourceSignature: record.sourceSignature,
                platformAvailability: record.platformAvailability,
                covered: record.covered,
                referenceCount: record.referenceCount,
                references: record.references,
                allowlisted: true,
                allowlistReasonCategory: annotation.reasonCategory,
                allowlistRationale: annotation.rationale,
                allowlistIssueURL: annotation.issueURL,
                mangledName: record.mangledName
            )
        }
        return AllowlistValidation(
            annotatedSymbols: annotated,
            validationIssues: issues,
            valid: issues.isEmpty
        )
    }

    /// Recomputes `coverageValid` from `symbols` against the current `entries`
    /// and `evaluationDate`. Returns `true` iff every uncovered symbol is
    /// allowlisted with a non-expired entry, every entry is non-stale relative
    /// to `symbols`, and no covered symbol is allowlisted. Used by `--check-only`.
    public static func recomputeValid(
        symbols: [SymbolRecord],
        entries: [AllowlistEntry],
        evaluationDate: EvaluationDate
    ) -> Bool {
        let formatter = Self.expirationFormatter
        for entry in entries {
            guard let expirationDate = formatter.date(from: entry.expiration),
                expirationDate >= evaluationDate.foundationDate
            else {
                return false
            }
            // Non-stale relative to the stored report: at least one record
            // matches by (fullyQualifiedName, kind when present).
            let matchesReport = symbols.contains { record in
                record.fullyQualifiedName == entry.fullyQualifiedName
                    && (entry.kind == nil || entry.kind == record.kind)
            }
            if !matchesReport { return false }
        }
        // Every uncovered symbol must be allowlisted with a valid entry.
        for record in symbols where !record.covered {
            let hasValidEntry = entries.contains { entry in
                entry.fullyQualifiedName == record.fullyQualifiedName
                    && (entry.kind == nil || entry.kind == record.kind)
                    && (formatter.date(from: entry.expiration)?.timeIntervalSince(evaluationDate.foundationDate) ?? -1) >= 0
            }
            if !hasValidEntry { return false }
        }
        // No covered symbol may be allowlisted.
        let anyCoveredAllowlisted = symbols.contains { $0.covered && $0.allowlisted }
        if anyCoveredAllowlisted { return false }
        return true
    }

    /// `DateFormatter` pinned for `yyyy-MM-dd` parsing in `en_US_POSIX` / GMT,
    /// non-lenient (rejects `2026-02-31`).
    private static let expirationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    /// Match function: an entry matches a symbol when `fullyQualifiedName`
    /// equals and, when the entry specifies `kind`, the kind strings equal.
    private static func matches(entry: AllowlistEntry, symbol: API_Symbol) -> Bool {
        entry.fullyQualifiedName == symbol.fullyQualifiedName
            && (entry.kind == nil || entry.kind == symbol.kind.rawValue)
    }
}
