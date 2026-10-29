import Foundation

/// A predicate expression for SwiftData-compatible localized-standard string containment.
public struct OSDLocalizedStandardContains<Left: StandardPredicateExpression, Right: StandardPredicateExpression>:
    StandardPredicateExpression, Codable
where Left.Output == String, Right.Output == String {
    /// The string being searched.
    public let root: Left
    /// The substring to find.
    public let other: Right

    /// Creates a localized-standard containment expression.
    public init(root: Left, other: Right) {
        self.root = root
        self.other = other
    }

    /// Evaluates the predicate using Foundation's localized-standard string comparison.
    public func evaluate(_ bindings: PredicateBindings) throws -> Bool {
        let haystack = try root.evaluate(bindings)
        let needle = try other.evaluate(bindings)
        return haystack.localizedStandardContains(needle)
    }
}

/// Creates a predicate using SwiftData-compatible localized-standard string containment.
public func localizedStandardContains<Model: PersistentModel>(
    _ keyPath: KeyPath<Model, String> & Sendable,
    _ substring: String
) -> Predicate<Model> {
    Predicate { variable in
        OSDLocalizedStandardContains(
            root: PredicateExpressions.build_KeyPath(root: variable, keyPath: keyPath),
            other: PredicateExpressions.build_Arg(substring))
    }
}
