import Foundation

/// Describes reflected predicate expression nodes and their required Mirror children.
public enum PredicateNodeMetadata {
    /// Metadata for one reflected predicate expression type.
    public struct Entry: Sendable, Hashable {
        /// The normalized expression type name.
        public let name: String
        /// The child labels required by the expression shape.
        public let requiredChildren: Set<String>

        /// Creates metadata for a predicate expression node.
        public init(name: String, requiredChildren: Set<String>) {
            self.name = name
            self.requiredChildren = requiredChildren
        }
    }

    /// The supported reflected expression names and their required child labels.
    public static let entries: [String: Entry] = Dictionary(
        uniqueKeysWithValues: [
            Entry(name: "Conjunction", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "Disjunction", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "Negation", requiredChildren: ["wrapped"]),
            Entry(name: "Comparison", requiredChildren: ["op", "lhs", "rhs"]),
            Entry(name: "Arithmetic", requiredChildren: ["op", "lhs", "rhs"]),
            Entry(name: "IntDivision", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "IntRemainder", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "Equal", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "NotEqual", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "NilLiteral", requiredChildren: []),
            Entry(name: "KeyPath", requiredChildren: ["root", "keyPath"]),
            Entry(name: "Swift.KeyPath", requiredChildren: []),
            Entry(name: "Variable", requiredChildren: ["key"]),
            Entry(name: "VariableID", requiredChildren: ["id"]),
            Entry(name: "ExpressionEvaluate", requiredChildren: ["expression", "input"]),
            Entry(name: "Value", requiredChildren: ["value"]),
            Entry(name: "NilCoalesce", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "OptionalFlatMap", requiredChildren: ["wrapped", "transform", "variable"]),
            Entry(name: "StringLocalizedStandardContains", requiredChildren: ["root", "other"]),
            Entry(name: "CollectionContainsCollection", requiredChildren: ["base", "other"]),
            Entry(name: "OSDLocalizedStandardContains", requiredChildren: ["root", "other"]),
            Entry(name: "SequenceStartsWith", requiredChildren: ["base", "prefix"]),
            Entry(name: "SequenceContains", requiredChildren: ["sequence", "element"]),
            Entry(name: "RangeExpressionContains", requiredChildren: ["range", "element"]),
            Entry(name: "ClosedRange", requiredChildren: ["lower", "upper"]),
            Entry(name: "Range", requiredChildren: ["lower", "upper"]),
            Entry(name: "Conditional", requiredChildren: ["test", "trueBranch", "falseBranch"]),
        ].map { ($0.name, $0) })

    /// Returns catalog metadata for a reflected type name, ignoring generic arguments.
    public static func entry(for typeName: String) -> Entry? {
        let outerTypeName = String(typeName.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if ["Swift.KeyPath", "Swift.WritableKeyPath", "Swift.ReferenceWritableKeyPath"].contains(outerTypeName) {
            return entries["Swift.KeyPath"]
        }
        if outerTypeName == "OpenSwiftData.OSDLocalizedStandardContains" {
            return entries["OSDLocalizedStandardContains"]
        }
        if let exact = entries[outerTypeName] { return exact }
        for prefix in ["FoundationEssentials.PredicateExpressions.", "Foundation.PredicateExpressions."] {
            guard outerTypeName.hasPrefix(prefix) else { continue }
            return entries[String(outerTypeName.dropFirst(prefix.count))]
        }
        return nil
    }
}
