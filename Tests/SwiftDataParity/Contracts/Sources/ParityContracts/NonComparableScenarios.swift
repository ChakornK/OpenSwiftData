import Foundation

/// Scenarios declared non-comparable by the parity matrix.
///
/// The runners consult this table so emitted results match the matrix: a scenario whose matrix entry
/// is entirely non-comparable is not emitted at all, and a non-comparable variant inside an otherwise
/// compared entry is emitted with an empty observation list. Reasons mirror the matrix rationale.
public enum NonComparableScenarios {
    /// One matrix rationale per declared scenario.
    public static let declared: [ScenarioID: (reasonCategory: String, rationale: String)] = [
        // Deferred behavior gaps — Apple bugs not replicated.
        ScenarioID(suite: "ModelContainerParityTests", test: "erasing removes stored models and keeps the store usable"): deferred(
            "Apple's ModelContext.save() after ModelContainer.erase() triggers an abnormal termination that stops the checkpointed probe process at step 2 (lastCompletedStep == 2, pendingSaveReturned == false); OpenSwiftData's erase() keeps the store usable so the save completes (lastCompletedStep == 4, pendingNamesAfterSave == [\"pending\"]), which is the documented intent of erase(). OpenSwiftData intentionally does not replicate Apple's crash, so the two outcomes cannot be compared."),
        ScenarioID(suite: "UniqueConstraintParityTests", test: "duplicates inserted in one save collapse into one row"): deferred(
            "Apple's surviving row is selected non-deterministically (its conflict resolver iterates a Set, whose order is not guaranteed), so the survivorsObserved set varies run to run; OpenSwiftData deterministically keeps the last insert (z/2/nil), so the survivorsObserved sets cannot be compared. The parity harness has no per-field non-comparable mechanism, so the comparable everyTrialHasOneRow field is necessarily dropped along with survivorsObserved."),
        // Variants inside otherwise-compared entries.
        ScenarioID(suite: "StringPredicateParityTests", test: "string count counts characters/saved"): deferred(
            "Apple's saved-model String.count predicate translation matches no rows for counts that should match and every row for counts that should not, contradicting Swift semantics; OpenSwiftData evaluates String.count per Swift semantics (grapheme cluster count), so the saved-model outputs cannot be compared."),
        ScenarioID(suite: "StringPredicateParityTests", test: "optional flatMap over a string/saved"): deferred(
            "Apple's saved-model Optional.flatMap and String.isEmpty predicate translation matches no rows, contradicting Swift semantics; OpenSwiftData evaluates Optional.flatMap and String.isEmpty per Swift semantics, so the saved-model outputs cannot be compared."),
    ]

    /// Returns the disposition for a scenario, or `nil` when the scenario is comparable.
    public static func disposition(for id: ScenarioID) -> ScenarioDisposition? {
        guard let entry = declared[id] else { return nil }
        return .nonComparable(reasonCategory: entry.reasonCategory, rationale: entry.rationale)
    }

    /// Splits runner results against this table: drops scenarios the matrix declares non-comparable
    /// as whole entries, and rewrites non-comparable variants inside compared entries to empty
    /// observations so both runner outputs match the matrix exactly.
    public static func apply(_ results: [ScenarioResult]) -> [ScenarioResult] {
        results.compactMap { result in
            guard let disposition = disposition(for: result.id) else { return result }
            // A non-comparable result inside an otherwise-compared entry keeps its place with no
            // observations; whole-entry non-comparables are dropped from runner output entirely.
            return isPartOfComparedEntry(result.id)
                ? ScenarioResult(id: result.id, observations: [], disposition: disposition)
                : nil
        }
    }

    /// Whether the matrix entry containing this scenario also contains comparable variants.
    ///
    /// Mirrors `parity-matrix.json`: a parameterized source case (e.g. `string count counts
    /// characters`) emits one scenario per test argument, and only some variants diverge.
    /// Entries whose scenarios are all non-comparable produce no runner emission at all.
    private static var comparedEntryStems: Set<String> {
        [
            "StringPredicateParityTests/string count counts characters",
            "StringPredicateParityTests/optional flatMap over a string",
        ]
    }

    private static func isPartOfComparedEntry(_ id: ScenarioID) -> Bool {
        comparedEntryStems.contains("\(id.suite)/\(variantStem(id.test))")
    }

    /// The parameterized-test stem of a scenario test name (text before the final `/`).
    private static func variantStem(_ test: String) -> String {
        guard let index = test.lastIndex(of: "/") else { return test }
        return String(test[..<index])
    }

    private static func deferred(_ rationale: String) -> (String, String) {
        ("deferred-behavior-gap", rationale)
    }
}
