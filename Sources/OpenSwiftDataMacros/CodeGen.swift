import SwiftSyntax
import SwiftSyntaxBuilder

enum CodeGen {
    struct Property {
        let name: String
        let initializer: String?
        let metadata: String?
        let hasExplicitAttribute: Bool
        let hasExplicitRelationship: Bool
        let isTransient: Bool
        let isComputed: Bool
        let isStatic: Bool
        let isLazy: Bool

        init(
            name: String,
            initializer: String? = nil,
            metadata: String? = nil,
            hasExplicitAttribute: Bool = false,
            hasExplicitRelationship: Bool = false,
            isTransient: Bool = false,
            isComputed: Bool = false,
            isStatic: Bool = false,
            isLazy: Bool = false
        ) {
            self.name = name
            self.initializer = initializer
            self.metadata = metadata
            self.hasExplicitAttribute = hasExplicitAttribute
            self.hasExplicitRelationship = hasExplicitRelationship
            self.isTransient = isTransient
            self.isComputed = isComputed
            self.isStatic = isStatic
            self.isLazy = isLazy
        }

        init(_ binding: PatternBindingSyntax, attributes: AttributeListSyntax, modifiers: DeclModifierListSyntax) {
            name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
            initializer = binding.initializer?.value.trimmedDescription
            isComputed = binding.accessorBlock != nil
            isStatic = modifiers.contains { ["static", "class"].contains($0.name.text) }
            isLazy = modifiers.contains { $0.name.text == "lazy" }

            var resolvedMetadata: String?
            var explicitAttribute = false
            var explicitRelationship = false
            var transient = false
            for element in attributes {
                guard case let .attribute(attribute) = element else { continue }
                let attributeName = attribute.attributeName.trimmedDescription
                if attributeName == "Attribute" {
                    explicitAttribute = true
                } else if attributeName == "Relationship" {
                    explicitRelationship = true
                }
                guard let arguments = attribute.arguments,
                    case let .argumentList(argumentList) = arguments
                else {
                    if attributeName == "Transient" { transient = true }
                    continue
                }

                guard attributeName == "Attribute" || attributeName == "Relationship" else { continue }
                let metadataArguments = argumentList.trimmedDescription.trimmingWhitespace()
                resolvedMetadata = "Schema.\(attributeName)(\(metadataArguments))"
            }
            metadata = resolvedMetadata
            hasExplicitAttribute = explicitAttribute
            hasExplicitRelationship = explicitRelationship
            isTransient = transient
        }
    }

