import Foundation
import OSDCore

package enum PredicateRuntimeTreeBuilder {
    package struct Result {
        package let root: RuntimePredicateNode
        package let captures: [RuntimePredicatePath: StoredValue]
    }

    package static func build<Model: PersistentModel>(
        _ value: Any,
        modelType: Model.Type,
        entity: Schema.Entity
    ) throws -> Result {
        var captures: [RuntimePredicatePath: StoredValue] = [:]
        func visit(_ value: Any, path: [String] = []) throws -> RuntimePredicateNode {
            let typeName = String(reflecting: type(of: value))
            if let keyPath = value as? AnyKeyPath {
                return try propertyReference(for: keyPath, modelType: modelType, entity: entity)
            }

            let mirror = Mirror(reflecting: value)
            guard let entry = PredicateNodeMetadata.entry(for: typeName) else {
                throw SwiftDataError.unsupportedPredicate(typeName)
            }
            let name = entry.name
            let requiredLabels = entry.requiredChildren
            let children = Array(mirror.children)
            let childLabels = children.compactMap(\.label)
            guard childLabels.count == children.count, Set(childLabels).count == childLabels.count else {
                throw SwiftDataError.unsupportedPredicate(
                    "Malformed predicate node \(name): unlabeled or duplicate children")
            }
            let labels = Set(childLabels)
            guard labels == requiredLabels else {
                throw SwiftDataError.unsupportedPredicate(
                    "Malformed predicate node \(name): expected \(requiredLabels.sorted()), found \(labels.sorted())")
            }
            if name == "KeyPath", let keyPathValue = children.first(where: { $0.label == "keyPath" })?.value,
                let keyPath = keyPathValue as? AnyKeyPath
            {
                return try propertyReference(for: keyPath, modelType: modelType, entity: entity)
            }
            if name == "KeyPath" {
                throw SwiftDataError.unsupportedPredicate(
                    "Predicate key path could not be resolved to a model property.")
            }
            if name == "Swift.KeyPath", children.isEmpty {
                throw SwiftDataError.unsupportedPredicate(
                    "Predicate key path could not be resolved to a model property.")
            }
            let converted = try children.compactMap { child -> (String, RuntimePredicateNode)? in
                guard let label = child.label else { return nil }
                let childTypeName = String(reflecting: type(of: child.value))
                if child.value is AnyKeyPath || PredicateNodeMetadata.entry(for: childTypeName) != nil {
                    return (label, try visit(child.value, path: path + [label]))
                }
                if name == "Value" {
                    do {
                        captures[RuntimePredicatePath(labels: path)] = try StoredValue(
                            predicateScalar: child.value, type: type(of: child.value))
                    } catch {
                        throw SwiftDataError.unsupportedPredicate("Unsupported predicate capture \(childTypeName)")
                    }
                }
                return (label, .capture(typeName: childTypeName, description: String(describing: child.value)))
            }
            return .expression(name: name, children: converted)
        }
        return Result(root: try visit(value), captures: captures)
    }

    private static func propertyReference<Model: PersistentModel>(
        for keyPath: AnyKeyPath,
        modelType: Model.Type,
        entity: Schema.Entity
    ) throws -> RuntimePredicateNode {
        let metadata = modelType.schemaMetadata()
        if let property = metadata.first(where: { $0.keypath == keyPath }),
            !property.isRelationship,
            entity.attributes.contains(where: { $0.name == property.name }),
            entity.attributes.first(where: { $0.name == property.name })?.options.contains(.flattened) != true
        {
            return .property(RuntimePropertyReference(name: property.name))
        }
        if let component = modelType.flattenedPropertyAdapters().first(where: {
            $0.componentKeyPath == keyPath || $0.localComponentKeyPath == keyPath
        }),
            let attribute = entity.attributes.first(where: { $0.name == component.propertyName }),
            attribute.options.contains(.flattened),
            attribute.components.contains(where: { $0.columnName == component.columnName })
        {
            return .property(RuntimePropertyReference(name: component.columnName))
        }
        let pathParts = String(describing: keyPath).split(separator: ".").map(String.init)
        if pathParts.count == 2,
            let component = modelType.flattenedPropertyAdapters().first(where: {
                $0.propertyName == pathParts[0] && $0.componentName == pathParts[1]
            }),
            entity.attributes.first(where: { $0.name == component.propertyName })?.options.contains(.flattened) == true
        {
            return .property(RuntimePropertyReference(name: component.columnName))
        }
        throw SwiftDataError.unsupportedPredicate("Predicate key path is not a direct persisted scalar attribute.")
    }

}
