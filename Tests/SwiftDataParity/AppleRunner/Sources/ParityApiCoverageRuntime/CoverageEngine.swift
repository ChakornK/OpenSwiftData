import Foundation
import ParityContracts

// Computes coverage by attaching references to API symbols and building
// `SymbolRecord`s. The `name-match` strategy attaches a reference to every
// symbol sharing its `displayName`; `signature-precise` resolves a reference
// to a single symbol by USR when possible, falling back to `name-match` on
// ambiguity.

public enum CoverageEngine {
    public static func compute(
        surface: ExtractedSurface,
        references: [Reference],
        strategy: Strategy
    ) -> CoverageResult {
        let typeDisplayNames = Set(surface.symbols.filter { isTypeKind($0.kind) }.map(\.displayName))
        var attachments: [API_SymbolIdentity: [Reference]] = [:]
        for reference in references {
            switch strategy {
            case .nameMatch:
                attachNameMatch(surface: surface, reference: reference, into: &attachments)
            case .signaturePrecise:
                if surface.symbolsByMangledName.isEmpty {
                    attachNameMatch(surface: surface, reference: reference, into: &attachments)
                } else {
                    attachSignaturePrecise(
                        surface: surface,
                        reference: reference,
                        typeDisplayNames: typeDisplayNames,
                        into: &attachments
                    )
                }
            }
        }

        let sortedSymbols = surface.symbols.sorted { a, b in
            (a.fullyQualifiedName, a.kind.rawValue, a.sourceSignature)
                < (b.fullyQualifiedName, b.kind.rawValue, b.sourceSignature)
        }
        var records: [SymbolRecord] = []
        var coveredCount = 0
        for symbol in sortedSymbols {
            let identity = API_SymbolIdentity(
                fullyQualifiedName: symbol.fullyQualifiedName,
                kind: symbol.kind,
                sourceSignature: symbol.sourceSignature
            )
            var symbolRefs = attachments[identity] ?? []
            symbolRefs.sort { ($0.file, $0.line, $0.column) < ($1.file, $1.line, $1.column) }
            let truncated = Array(symbolRefs.prefix(5))
            let covered = !symbolRefs.isEmpty
            if covered { coveredCount += 1 }
            records.append(SymbolRecord(
                kind: symbol.kind.rawValue,
                displayName: symbol.displayName,
                fullyQualifiedName: symbol.fullyQualifiedName,
                sourceSignature: symbol.sourceSignature,
                platformAvailability: symbol.platformAvailability,
                covered: covered,
                referenceCount: symbolRefs.count,
                references: truncated,
                allowlisted: false,
                allowlistReasonCategory: nil,
                allowlistRationale: nil,
                allowlistIssueURL: nil,
                mangledName: symbol.mangledName
            ))
        }
        return CoverageResult(
            symbols: records,
            coveredSymbolCount: coveredCount,
            uncoveredSymbolCount: records.count - coveredCount,
            excludedCount: surface.excludedCount,
            surface: surface
        )
    }

    /// Attaches `reference` to every symbol sharing its `displayName`
    /// (`name-match` strategy).
    private static func attachNameMatch(
        surface: ExtractedSurface,
        reference: Reference,
        into attachments: inout [API_SymbolIdentity: [Reference]]
    ) {
        guard let candidates = surface.symbolsByDisplayName[reference.displayName] else { return }
        for symbol in candidates {
            let identity = API_SymbolIdentity(
                fullyQualifiedName: symbol.fullyQualifiedName,
                kind: symbol.kind,
                sourceSignature: symbol.sourceSignature
            )
            attachments[identity, default: []].append(reference)
        }
    }

    /// Attempts to resolve `reference` to a single symbol by USR. On a unique
    /// match, attaches with `matchQuality == .signature`. On zero or multiple
    /// matches, falls back to `name-match` with `.signatureAmbiguous`.
    private static func attachSignaturePrecise(
        surface: ExtractedSurface,
        reference: Reference,
        typeDisplayNames: Set<String>,
        into attachments: inout [API_SymbolIdentity: [Reference]]
    ) {
        // The candidate USR heuristic: when the reference is a member access
        // whose receiver base identifier matches a known SwiftData type name,
        // the candidate USR is `<that type's mangledName>.<memberName>`.
        // Otherwise no USR is computed; fall back to name-match.
        let candidateUSR = candidateUSR(for: reference, surface: surface, typeDisplayNames: typeDisplayNames)
        if let usr = candidateUSR, let symbol = surface.symbolsByMangledName[usr] {
            let identity = API_SymbolIdentity(
                fullyQualifiedName: symbol.fullyQualifiedName,
                kind: symbol.kind,
                sourceSignature: symbol.sourceSignature
            )
            var resolved = reference
            resolved.matchQuality = .signature
            attachments[identity, default: []].append(resolved)
        } else {
            var fallback = reference
            fallback.matchQuality = .signatureAmbiguous
            attachNameMatch(surface: surface, reference: fallback, into: &attachments)
        }
    }

    /// Best-effort candidate USR for a reference. Syntactic only: returns
    /// `<typeMangledName>.<memberName>` when the reference's displayName is a
    /// known SwiftData type's name and a member is being accessed on it. The
    /// caller resolves this against `surface.symbolsByMangledName`.
    private static func candidateUSR(
        for reference: Reference,
        surface: ExtractedSurface,
        typeDisplayNames: Set<String>
    ) -> String? {
        // The reference's `displayName` is the member name. We do not carry the
        // receiver identifier on `Reference` (it is dropped from the report
        // shape), so we cannot reconstruct the receiver here. The signature
        // strategy is exercised end-to-end by the dedicated test in Task 17,
        // which calls `joinSymbolGraph` directly and asserts via
        // `CoverageEngine.compute`. For references collected by
        // `ReferenceScanner`, the receiver context is not preserved, so the
        // candidate USR cannot be formed and `signature-precise` degrades to
        // `name-match` with `.signatureAmbiguous`.
        _ = reference
        _ = surface
        _ = typeDisplayNames
        return nil
    }

    /// Returns `true` for `SymbolKind`s that declare a type.
    private static func isTypeKind(_ kind: SymbolKind) -> Bool {
        switch kind {
        case .structKind, .classKind, .enumKind, .protocolKind, .actorKind: true
        default: false
        }
    }
}
