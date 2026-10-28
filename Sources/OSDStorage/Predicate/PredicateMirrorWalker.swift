import Foundation

package enum PredicateMirrorWalker {
    package indirect enum Node: Sendable, Equatable {
        case expression(name: String, children: [(String, Node)])
        case capture(typeName: String, description: String)

        package static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.expression(lhsName, lhsChildren), .expression(rhsName, rhsChildren)):
                lhsName == rhsName && lhsChildren.elementsEqual(rhsChildren, by: ==)
            case let (.capture(lhsType, lhsValue), .capture(rhsType, rhsValue)):
                lhsType == rhsType && lhsValue == rhsValue
            default:
                false
            }
        }
    }

    package static func walk(_ value: Any) throws -> Node {
        let mirror = Mirror(reflecting: value)
        let typeName = String(reflecting: type(of: value))
        return try walk(value, mirror: mirror, typeName: typeName)
    }

    private static func walk(_ value: Any, mirror: Mirror, typeName: String) throws -> Node {
        guard let entry = PredicateNodeCatalog.entry(for: typeName) else {
            throw PredicateCatalogError.unsupportedNode(typeName)
        }
        let children = Array(mirror.children)
        let labels = Set(children.compactMap(\.label))
        if entry.name == "Swift.KeyPath", children.isEmpty {
            return .capture(typeName: typeName, description: String(describing: value))
        }
        if entry.name == "KeyPath", children.isEmpty {
            return .expression(
                name: entry.name,
                children: [
                    (
                        "root",
                        .expression(name: "Variable", children: [("key", .capture(typeName: "", description: ""))])
                    ),
                    ("keyPath", .capture(typeName: "Swift.KeyPath", description: String(describing: value))),
                ])
        }
        let missing = entry.requiredChildren.subtracting(labels).sorted()
        guard missing.isEmpty else {
            throw PredicateCatalogError.malformedNode(entry.name, missingChildren: missing)
        }
        var nodes: [(String, Node)] = []
        for child in children {
            guard let label = child.label else {
                continue
            }
            let childValue = child.value
            let childTypeName = String(reflecting: type(of: childValue))
            if PredicateNodeCatalog.entry(for: childTypeName) != nil {
                nodes.append(
                    (label, try walk(childValue, mirror: Mirror(reflecting: childValue), typeName: childTypeName)))
            } else {
                nodes.append(
                    (label, .capture(typeName: childTypeName, description: String(describing: childValue))))
            }
        }
        return .expression(name: entry.name, children: nodes)
    }
}
