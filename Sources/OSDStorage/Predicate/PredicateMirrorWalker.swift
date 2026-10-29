import Foundation
import OSDCore

package enum PredicateMirrorWalker {
    package indirect enum Node: Sendable, Equatable {
        case expression(name: String, children: [(String, Node)])
        case capture(typeName: String, description: String)
        case propertyReference(String)
        case typedValue(StoredValue)

        package static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.expression(lhsName, lhsChildren), .expression(rhsName, rhsChildren)):
                lhsName == rhsName && lhsChildren.elementsEqual(rhsChildren, by: ==)
            case let (.capture(lhsType, lhsValue), .capture(rhsType, rhsValue)):
                lhsType == rhsType && lhsValue == rhsValue
            case let (.propertyReference(lhsName), .propertyReference(rhsName)):
                lhsName == rhsName
            case let (.typedValue(lhsValue), .typedValue(rhsValue)):
                lhsValue == rhsValue
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

    package static func walk(
        _ value: Any,
        resolveKeyPath: (AnyKeyPath) throws -> String
    ) throws -> Node {
        func walkResolved(_ current: Any) throws -> Node {
            let mirror = Mirror(reflecting: current)
            let typeName = String(reflecting: type(of: current))
            guard let entry = PredicateNodeCatalog.entry(for: typeName) else {
                throw PredicateCatalogError.unsupportedNode(typeName)
            }
            let children = Array(mirror.children)
            if let keyPath = current as? AnyKeyPath {
                return .capture(
                    typeName: "OpenSwiftData.PropertyReference", description: try resolveKeyPath(keyPath))
            }
            if entry.name == "Swift.KeyPath", children.isEmpty {
                guard let keyPath = current as? AnyKeyPath else {
                    throw PredicateCatalogError.unsupportedNode(typeName)
                }
                return .capture(typeName: "OpenSwiftData.PropertyReference", description: try resolveKeyPath(keyPath))
            }
            try Self.validateChildren(children, entry: entry)
            var nodes: [(String, Node)] = []
            for child in children {
                guard let label = child.label else {
                    throw PredicateCatalogError.malformedNode(
                        entry.name, missingChildren: entry.requiredChildren.sorted())
                }
                let childTypeName = String(reflecting: type(of: child.value))
                if child.value is AnyKeyPath || PredicateNodeCatalog.entry(for: childTypeName) != nil {
                    nodes.append((label, try walkResolved(child.value)))
                } else if Self.isScalarCapture(childTypeName) {
                    nodes.append(
                        (label, .capture(typeName: childTypeName, description: String(describing: child.value))))
                } else {
                    throw PredicateCatalogError.unsupportedNode(childTypeName)
                }
            }
            return .expression(name: entry.name, children: nodes)
        }
        return try walkResolved(value)
    }

    private static func isScalarCapture(_ typeName: String) -> Bool {
        let name =
            typeName.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: ".").last.map(String.init) ?? typeName
        return [
            "ComparisonOperator", "ArithmeticOperator", "StringComparisonOptions",
            "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
            "UInt64", "Float", "Double", "String", "Character", "Decimal", "Date", "UUID", "Data", "URL",
        ].contains(name)
    }

    private static func walk(
        _ value: Any,
        mirror: Mirror,
        typeName: String,
        resolveKeyPath: ((AnyKeyPath) throws -> String)? = nil
    ) throws -> Node {
        guard let entry = PredicateNodeCatalog.entry(for: typeName) else {
            throw PredicateCatalogError.unsupportedNode(typeName)
        }
        let children = Array(mirror.children)
        if entry.name == "Swift.KeyPath", children.isEmpty {
            guard let keyPath = value as? AnyKeyPath else { throw PredicateCatalogError.unsupportedNode(typeName) }
            if let resolveKeyPath {
                return .capture(typeName: "OpenSwiftData.PropertyReference", description: try resolveKeyPath(keyPath))
            }
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
        try Self.validateChildren(children, entry: entry)
        var nodes: [(String, Node)] = []
        for child in children {
            guard let label = child.label else {
                throw PredicateCatalogError.malformedNode(entry.name, missingChildren: entry.requiredChildren.sorted())
            }
            let childValue = child.value
            let childTypeName = String(reflecting: type(of: childValue))
            if PredicateNodeCatalog.entry(for: childTypeName) != nil {
                nodes.append(
                    (
                        label,
                        try walk(
                            childValue, mirror: Mirror(reflecting: childValue), typeName: childTypeName,
                            resolveKeyPath: resolveKeyPath)
                    )
                )
            } else if Self.isScalarCapture(childTypeName) {
                nodes.append(
                    (label, .capture(typeName: childTypeName, description: String(describing: childValue))))
            } else {
                throw PredicateCatalogError.unsupportedNode(childTypeName)
            }
        }
        return .expression(name: entry.name, children: nodes)
    }

    private static func validateChildren(_ children: [Mirror.Child], entry: PredicateNodeCatalog.Entry) throws {
        let labels = children.compactMap(\.label)
        guard labels.count == children.count else {
            throw PredicateCatalogError.unsupportedNode("Unlabeled child in \(entry.name)")
        }
        guard Set(labels).count == labels.count else {
            throw PredicateCatalogError.unsupportedNode("Duplicate child label in \(entry.name)")
        }
        let actual = Set(labels)
        guard actual == entry.requiredChildren else {
            let missing = entry.requiredChildren.subtracting(actual).sorted()
            let unexpected = actual.subtracting(entry.requiredChildren).sorted()
            if !missing.isEmpty {
                throw PredicateCatalogError.malformedNode(entry.name, missingChildren: missing)
            }
            throw PredicateCatalogError.unsupportedNode("Unexpected child labels in \(entry.name): \(unexpected)")
        }
    }
}
