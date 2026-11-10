import Foundation

/// Scenarios declared non-comparable by the parity matrix.
///
/// The runners consult this table so emitted results match the matrix: a scenario whose matrix entry
/// is entirely non-comparable is not emitted at all, and a non-comparable variant inside an otherwise
/// compared entry is emitted with an empty observation list. Reasons mirror the matrix rationale.
public enum NonComparableScenarios {
    /// One matrix rationale per declared scenario.
    public static let declared: [ScenarioID: (reasonCategory: String, rationale: String)] = [
        // Deferred behavior gaps tracked under issue #8.
        ScenarioID(suite: "FetchDescriptorParityTests", test: "defaults match SwiftData"): deferred(
            "OpenSwiftData's FetchDescriptor leaves fetchOffset nil by default; Apple's is non-nil."),
        ScenarioID(suite: "FetchDescriptorParityTests", test: "descriptors compare every option"): deferred(
            "OpenSwiftData compares descriptors with equal predicates and sorts as equal; Apple reports unequal."),
        ScenarioID(suite: "ModelContainerParityTests", test: "configurations are a set and containers compare by identity"): deferred(
            "OpenSwiftData's configuration set matches expectations; Apple's does not, and containers compare differently."),
        ScenarioID(suite: "ModelContainerParityTests", test: "erasing removes stored models and keeps the store usable"): deferred(
            "Apple traps during its post-erase save probe; OpenSwiftData completes the probe."),
        ScenarioID(suite: "StoreIdentifierParityTests", test: "the store identifier survives reopening the store"): deferred(
            "Apple regenerates the store identifier and drops the registered model on reopen; OpenSwiftData preserves both."),
        ScenarioID(suite: "UniqueConstraintParityTests", test: "duplicates inserted in one save collapse into one row"): deferred(
            "Apple keeps both duplicate rows after a single save; OpenSwiftData collapses them."),
        ScenarioID(suite: "BatchDeleteParityTests", test: "batch deletes leave pending changes and registered instances alone"): deferred(
            "OpenSwiftData marks batch-deleted saved models deleted and unregisters them; Apple leaves them registered."),
        ScenarioID(suite: "SchemaIntrospectionParityTests", test: "constraints and indices are listed by property name"): deferred(
            "Apple emits a synthetic binary column into #Index expansion; OpenSwiftData lists declared properties only."),
        ScenarioID(suite: "SchemaIntrospectionParityTests", test: "schemas round-trip through Codable and files"): deferred(
            "Apple drops indices through schema Codable round-trip; OpenSwiftData preserves them."),
        // Variants inside otherwise-compared entries.
        ScenarioID(suite: "StringPredicateParityTests", test: "string count counts characters/saved"): deferred(
            "Apple's saved-model String.count predicates match no rows or every row; OpenSwiftData counts characters."),
        ScenarioID(suite: "StringPredicateParityTests", test: "optional flatMap over a string/saved"): deferred(
            "Apple's saved-model optional flatMap and isEmpty predicates match no rows; OpenSwiftData matches."),
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
        ("deferred-behavior-gap", "\(rationale) Tracked under issue #8.")
    }
}