    static func memberSources(_ declaration: ClassDeclSyntax, variant: InitializationVariant = .a) -> [String] {
        let modelName = declaration.name.text
        let properties = persistedProperties(in: declaration)
        let adapterRows = properties.compactMap { property -> String? in
            guard !property.hasExplicitRelationship,
                property.metadata?.hasPrefix("Schema.Relationship") != true,
                let type = propertyType(property.name, in: declaration)
            else { return nil }
            let isExplicitAttribute = property.hasExplicitAttribute
            let isOptionalScalar =
                type.as(OptionalTypeSyntax.self).map { isSupportedScalarType($0.wrappedType) } ?? false
            guard isExplicitAttribute || isSupportedScalarType(type) || isOptionalScalar else { return nil }
            let typeName = type.trimmedDescription
            return
                "        TypedPropertyAdapter<\(modelName), \(typeName)>(\"\(property.name)\", keyPath: \\\(modelName).\(property.name), encode: { model in try PersistentValue.encode(model.\(property.name)) }, decode: { value, model in model.\(property.name) = try PersistentValue.decode(\(typeName).self, from: value) }, decodeValue: { value in (try PersistentValue.decode(\(typeName).self, from: value)) as Any })"
        }
        let adapterSource: String? =
            adapterRows.isEmpty
            ? nil
            : "public static func persistenceAdapters() -> [any PersistencePropertyAdapter<\(modelName)>] {\n    [\n\(adapterRows.joined(separator: ",\n"))\n    ]\n}"
        let relationshipRows = properties.compactMap { property -> String? in
            guard let type = propertyType(property.name, in: declaration) else { return nil }
            let relationshipMetadata =
                property.metadata?.hasPrefix("Schema.Relationship") == true
                ? property.metadata : nil
            let explicitRelationship = property.hasExplicitRelationship
            let explicitAttribute = property.hasExplicitAttribute
            guard !property.isTransient, !property.isComputed, !property.isStatic, !property.isLazy else { return nil }
            let optional = type.as(OptionalTypeSyntax.self)
            let relationshipType = optional?.wrappedType ?? type
            let isOptional = optional != nil
            let destination: TypeSyntax
            let isCollection: Bool
            if let array = relationshipType.as(ArrayTypeSyntax.self) {
                destination = array.element
                isCollection = true
            } else if let set = relationshipType.as(IdentifierTypeSyntax.self), set.name.text == "Set",
                let argument = set.genericArgumentClause?.arguments.first?.argument,
                case let .type(element) = argument
            {
                destination = element
                isCollection = true
            } else if let identifier = relationshipType.as(IdentifierTypeSyntax.self),
                identifier.genericArgumentClause == nil
            {
                destination = relationshipType
                isCollection = false
            } else if let member = relationshipType.as(MemberTypeSyntax.self) {
                destination = TypeSyntax(member)
                isCollection = false
            } else {
                return nil
            }
            let isSimpleModelType: Bool
            if let destinationIdentifier = destination.as(IdentifierTypeSyntax.self) {
                isSimpleModelType = destinationIdentifier.genericArgumentClause == nil
            } else {
                isSimpleModelType = destination.is(MemberTypeSyntax.self)
            }
            guard isSimpleModelType, !isSupportedScalarType(destination), explicitRelationship || !explicitAttribute
            else { return nil }
            let endpointClosure =
                isCollection
                ? (isOptional ? "{ value in value.map { Array($0) } ?? [] }" : "{ value in value }")
                : (isOptional ? "{ value in value.map { [$0] } ?? [] }" : "{ value in [value] }")
            let metadataArgument = relationshipMetadata.map { "metadata: \($0), " } ?? ""
            let inverseArgument = ""
            let adapterTail = (isCollection ? ", isToMany: true" : ", isToMany: false") + inverseArgument
            let adapter =
                "TypedRelationshipPropertyAdapter<\(modelName), \(type.trimmedDescription), \(destination.trimmedDescription)>"
            let row =
                "        \(adapter)(\"\(property.name)\", keyPath: \\\(modelName).\(property.name), \(metadataArgument)read: { model in model.\(property.name) }, endpoints: \(endpointClosure)\(adapterTail))"
            if explicitRelationship { return "explicit|\(row)" }
            return explicitAttribute ? nil : "inferred|\(row)"
        }
        let explicitRelationshipRows = relationshipRows.compactMap {
            $0.hasPrefix("explicit|") ? String($0.dropFirst(9)) : nil
        }
        let inferredRelationshipRows = relationshipRows.compactMap {
            $0.hasPrefix("inferred|") ? String($0.dropFirst(9)) : nil
        }
        let explicitBoxRows = explicitRelationshipRows.map {
            "        RelationshipAdapterBox<\(modelName)>(\($0.trimmingWhitespace()))"
        }
        let inferredBoxRows = inferredRelationshipRows.map {
            "        RelationshipAdapterBox<\(modelName)>(\($0.trimmingWhitespace()))"
        }
        let relationshipAdapterSource: String? =
            explicitBoxRows.isEmpty
            ? nil
            : "public static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    [\n\(explicitBoxRows.joined(separator: ",\n"))\n    ]\n}"
        let inferredRelationshipAdapterSource: String? =
            inferredBoxRows.isEmpty
            ? nil
            : "public static func inferredRelationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    [\n\(inferredBoxRows.joined(separator: ",\n"))\n    ]\n}"
        let metadataRows = properties.map { property in
            "Schema.PropertyMetadata(name: \"\(property.name)\", keypath: \\\((modelName)).\(property.name), defaultValue: \(property.initializer ?? "nil"), metadata: \(property.metadata ?? "nil"))"
        }
        let metadataBody =
            metadataRows.isEmpty
            ? "    return []" : "    return [\n        \(metadataRows.joined(separator: ",\n        "))\n    ]"
        let initializerAssignments: [String] =
            variant == .b
            ? properties.map { "    _\($0.name) = _SwiftDataNoType()" }
            : []
        let backingInitializer =
            ([
                "public init(backingData: any BackingData<\(modelName)>) {",
                "    _$backingData = backingData",
            ] + initializerAssignments + ["}"]).joined(separator: "\n")

        return [
            "@Transient\nprivate var _$backingData: any BackingData<\(modelName)> = \(modelName).createBackingData()",
            "public var persistentBackingData: any BackingData<\(modelName)> {\n    get { _$backingData }\n    set { _$backingData = newValue }\n}",
            "public static func schemaMetadata() -> [Schema.PropertyMetadata] {\n\(metadataBody)\n}",
            adapterSource,
            relationshipAdapterSource,
            inferredRelationshipAdapterSource,
            backingInitializer,
            "@Transient\nprivate let _$observationRegistrar = Observation.ObservationRegistrar()",
            "internal nonisolated func access<_M>(keyPath: KeyPath<\(modelName), _M>) {\n    _$observationRegistrar.access(self, keyPath: keyPath)\n}",
            "internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<\(modelName), _M>, _ mutation: () throws -> _MR) rethrows -> _MR {\n    try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)\n}",
            "struct _SwiftDataNoType {}",
        ].compactMap { $0 }
    }

