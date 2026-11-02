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
        package let identifierCaptures: [RuntimePredicatePath: PersistentIdentifier]
    }

    package static func build<Model: PersistentModel>(
        _ value: Any,
        modelType: Model.Type,
        entity: Schema.Entity,
        schema: Schema? = nil,
        modelTypeForEntity: (String) -> (any PersistentModel.Type)? = { _ in nil }
    ) throws -> Result {
        var captures: [RuntimePredicatePath: StoredValue] = [:]
        var identifierCaptures: [RuntimePredicatePath: PersistentIdentifier] = [:]
        var unsignedCollectionBoundPaths = Set<RuntimePredicatePath>()
        var activeModelType: any PersistentModel.Type = modelType
        var activeEntity = entity
        var activeCollectionName: String?
        var activeRelationshipName: String?
        var activePredicateRootType: Any.Type = Model.self
        var collectionVariableScopes: [UInt] = []
        func capturedPartialIntegerRange(_ value: Any) throws -> (
            name: String, boundName: String, value: Any, stored: StoredValue
        )? {
            let reflectedName = String(reflecting: type(of: value))
            let name =
                reflectedName.split(separator: "<", maxSplits: 1).first
                .map(String.init)?.split(separator: ".").last.map(String.init) ?? reflectedName
            let boundName: String
            switch name {
            case "PartialRangeFrom": boundName = "lowerBound"
            case "PartialRangeThrough", "PartialRangeUpTo": boundName = "upperBound"
            default: return nil
            }
            let children = Array(Mirror(reflecting: value).children)
            guard children.count == 1, children[0].label == boundName else {
                throw SwiftDataError.unsupportedPredicate("Malformed captured \(name) range")
            }
            let stored = try StoredValue(predicateScalar: children[0].value, type: type(of: children[0].value))
            guard case .int = stored else {
                throw SwiftDataError.unsupportedPredicate("Partial range bounds require integer captures")
            }
            return (name, boundName, children[0].value, stored)
        }
        func keyPathRootVariableID(_ value: Any) -> UInt? {
            guard let root = Mirror(reflecting: value).children.first(where: { $0.label == "root" })?.value else {
                return nil
            }
            return variableIdentifier(root)
        }
        func relationshipTraversal(
            _ node: RuntimePredicateNode,
            from ownerEntity: Schema.Entity
        ) throws -> (names: [String], entity: Schema.Entity, modelType: any PersistentModel.Type)? {
            switch node {
            case let .property(reference):
                var components = reference.name.split(separator: ".").map(String.init)
                let scopePrefix = activeRelationshipName?.split(separator: ".").map(String.init) ?? []
                if !scopePrefix.isEmpty, components.starts(with: scopePrefix) {
                    components = Array(components.dropFirst(scopePrefix.count))
                }
                var currentEntity = ownerEntity
                var currentModelType: (any PersistentModel.Type)?
                for name in components {
                    guard let schema,
                        let relationship = currentEntity.relationships.first(where: {
                            $0.name == name && !$0.isToMany
                        }),
                        supportsToOnePredicate(relationship, ownerEntity: currentEntity, schema: schema),
                        let destinationEntity = schema.entity(forName: relationship.destination),
                        let destinationModelType = modelTypeForEntity(destinationEntity.name)
                    else { return nil }
                    currentEntity = destinationEntity
                    currentModelType = destinationModelType
                }
                guard let currentModelType else { return nil }
                return (components, currentEntity, currentModelType)
            case let .expression(name, children) where name == "OptionalFlatMap":
                guard let wrapped = children.first(where: { $0.0 == "wrapped" })?.1,
                    let transform = children.first(where: { $0.0 == "transform" })?.1,
                    let base = try relationshipTraversal(wrapped, from: ownerEntity)
                else { return nil }
                if case let .property(transformProperty) = transform,
                    let relationshipName = transformProperty.name.split(separator: ".").last.map(String.init),
                    let relationship = base.entity.relationships.first(where: {
                        $0.name == relationshipName && !$0.isToMany
                    }),
                    let schema,
                    supportsToOnePredicate(relationship, ownerEntity: base.entity, schema: schema),
                    let destinationEntity = schema.entity(forName: relationship.destination),
                    let destinationModelType = modelTypeForEntity(destinationEntity.name)
                {
                    return (base.names + [relationship.name], destinationEntity, destinationModelType)
                }
                if case .expression(name: "OptionalFlatMap", children: _) = transform,
                    let nested = try relationshipTraversal(transform, from: base.entity)
                {
                    return (base.names + nested.names, nested.entity, nested.modelType)
                }
                return base
            default:
                return nil
            }
        }
        func visit(
            _ value: Any,
            path: [String] = [],
            bindings: [UInt: ExpressionBinding] = [:],
            capturePathRewrites: [CapturePathRewrite] = []
        ) throws -> RuntimePredicateNode {
            let typeName = String(reflecting: type(of: value))
            if let keyPath = value as? AnyKeyPath {
                return try propertyReference(
                    for: keyPath, modelType: activeModelType, entity: activeEntity, schema: schema,
                    collectionName: activeCollectionName, relationshipName: activeRelationshipName,
                    expectedRootType: activePredicateRootType)
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
            if name == "Value",
                let capturedValue = children.first(where: { $0.label == "value" })?.value,
                let identifier = capturedValue as? PersistentIdentifier
            {
                let rewrittenPath = capturePathRewrites.reduce(path) { $1.apply(to: $0) }
                identifierCaptures[RuntimePredicatePath(labels: rewrittenPath)] = identifier
                return .expression(
                    name: "Value",
                    children: [
                        (
                            "value",
                            .capture(
                                typeName: String(reflecting: PersistentIdentifier.self),
                                description: "persistent identifier")
                        )
                    ])
            }
            if name == "Value",
                let capturedValue = children.first(where: { $0.label == "value" })?.value,
                let range = try capturedPartialIntegerRange(capturedValue)
            {
                let boundPath = capturePathRewrites.reduce(path + [range.boundName]) { $1.apply(to: $0) }
                captures[RuntimePredicatePath(labels: boundPath)] = range.stored
                return .expression(
                    name: range.name,
                    children: [
                        (
                            range.boundName,
                            .expression(
                                name: "Value",
                                children: [
                                    (
                                        "value",
                                        .capture(
                                            typeName: String(reflecting: type(of: range.value)),
                                            description: String(describing: range.value))
                                    )
                                ])
                        )
                    ])
            }
            if name == "SequenceContainsWhere" || name == "SequenceAllSatisfy" {
                guard let schema,
                    let sequence = children.first(where: { $0.label == "sequence" })?.value,
                    let test = children.first(where: { $0.label == "test" })?.value,
                    let variable = children.first(where: { $0.label == "variable" })?.value,
                    let sequenceVariableID = variableIdentifier(variable),
                    let sequenceRootID = keyPathRootVariableID(sequence)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Collection quantifiers require a to-many relationship.")
                }
                if collectionVariableScopes.isEmpty {
                    collectionVariableScopes.append(sequenceRootID)
                }
                guard collectionVariableScopes.count <= 3,
                    collectionVariableScopes.last == sequenceRootID
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Nested collection quantifier depth or variable scope is unsupported.")
                }
                let sequenceNode = try visit(
                    sequence, path: path + ["sequence"], bindings: bindings,
                    capturePathRewrites: capturePathRewrites)
                guard case let .property(sequenceProperty) = sequenceNode else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Collection quantifiers require a relationship collection key path.")
                }
                let collectionParts = sequenceProperty.name.split(separator: ".").map(String.init)
                guard let collectionName = collectionParts.last else {
                    throw SwiftDataError.unsupportedPredicate("Collection quantifier has an empty collection path.")
                }
                let activePrefix = activeRelationshipName?.split(separator: ".").map(String.init) ?? []
                let ownerParts = Array(collectionParts.dropLast())
                let localOwnerParts =
                    ownerParts.starts(with: activePrefix)
                    ? Array(ownerParts.dropFirst(activePrefix.count)) : ownerParts
                if name == "SequenceAllSatisfy", collectionVariableScopes.count == 1, localOwnerParts.isEmpty,
                    codableCollectionName(sequenceNode, entity: activeEntity) == collectionName
                {
                    let testTypeName = String(reflecting: type(of: test))
                    guard let comparison = PredicateNodeMetadata.entry(for: testTypeName) else {
                        throw SwiftDataError.unsupportedPredicate("Unsupported Codable collection allSatisfy body.")
                    }
                    let testFields = Dictionary(
                        uniqueKeysWithValues: Mirror(reflecting: test).children.compactMap { child in
                            child.label.map { ($0, child.value) }
                        })
                    guard let lhs = testFields["lhs"], let rhs = testFields["rhs"] else {
                        throw SwiftDataError.unsupportedPredicate("Malformed scalar collection allSatisfy body.")
                    }
                    let value: Any
                    let elementIsLeft: Bool
                    if variableIdentifier(lhs) == sequenceVariableID, variableIdentifier(rhs) == nil {
                        value = rhs
                        elementIsLeft = true
                    } else if variableIdentifier(rhs) == sequenceVariableID, variableIdentifier(lhs) == nil {
                        value = lhs
                        elementIsLeft = false
                    } else {
                        throw SwiftDataError.unsupportedPredicate(
                            "Codable collection allSatisfy must compare its element to one captured scalar.")
                    }
                    let operationName: String
                    if comparison.name == "Equal" || comparison.name == "NotEqual" {
                        operationName = comparison.name
                    } else if comparison.name == "Comparison", let operatorNode = testFields["op"] {
                        let reflectedOperator =
                            String(describing: operatorNode).split(separator: ".").last.map(String.init) ?? ""
                        guard
                            ["lessThan", "lessThanOrEqual", "greaterThan", "greaterThanOrEqual"]
                                .contains(reflectedOperator),
                            let elementType = activeEntity.attributes.first(where: { $0.name == collectionName })
                                .map({ Self.codableScalarCollectionElementType($0.type) }) ?? nil,
                            ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt64"]
                                .contains(elementType)
                        else {
                            throw SwiftDataError.unsupportedPredicate(
                                "Codable collection allSatisfy ordering supports integer elements only.")
                        }
                        operationName = elementIsLeft ? reflectedOperator : Self.reversedComparison(reflectedOperator)
                    } else {
                        throw SwiftDataError.unsupportedPredicate(
                            "Codable collection allSatisfy supports direct scalar comparisons only.")
                    }
                    let isNotEqual = operationName == "NotEqual"
                    let valuePath = isNotEqual ? path + ["wrapped", "element"] : path + ["value"]
                    let unsignedBoundPath = RuntimePredicatePath(
                        labels: capturePathRewrites.reduce(valuePath) { $1.apply(to: $0) })
                    let usesUnsignedBound =
                        !isNotEqual
                        && ["UInt", "UInt64"].contains(
                            activeEntity.attributes.first(where: { $0.name == collectionName })
                                .flatMap { Self.codableScalarCollectionElementType($0.type) })
                    if usesUnsignedBound { unsignedCollectionBoundPaths.insert(unsignedBoundPath) }
                    let valueNode: RuntimePredicateNode
                    do {
                        valueNode = try visit(
                            value, path: valuePath, bindings: bindings,
                            capturePathRewrites: capturePathRewrites)
                    } catch {
                        unsignedCollectionBoundPaths.remove(unsignedBoundPath)
                        throw error
                    }
                    unsignedCollectionBoundPaths.remove(unsignedBoundPath)
                    if operationName == "Equal" {
                        return .expression(
                            name: "OSDScalarCollectionAllEqual",
                            children: [("sequence", sequenceNode), ("value", valueNode)])
                    }
                    if isNotEqual {
                        let contains = RuntimePredicateNode.expression(
                            name: "SequenceContains",
                            children: [("sequence", sequenceNode), ("element", valueNode)])
                        return .expression(name: "Negation", children: [("wrapped", contains)])
                    }
                    return .expression(
                        name:
                            "OSDScalarCollectionAll\(operationName.prefix(1).uppercased())\(operationName.dropFirst())",
                        children: [("sequence", sequenceNode), ("value", valueNode)])
                }
                let collectionOwner: (entity: Schema.Entity, modelType: any PersistentModel.Type)
                if localOwnerParts.isEmpty {
                    collectionOwner = (activeEntity, activeModelType)
                } else if let traversal = try relationshipTraversal(
                    .property(RuntimePropertyReference(name: localOwnerParts.joined(separator: "."))),
                    from: activeEntity)
                {
                    collectionOwner = (traversal.entity, traversal.modelType)
                } else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Collection quantifiers require owning to-one relationships before the collection.")
                }
                let optionalOwnerPathDepth = ownerParts.filter { !$0.hasSuffix("[]") }.count
                guard
                    let relationship = collectionOwner.entity.relationships.first(where: {
                        $0.name == collectionName && $0.isToMany
                    }),
                    supportsCollectionPredicate(relationship, schema: schema),
                    !(name == "SequenceAllSatisfy" && optionalOwnerPathDepth > 1 && relationship.inverse != nil),
                    collectionVariableScopes.count == 1
                        || ((collectionVariableScopes.count == 2 || collectionVariableScopes.count == 3)
                            && localOwnerParts.isEmpty
                            && supportsCollectionPredicate(relationship, schema: schema))
                        || (localOwnerParts.isEmpty && relationship.inverse == nil),
                    let destinationEntity = schema.entity(forName: relationship.destination),
                    let destinationModelType = modelTypeForEntity(destinationEntity.name)
                else {
                    throw SwiftDataError.unsupportedPredicate(
                        "Collection quantifier requires a supported to-many relationship.")
                }
                let previousModelType = activeModelType
                let previousEntity = activeEntity
                let previousCollectionName = activeCollectionName
                let previousPredicateRootType = activePredicateRootType
                let fullCollectionPath =
                    previousCollectionName.map { "\($0)[].\(sequenceProperty.name)" }
                    ?? sequenceProperty.name
                activeModelType = destinationModelType
                activeEntity = destinationEntity
                activeCollectionName = fullCollectionPath
                activePredicateRootType = destinationModelType
                collectionVariableScopes.append(sequenceVariableID)
                let testNode: RuntimePredicateNode
                do {
                    testNode = try visit(
                        test, path: path + ["test"], bindings: bindings,
                        capturePathRewrites: capturePathRewrites)
                } catch {
                    collectionVariableScopes.removeLast()
                    activeModelType = previousModelType
                    activeEntity = previousEntity
                    activeCollectionName = previousCollectionName
                    activePredicateRootType = previousPredicateRootType
                    throw error
                }
                collectionVariableScopes.removeLast()
                activeModelType = previousModelType
                activeEntity = previousEntity
                activeCollectionName = previousCollectionName
                activePredicateRootType = previousPredicateRootType
                return .expression(
                    name: name == "SequenceAllSatisfy" ? "OSDSequenceAllSatisfy" : "OSDSequenceContainsWhere",
                    children: [
                        (
                            "sequence",
                            collectionVariableScopes.count > 1
                                ? .property(
                                    RuntimePropertyReference(
                                        name: fullCollectionPath))
                                : sequenceNode
                        ),
                        ("test", testNode),
                    ])
            }
            if name == "OptionalFlatMap" {
                guard schema != nil else {
                    throw SwiftDataError.unsupportedPredicate("Malformed OptionalFlatMap relationship predicate")
                }
                guard let wrapped = children.first(where: { $0.label == "wrapped" })?.value,
                    let transform = children.first(where: { $0.label == "transform" })?.value,
                    let variable = children.first(where: { $0.label == "variable" })?.value,
                    let variableID = variableIdentifier(variable)
                else {
                    throw SwiftDataError.unsupportedPredicate("Malformed OptionalFlatMap relationship predicate")
                }
                let wrappedNode = try visit(
                    wrapped, path: path + ["wrapped"], bindings: bindings,
                    capturePathRewrites: capturePathRewrites)
                if case let .property(reference) = wrappedNode,
                    let propertyName = reference.name.split(separator: ".").last.map(String.init),
                    let wrappedAttribute = activeEntity.attributes.first(where: { $0.name == propertyName }),
                    !wrappedAttribute.options.contains(.codable),
                    !wrappedAttribute.options.contains(.flattened),
                    let transformMetadata = PredicateNodeMetadata.entry(
                        for: String(reflecting: type(of: transform)))
                {
                    let operation: (nodeName: String, receiverLabel: String, operandLabel: String)? =
                        switch transformMetadata.name {
                        case "CollectionContainsCollection": ("CollectionContainsCollection", "base", "other")
                        case "SequenceStartsWith": ("SequenceStartsWith", "base", "prefix")
                        default: nil
                        }
                    if let operation {
                        let transformChildren = Array(Mirror(reflecting: transform).children)
                        let transformLabels = transformChildren.compactMap(\.label)
                        guard transformLabels.count == transformChildren.count,
                            Set(transformLabels).count == transformLabels.count,
                            Set(transformLabels) == transformMetadata.requiredChildren
                        else {
                            throw SwiftDataError.unsupportedPredicate(
                                "Malformed optional String operation \(operation.nodeName).")
                        }
                        let transformFields = Dictionary(
                            uniqueKeysWithValues: zip(transformLabels, transformChildren.map(\.value)))
                        guard let base = transformFields[operation.receiverLabel],
                            variableIdentifier(base) == variableID,
                            let operand = transformFields[operation.operandLabel]
                        else {
                            throw SwiftDataError.unsupportedPredicate(
                                "Optional String operations must use the bound value as the receiver.")
                        }
                        let captureRewrite = CapturePathRewrite(
                            sourcePrefix: path + ["transform", operation.operandLabel],
                            destinationPrefix: path + [operation.operandLabel])
                        let operandNode = try visit(
                            operand, path: path + [operation.operandLabel], bindings: bindings,
                            capturePathRewrites: [captureRewrite] + capturePathRewrites)
                        return .expression(
                            name: operation.nodeName,
                            children: [
                                (operation.receiverLabel, wrappedNode),
                                (operation.operandLabel, operandNode),
                            ])
                    }
                    if ["Comparison", "Equal", "NotEqual"].contains(transformMetadata.name) {
                        let transformChildren = Array(Mirror(reflecting: transform).children)
                        let transformLabels = transformChildren.compactMap(\.label)
                        guard transformLabels.count == transformChildren.count,
                            Set(transformLabels).count == transformLabels.count,
                            Set(transformLabels) == transformMetadata.requiredChildren
                        else {
                            throw SwiftDataError.unsupportedPredicate(
                                "Malformed optional scalar comparison.")
                        }
                        let rewritten = try transformChildren.compactMap { child -> (String, RuntimePredicateNode)? in
                            guard let label = child.label else { return nil }
                            if variableIdentifier(child.value) == variableID {
                                return (label, wrappedNode)
                            }
                            if label == "op" {
                                return (
                                    label,
                                    .capture(
                                        typeName: String(reflecting: type(of: child.value)),
                                        description: String(describing: child.value))
                                )
                            }
                            let captureRewrite = CapturePathRewrite(
                                sourcePrefix: path + ["transform", label],
                                destinationPrefix: path + [label])
                            return (
                                label,
                                try visit(
                                    child.value,
                                    path: path + [label],
                                    bindings: bindings,
                                    capturePathRewrites: [captureRewrite] + capturePathRewrites)
                            )
                        }
                        return .expression(name: transformMetadata.name, children: rewritten)
                    }
                }
                if codableCollectionName(wrappedNode, entity: activeEntity) != nil {
                    var scopedBindings = bindings
                    scopedBindings[variableID] = ExpressionBinding(
                        value: wrapped,
                        outerBindings: bindings,
                        capturePathRewrites: capturePathRewrites)
                    let transformNode = try visit(
                        transform, path: path + ["transform"], bindings: scopedBindings,
                        capturePathRewrites: capturePathRewrites)
                    return .expression(
                        name: name,
                        children: [
                            ("wrapped", wrappedNode),
                            ("transform", transformNode),
                            (
                                "variable",
                                try visit(
                                    variable, path: path + ["variable"], bindings: bindings,
                                    capturePathRewrites: capturePathRewrites)
                            ),
                        ])
                }
                guard let traversal = try relationshipTraversal(wrappedNode, from: activeEntity) else {
                    throw SwiftDataError.unsupportedPredicate(
                        "OptionalFlatMap requires a supported to-one relationship path.")
                }
                let previousModelType = activeModelType
                let previousEntity = activeEntity
                let previousRelationshipName = activeRelationshipName
                let previousPredicateRootType = activePredicateRootType
                activeModelType = traversal.modelType
                activeEntity = traversal.entity
                let previousPath = previousRelationshipName?.split(separator: ".").map(String.init) ?? []
                let fullPath =
                    traversal.names.starts(with: previousPath)
                    ? traversal.names : previousPath + traversal.names
                activeRelationshipName = fullPath.joined(separator: ".")
                activePredicateRootType = traversal.modelType
                let transformNode: RuntimePredicateNode
                do {
                    transformNode = try visit(
                        transform, path: path + ["transform"], bindings: bindings,
                        capturePathRewrites: capturePathRewrites)
                } catch {
                    activeModelType = previousModelType
                    activeEntity = previousEntity
                    activeRelationshipName = previousRelationshipName
                    activePredicateRootType = previousPredicateRootType
                    throw error
                }
                activeModelType = previousModelType
                activeEntity = previousEntity
                activeRelationshipName = previousRelationshipName
                activePredicateRootType = previousPredicateRootType
                return .expression(
                    name: name,
                    children: [
                        ("wrapped", wrappedNode),
                        ("transform", transformNode),
                        (
                            "variable",
                            try visit(
                                variable, path: path + ["variable"], bindings: bindings,
                                capturePathRewrites: capturePathRewrites)
                        ),
                    ])
            }
            if name == "KeyPath",
                let keyPathValue = children.first(where: { $0.label == "keyPath" })?.value,
                let keyPath = keyPathValue as? AnyKeyPath,
                ObjectIdentifier(type(of: keyPath).valueType) == ObjectIdentifier(Bool.self),
                isArrayOrSetType(type(of: keyPath).rootType),
                let root = children.first(where: { $0.label == "root" })?.value
            {
                let rootNode = try visit(
                    root, path: path + ["root"], bindings: bindings,
                    capturePathRewrites: capturePathRewrites)
                if case let .property(reference) = rootNode,
                    let propertyName = reference.name.split(separator: ".").last.map(String.init),
                    let attribute = activeEntity.attributes.first(where: { $0.name == propertyName }),
                    attribute.options.contains(.codable),
                    Self.codableScalarCollectionElementType(attribute.type) != nil,
                    let propertyKeyPath = activeModelType.schemaMetadata().first(where: { $0.name == propertyName })?
                        .keypath,
                    matchesCollectionRoot(
                        type(of: propertyKeyPath).valueType,
                        computedRoot: type(of: keyPath).rootType)
                {
                    return .expression(name: "OSDCodableCollectionIsEmpty", children: [("collection", rootNode)])
                }
                if case let .property(reference) = rootNode,
                    let collectionName = reference.name.split(separator: ".").last.map(String.init),
                    let relationship = activeEntity.relationships.first(where: {
                        $0.name == collectionName && $0.isToMany
                    }),
                    let schema,
                    supportsCollectionPredicate(relationship, schema: schema),
                    let metadata = activeModelType.schemaMetadata().first(where: { $0.name == collectionName })?
                        .keypath,
                    matchesCollectionRoot(
                        type(of: metadata).valueType, computedRoot: type(of: keyPath).rootType)
                {
                    return .expression(name: "OSDSequenceIsEmpty", children: [("sequence", rootNode)])
                }
            }
            if name == "KeyPath",
                let keyPathValue = children.first(where: { $0.label == "keyPath" })?.value,
                let keyPath = keyPathValue as? AnyKeyPath,
                ObjectIdentifier(type(of: keyPath).valueType) == ObjectIdentifier(Int.self),
                isArrayOrSetType(type(of: keyPath).rootType),
                let root = children.first(where: { $0.label == "root" })?.value
            {
                let rootNode = try visit(
                    root, path: path + ["root"], bindings: bindings,
                    capturePathRewrites: capturePathRewrites)
                if case let .property(reference) = rootNode,
                    let propertyName = reference.name.split(separator: ".").last.map(String.init),
                    let attribute = activeEntity.attributes.first(where: { $0.name == propertyName }),
                    attribute.options.contains(.codable),
                    Self.codableScalarCollectionElementType(attribute.type) != nil,
                    let propertyKeyPath = activeModelType.schemaMetadata().first(where: { $0.name == propertyName })?
                        .keypath,
                    matchesCollectionRoot(
                        type(of: propertyKeyPath).valueType,
                        computedRoot: type(of: keyPath).rootType)
                {
                    return .expression(name: "OSDCodableCollectionCount", children: [("collection", rootNode)])
                }
            }
            if name == "KeyPath",
                let keyPathValue = children.first(where: { $0.label == "keyPath" })?.value,
                let keyPath = keyPathValue as? AnyKeyPath,
                ObjectIdentifier(type(of: keyPath).valueType) == ObjectIdentifier(Int.self),
                isArrayOrSetType(type(of: keyPath).rootType),
                let root = children.first(where: { $0.label == "root" })?.value
            {
                let rootNode = try visit(
                    root, path: path + ["root"], bindings: bindings,
                    capturePathRewrites: capturePathRewrites)
                if case let .property(reference) = rootNode,
                    let collectionName = reference.name.split(separator: ".").last.map(String.init),
                    let relationship = activeEntity.relationships.first(where: {
                        $0.name == collectionName && $0.isToMany
                    }),
                    let schema,
                    supportsCollectionPredicate(relationship, schema: schema),
                    let metadata = activeModelType.schemaMetadata().first(where: { $0.name == collectionName })?
                        .keypath,
                    ObjectIdentifier(type(of: metadata).valueType) == ObjectIdentifier(type(of: keyPath).rootType)
                {
                    return .expression(name: "OSDSequenceCount", children: [("sequence", rootNode)])
                }
            }
            if name == "KeyPath", let keyPathValue = children.first(where: { $0.label == "keyPath" })?.value,
                let keyPath = keyPathValue as? AnyKeyPath
            {
                return try propertyReference(
                    for: keyPath, modelType: activeModelType, entity: activeEntity, schema: schema,
                    collectionName: activeCollectionName, relationshipName: activeRelationshipName,
                    expectedRootType: activePredicateRootType)
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
                        let capturePath = RuntimePredicatePath(labels: rewrittenPath)
                        if unsignedCollectionBoundPaths.contains(capturePath),
                            let unsigned = unsignedIntegerValue(child.value)
                        {
                            captures[capturePath] = .text(String(unsigned))
                        } else {
                            captures[capturePath] = try StoredValue(
                                predicateScalar: child.value, type: type(of: child.value))
                        }
                    } catch {
                        throw SwiftDataError.unsupportedPredicate("Unsupported predicate capture \(childTypeName)")
                    }
                }
                return (label, .capture(typeName: childTypeName, description: String(describing: child.value)))
            }
            return .expression(name: name, children: converted)
        }
        return Result(root: try visit(value), captures: captures, identifierCaptures: identifierCaptures)
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

    private static func unsignedIntegerValue(_ value: Any) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? UInt { return UInt64(value) }
        return nil
    }

    private static func isArrayOrSetType(_ type: Any.Type) -> Bool {
        let name = String(reflecting: type)
        return name.hasPrefix("Swift.Array<") || name.hasPrefix("Swift.Set<")
    }

    private static func matchesCollectionRoot(_ valueType: Any.Type, computedRoot: Any.Type) -> Bool {
        let valueName = String(reflecting: valueType)
        let rootName = String(reflecting: computedRoot)
        if valueName == rootName { return true }
        return valueName == "Swift.Optional<\(rootName)>"
    }

    private static func reversedComparison(_ operation: String) -> String {
        switch operation {
        case "lessThan": "greaterThan"
        case "lessThanOrEqual": "greaterThanOrEqual"
        case "greaterThan": "lessThan"
        case "greaterThanOrEqual": "lessThanOrEqual"
        default: operation
        }
    }

    private static func supportsToOnePredicate(
        _ relationship: Schema.Relationship,
        ownerEntity: Schema.Entity,
        schema: Schema
    ) -> Bool {
        guard let inverseName = relationship.inverse else { return true }
        guard let inverse = schema.relationshipDeclaration(named: inverseName, onOrBelow: relationship.destination),
            !inverse.relationship.isToMany
        else { return false }
        let ownerName =
            schema.relationshipStorageMapping(
                modelEntityName: ownerEntity.name, relationshipName: relationship.name)?.declaringEntityName
            ?? ownerEntity.name
        let inverseOwnerName = "\(inverse.entityName).\(inverse.relationship.name)"
        return ownerName.utf8.lexicographicallyPrecedes(inverseOwnerName.utf8)
            || schema.relationshipStorageMapping(
                modelEntityName: inverse.entityName, relationshipName: inverse.relationship.name) != nil
    }

    private static func supportsCollectionPredicate(_ relationship: Schema.Relationship, schema: Schema) -> Bool {
        guard let inverseName = relationship.inverse else { return true }
        guard let inverse = schema.relationshipDeclaration(named: inverseName, onOrBelow: relationship.destination)
        else { return false }
        if inverse.relationship.isToMany { return true }
        return schema.relationshipStorageMapping(
            modelEntityName: inverse.entityName, relationshipName: inverse.relationship.name) != nil
    }

    private static func codableCollectionName(
        _ node: RuntimePredicateNode,
        entity: Schema.Entity
    ) -> String? {
        guard case let .property(reference) = node,
            let propertyName = reference.name.split(separator: ".").last.map(String.init),
            let attribute = entity.attributes.first(where: { $0.name == propertyName }),
            attribute.options.contains(.codable),
            codableScalarCollectionElementType(attribute.type) != nil
        else { return nil }
        return propertyName
    }

    private static func codableScalarCollectionElementType(_ typeName: String) -> String? {
        let unwrapped = typeName.hasSuffix("?") ? String(typeName.dropLast()) : typeName
        guard let opening = unwrapped.firstIndex(of: "<"), unwrapped.last == ">" else { return nil }
        let collectionName = unwrapped[..<opening].split(separator: ".").last.map(String.init) ?? ""
        guard collectionName == "Array" || collectionName == "Set" else { return nil }
        let rawElement = String(
            unwrapped[unwrapped.index(after: opening)..<unwrapped.index(before: unwrapped.endIndex)])
        let elementName = rawElement.split(separator: ".").last.map(String.init) ?? rawElement
        guard
            [
                "String", "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
                "UInt32", "UInt64",
            ].contains(elementName)
        else { return nil }
        return elementName
    }

    private static func propertyReference(
        for keyPath: AnyKeyPath,
        modelType: any PersistentModel.Type,
        entity: Schema.Entity,
        schema: Schema?,
        collectionName: String? = nil,
        relationshipName: String? = nil,
        expectedRootType: Any.Type
    ) throws -> RuntimePredicateNode {
        let keyPathRootType = type(of: keyPath).rootType
        if ObjectIdentifier(type(of: keyPath).valueType) == ObjectIdentifier(PersistentIdentifier.self),
            ObjectIdentifier(keyPathRootType) == ObjectIdentifier(expectedRootType),
            modelType.propertyName(forKeyPath: keyPath) == nil
        {
            let path = relationshipName?.split(separator: ".").map(String.init) ?? []
            let name = (path + [PredicatePlanProperty.persistentIdentifier]).joined(separator: ".")
            return .property(RuntimePropertyReference(name: name))
        }
        if let schema,
            ObjectIdentifier(keyPathRootType) == ObjectIdentifier(expectedRootType),
            let destinationModelType = keyPathRootType as? any PersistentModel.Type,
            let destinationEntityName = String(describing: destinationModelType).split(separator: ".").last.map(
                String.init),
            let destination = schema.entity(forName: destinationEntityName),
            let property = destinationModelType.schemaMetadata().first(where: { $0.keypath == keyPath }),
            !property.isRelationship,
            destination.attributes.contains(where: { $0.name == property.name }),
            destination.attributes.first(where: { $0.name == property.name })?.options.contains(.flattened) != true
        {
            return .property(
                RuntimePropertyReference(
                    name: collectionName.map { "\($0)[].\(property.name)" }
                        ?? relationshipName.map { "\($0).\(property.name)" }
                        ?? property.name))
        }
        let metadata = modelType.schemaMetadata()
        if let propertyName = modelType.propertyName(forKeyPath: keyPath),
            let property = metadata.first(where: { $0.name == propertyName }),
            property.isRelationship,
            entity.relationships.contains(where: { $0.name == property.name })
        {
            return .property(
                RuntimePropertyReference(
                    name: relationshipName.map { "\($0).\(property.name)" } ?? property.name))
        }
        if let propertyName = modelType.propertyName(forKeyPath: keyPath),
            let property = metadata.first(where: { $0.name == propertyName }),
            !property.isRelationship,
            entity.attributes.contains(where: { $0.name == property.name }),
            entity.attributes.first(where: { $0.name == property.name })?.options.contains(.flattened) != true
        {
            return .property(
                RuntimePropertyReference(
                    name: collectionName.map { "\($0)[].\(property.name)" }
                        ?? relationshipName.map { "\($0).\(property.name)" }
                        ?? property.name))
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
        if ObjectIdentifier(keyPathRootType) != ObjectIdentifier(expectedRootType) {
            throw SwiftDataError.unsupportedPredicate(
                "Predicate key path root '\(String(reflecting: keyPathRootType))' does not match active model scope "
                    + "'\(String(reflecting: expectedRootType))' for '\(String(describing: keyPath))'.")
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
