import Foundation
import OSDCore

package enum PredicateRuntimeTreeBuilder {
    private final class ExpressionBinding {
        let value: Any
        let outerBindings: [UInt: ExpressionBinding]
        let capturePathRewrites: [CapturePathRewrite]

        init(
            value: Any,
            outerBindings: [UInt: ExpressionBinding],
            capturePathRewrites: [CapturePathRewrite]
        ) {
            self.value = value
            self.outerBindings = outerBindings
            self.capturePathRewrites = capturePathRewrites
        }
    }

    private struct CapturePathRewrite {
        let sourcePrefix: [String]
        let destinationPrefix: [String]

        func apply(to path: [String]) -> [String] {
            guard path.starts(with: sourcePrefix) else { return path }
            return destinationPrefix + path.dropFirst(sourcePrefix.count)
        }
    }

    package struct Result {
        package let root: RuntimePredicateNode
        package let captures: [RuntimePredicatePath: StoredValue]
    }

    package static func build<Model: PersistentModel>(
        _ value: Any,
        modelType: Model.Type,
        entity: Schema.Entity,
        schema: Schema? = nil
    ) throws -> Result {
        var captures: [RuntimePredicatePath: StoredValue] = [:]
        func visit(
            _ value: Any,
            path: [String] = [],
            bindings: [UInt: ExpressionBinding] = [:],
            capturePathRewrites: [CapturePathRewrite] = []
        ) throws -> RuntimePredicateNode {
            let typeName = String(reflecting: type(of: value))
            if let keyPath = value as? AnyKeyPath {
                return try propertyReference(
                    for: keyPath, modelType: modelType, entity: entity, schema: schema)
            }

            let mirror = Mirror(reflecting: value)
            let outerTypeName = typeName.split(separator: "<", maxSplits: 1).first.map(String.init) ?? typeName
            if outerTypeName == "FoundationEssentials.Expression" || outerTypeName == "Foundation.Expression" {
                throw SwiftDataError.unsupportedPredicate(
                    "Expression values are only supported inside ExpressionEvaluate")
            }
            if let entry = PredicateNodeMetadata.entry(for: typeName), entry.name == "ExpressionEvaluate" {
                return try visitExpressionEvaluate(
                    mirror: mirror, path: path, bindings: bindings,
                    capturePathRewrites: capturePathRewrites, visit: visit)
            }
            if let entry = PredicateNodeMetadata.entry(for: typeName), entry.name == "Variable",
                let identifier = variableIdentifier(value),
                let binding = bindings[identifier]
            {
                return try visit(
                    binding.value,
                    path: path,
                    bindings: binding.outerBindings,
                    capturePathRewrites: binding.capturePathRewrites)
            }
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
                return try propertyReference(
                    for: keyPath, modelType: modelType, entity: entity, schema: schema)
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
                    return (
                        label,
                        try visit(
                            child.value, path: path + [label], bindings: bindings,
                            capturePathRewrites: capturePathRewrites)
                    )
                }
                if name == "Value" {
                    do {
                        let rewrittenPath = capturePathRewrites.reduce(path) { $1.apply(to: $0) }
                        captures[RuntimePredicatePath(labels: rewrittenPath)] = try StoredValue(
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

    private static func visitExpressionEvaluate(
        mirror: Mirror,
        path: [String],
        bindings: [UInt: ExpressionBinding],
        capturePathRewrites: [CapturePathRewrite],
        visit: (Any, [String], [UInt: ExpressionBinding], [CapturePathRewrite]) throws -> RuntimePredicateNode
    ) throws -> RuntimePredicateNode {
        let children = Dictionary(
            uniqueKeysWithValues: mirror.children.compactMap { child in
                child.label.map { ($0, child.value) }
            })
        guard children.count == 2, let expressionValue = children["expression"], let input = children["input"] else {
            throw SwiftDataError.unsupportedPredicate("Malformed ExpressionEvaluate node")
        }
        let wrappedValue = try requiredChild("value", of: expressionValue, expectedName: "Value")
        let expressionBody = try requiredChild("expression", of: wrappedValue, expectedName: "Expression")
        let expressionVariablePack = try requiredChild("variable", of: wrappedValue, expectedName: "Expression")
        let expressionVariables = try variablePack(expressionVariablePack)
        let inputs = try predicateInputPack(input)
        guard expressionVariables.count == inputs.count else {
            throw SwiftDataError.unsupportedPredicate("ExpressionEvaluate input arity does not match its expression")
        }
        let bodyPath = path + ["expression", "value", "expression"]
        let rewrittenPath = CapturePathRewrite(
            sourcePrefix: bodyPath, destinationPrefix: path)
        let expressionCaptureRewrites = [rewrittenPath] + capturePathRewrites
        var expressionBindings = bindings
        for (expressionVariable, inputValue) in zip(expressionVariables, inputs) {
            guard let identifier = variableIdentifier(expressionVariable) else {
                throw SwiftDataError.unsupportedPredicate("Malformed expression variable identifier")
            }
            expressionBindings[identifier] = ExpressionBinding(
                value: inputValue,
                outerBindings: bindings,
                capturePathRewrites: expressionCaptureRewrites)
        }
        return try visit(
            expressionBody,
            bodyPath,
            expressionBindings,
            expressionCaptureRewrites)
    }

    private static func requiredChild(_ label: String, of value: Any, expectedName: String) throws -> Any {
        let mirror = Mirror(reflecting: value)
        let typeName = String(reflecting: type(of: value))
        let outerTypeName = typeName.split(separator: "<", maxSplits: 1).first.map(String.init) ?? typeName
        let outerName = outerTypeName.split(separator: ".").last.map(String.init) ?? outerTypeName
        guard outerName == expectedName,
            let child = mirror.children.first(where: { $0.label == label })?.value
        else {
            throw SwiftDataError.unsupportedPredicate("Malformed expression node: expected \(expectedName).\(label)")
        }
        return child
    }

    private static func predicateInputPack(_ value: Any) throws -> [Any] {
        if PredicateNodeMetadata.entry(for: String(reflecting: type(of: value))) != nil {
            return [value]
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .tuple,
            mirror.children.isEmpty
                || mirror.children.enumerated().allSatisfy({ $0.element.label == ".\($0.offset)" })
        else {
            throw SwiftDataError.unsupportedPredicate("Malformed ExpressionEvaluate input pack")
        }
        return mirror.children.map(\.value)
    }

    private static func variablePack(_ value: Any) throws -> [Any] {
        if PredicateNodeMetadata.entry(for: String(reflecting: type(of: value)))?.name == "Variable" {
            return [value]
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .tuple,
            mirror.children.isEmpty
                || mirror.children.enumerated().allSatisfy({ $0.element.label == ".\($0.offset)" })
        else {
            throw SwiftDataError.unsupportedPredicate("Malformed expression variable pack")
        }
        return mirror.children.map(\.value)
    }

    private static func variableIdentifier(_ value: Any) -> UInt? {
        let mirror = Mirror(reflecting: value)
        guard let key = mirror.children.first(where: { $0.label == "key" })?.value,
            let id = Mirror(reflecting: key).children.first(where: { $0.label == "id" })?.value
        else { return nil }
        return id as? UInt
    }

    private static func propertyReference<Model: PersistentModel>(
        for keyPath: AnyKeyPath,
        modelType: Model.Type,
        entity: Schema.Entity,
        schema: Schema?
    ) throws -> RuntimePredicateNode {
        let metadata = modelType.schemaMetadata()
        if let propertyName = modelType.propertyName(forKeyPath: keyPath),
            let property = metadata.first(where: { $0.name == propertyName }),
            property.isRelationship,
            entity.relationships.contains(where: { $0.name == property.name })
        {
            return .property(RuntimePropertyReference(name: property.name))
        }
        if let propertyName = modelType.propertyName(forKeyPath: keyPath),
            let property = metadata.first(where: { $0.name == propertyName }),
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
        if let schema,
            let destinationModelType = type(of: keyPath).rootType as? any PersistentModel.Type,
            let destinationEntityName = String(describing: destinationModelType).split(separator: ".").last.map(
                String.init),
            let destination = schema.entity(forName: destinationEntityName),
            let property = destinationModelType.schemaMetadata().first(where: { $0.keypath == keyPath }),
            !property.isRelationship,
            destination.attributes.contains(where: { $0.name == property.name }),
            destination.attributes.first(where: { $0.name == property.name })?.options.contains(.flattened) != true
        {
            return .property(RuntimePropertyReference(name: property.name))
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
        throw SwiftDataError.unsupportedPredicate(
            "Predicate key path is not a direct persisted scalar attribute: \(String(describing: keyPath)) on \(entity.name)."
        )
    }

}