    private static func isSupportedScalarType(_ type: TypeSyntax) -> Bool {
        if let optional = type.as(OptionalTypeSyntax.self) { return isSupportedScalarType(optional.wrappedType) }
        if let array = type.as(ArrayTypeSyntax.self) { return isSupportedScalarType(array.element) }
        guard let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil else {
            return false
        }
        return [
            "String", "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "UUID", "Date", "URL", "Decimal", "Data",
        ].contains(identifier.name.text)
    }

    private static func propertyType(_ name: String, in declaration: ClassDeclSyntax) -> TypeSyntax? {
        declaration.memberBlock.members.compactMap { member -> TypeSyntax? in
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { return nil }
            return variable.bindings.first(where: {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name
            })?.typeAnnotation?.type
        }.first
    }

    static func accessorSources(property: String, variant: InitializationVariant = .a) -> [String] {
        let storageRestriction =
            variant == .c
            ? "@storageRestrictions(accesses: _$backingData)"
            : "@storageRestrictions(accesses: _$backingData, initializes: _\(property))"
        let initializationAssignment = variant == .c ? [] : ["    _\(property) = _SwiftDataNoType()"]
        let initializer =
            ([
                "\(storageRestriction)",
                "init(initialValue) {",
                "    _$backingData.setValue(forKey: \\.\(property), to: initialValue)",
            ] + initializationAssignment + ["}"]).joined(separator: "\n")
        return [
            initializer,
            "get {\n    access(keyPath: \\.\(property))\n    return self.getValue(forKey: \\.\(property))\n}",
            "set {\n    withMutation(keyPath: \\.\(property)) {\n        self.setValue(forKey: \\.\(property), to: newValue)\n    }\n}",
        ]
    }

    static func accessorSources(property: Property, variant: InitializationVariant = .a) -> [String] {
        accessorSources(property: property.name, variant: variant)
    }

    static func peerSources(property: String, variant: InitializationVariant = .a) -> [String] {
        let initializer = variant == .c ? " = _SwiftDataNoType()" : ""
        return ["@Transient\nprivate var _\(property): _SwiftDataNoType\(initializer)"]
    }

    static func peerSources(property: Property, variant: InitializationVariant = .a) -> [String] {
        peerSources(property: property.name, variant: variant)
    }

    static func extensionSources(_ declaration: some DeclGroupSyntax) -> [String] {
        let modelName: String
        if let classDeclaration = declaration.as(ClassDeclSyntax.self) {
            modelName = classDeclaration.name.text
        } else if let structDeclaration = declaration.as(StructDeclSyntax.self) {
            modelName = structDeclaration.name.text
        } else {
            modelName = declaration.trimmedDescription
        }
        return [
            "extension \(modelName): PersistentModel {}",
            "extension \(modelName): RelationshipModel {}",
            "extension \(modelName): Observation.Observable {}",
            "extension \(modelName): @unchecked Sendable {}",
        ]
    }

    static func extensionSources(modelName: String) -> [String] {
        [
            "extension \(modelName): PersistentModel {}",
            "extension \(modelName): RelationshipModel {}",
            "extension \(modelName): Observation.Observable {}",
            "extension \(modelName): @unchecked Sendable {}",
        ]
    }

    static func persistedProperties(in declaration: ClassDeclSyntax) -> [Property] {
        declaration.memberBlock.members.flatMap { member -> [Property] in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                variable.bindings.count == 1
            else { return [] }
            return variable.bindings.compactMap { binding in
                guard binding.pattern.is(IdentifierPatternSyntax.self) else { return nil }
                let property = Property(binding, attributes: variable.attributes, modifiers: variable.modifiers)
                return property.isComputed || property.isStatic || property.isLazy || property.isTransient
                    ? nil : property
            }
        }
    }
}

enum InitializationVariant {
    case a
    case b
    case c
}

private extension String {
    func firstRange(of text: String) -> Range<String.Index>? {
        guard let lower = firstIndex(of: text.first ?? " ") else { return nil }
        guard let match = self[lower...].firstIndex(of: text.first ?? " "),
            self[match...].hasPrefix(text)
        else { return nil }
        return match..<index(match, offsetBy: text.count)
    }

    func trimmingWhitespace() -> String {
        var start = startIndex
        var end = endIndex
        while start < end, self[start].isWhitespace {
            formIndex(after: &start)
        }
        while start < end {
            let previous = index(before: end)
            guard self[previous].isWhitespace else { break }
            end = previous
        }
        return String(self[start..<end])
    }
}
