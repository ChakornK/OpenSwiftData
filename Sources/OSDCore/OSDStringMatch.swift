import Foundation

/// Portable string operations shared by SQL functions and in-memory predicate evaluation.
public enum OSDStringMatch {
    /// Applies Swift string containment with canonical-equivalence semantics.
    public static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.contains(needle)
    }

    /// Applies Swift string prefix matching with canonical-equivalence semantics.
    public static func startsWith(_ value: String, _ prefix: String) -> Bool {
        value.starts(with: prefix)
    }

    /// Applies Foundation's localized-standard substring comparison.
    public static func localizedStandardContains(_ haystack: String, _ needle: String) -> Bool {
        haystack.localizedStandardContains(needle)
    }
}
