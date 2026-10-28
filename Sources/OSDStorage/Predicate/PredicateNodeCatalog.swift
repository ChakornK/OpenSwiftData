import Foundation

package enum PredicateNodeCatalog {
    package struct Entry: Sendable, Hashable {
        package let name: String
        package let requiredChildren: Set<String>

        package init(name: String, requiredChildren: Set<String>) {
            self.name = name
            self.requiredChildren = requiredChildren
        }
    }

    package static let entries: [String: Entry] = Dictionary(
        uniqueKeysWithValues: [
            Entry(name: "Conjunction", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "Disjunction", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "Negation", requiredChildren: ["expression"]),
            Entry(name: "Comparison", requiredChildren: ["op", "lhs", "rhs"]),
            Entry(name: "KeyPath", requiredChildren: ["root", "keyPath"]),
            Entry(name: "Variable", requiredChildren: ["key"]),
            Entry(name: "VariableID", requiredChildren: ["id"]),
            Entry(name: "Value", requiredChildren: ["value"]),
            Entry(name: "NilCoalesce", requiredChildren: ["lhs", "rhs"]),
            Entry(name: "CollectionContainsCollection", requiredChildren: ["base", "other"]),
            Entry(name: "SequenceContains", requiredChildren: ["sequence", "element"]),
        ].map { ($0.name, $0) })

    package static func entry(for typeName: String) -> Entry? {
        let outerTypeName = typeName.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let nodeName = outerTypeName.split(separator: ".").last else {
            return nil
        }
        return entries[String(nodeName)]
    }
}

package enum PredicateCatalogError: Error, Equatable {
    case unsupportedNode(String)
    case malformedNode(String, missingChildren: [String])
}
