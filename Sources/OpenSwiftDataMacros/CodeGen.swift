import SwiftSyntax
import SwiftSyntaxBuilder
import Foundation
import SwiftDiagnostics

enum CodeGen {
    enum SchemaDirectiveKind {
        case unique
        case index

        var name: String {
            switch self {
            case .unique: "Unique"
            case .index: "Index"
            }
        }

        var isUnique: Bool {
            switch self {
            case .unique: true
            case .index: false
            }
        }
    }

    static func schemaDirectiveSources(
        _ node: some FreestandingMacroExpansionSyntax,
        kind: SchemaDirectiveKind,
        uniqueName: String
    ) throws -> [String] {
        let arguments = node.arguments
        guard !arguments.isEmpty else {
            throw SchemaDirectiveDiagnostic("#\(kind.name) requires at least one direct property key path.")
        }
        var properties: [String] = []
        for argument in arguments {
            guard let keyPath = argument.expression.as(KeyPathExprSyntax.self),
                keyPath.components.count == 1,
                let component = keyPath.components.first?.component.as(KeyPathPropertyComponentSyntax.self)
            else {
                throw SchemaDirectiveDiagnostic("#\(kind.name) arguments must be direct property key paths.")
            }
            properties.append(component.declName.baseName.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")))
        }
        guard Set(properties).count == properties.count else {
            throw SchemaDirectiveDiagnostic("#\(kind.name) cannot repeat a property key path.")
        }
        let quoted = properties.map { "\"\(escapeSwiftString($0))\"" }.joined(separator: ", ")
        let unique = kind.name == "Unique"
        return [
            "let \(uniqueName) = Schema.Index(properties: [\(quoted)], isUnique: \(unique))"
        ]
    }

    private static func escapeSwiftString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    struct Property {
        let name: String
        let initializer: String?
        let metadata: String?
        let inverseKeyPath: String?
        let hasExplicitAttribute: Bool
        let hasExplicitRelationship: Bool
        let isRelationship: Bool
        let isTransient: Bool
        let isComputed: Bool
        let isStatic: Bool
        let isLazy: Bool

        init(
            name: String,
            initializer: String? = nil,
            metadata: String? = nil,
            inverseKeyPath: String? = nil,
            hasExplicitAttribute: Bool = false,
            hasExplicitRelationship: Bool = false,
            isRelationship: Bool = false,
            isTransient: Bool = false,
            isComputed: Bool = false,
            isStatic: Bool = false,
            isLazy: Bool = false
        ) {
            self.name = name
            self.initializer = initializer
            self.metadata = metadata
            self.inverseKeyPath = inverseKeyPath
            self.hasExplicitAttribute = hasExplicitAttribute
            self.hasExplicitRelationship = hasExplicitRelationship
            self.isRelationship = isRelationship
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
            var resolvedInverseKeyPath: String?
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
                guard attributeName == "Attribute" || attributeName == "Relationship" else {
                    if attributeName == "Transient" { transient = true }
                    continue
                }
                let argumentList: LabeledExprListSyntax
                if let arguments = attribute.arguments,
                    case let .argumentList(argumentsList) = arguments
                {
                    argumentList = argumentsList
                } else {
                    argumentList = []
                }
                if attributeName == "Relationship" {
                    explicitRelationship = true
                }
                if attributeName == "Attribute" {
                    explicitAttribute = true
                }
                let metadataArguments = argumentList.trimmedDescription.trimmingWhitespace()
                if attributeName == "Relationship", argumentList.isEmpty {
                    resolvedMetadata = nil
                } else {
                    resolvedMetadata = "Schema.\(attributeName)(\(metadataArguments))"
                }
                // The inverse follows whichever attribute supplies the final metadata.
                resolvedInverseKeyPath = nil
                if attributeName == "Relationship",
                    let inverse = argumentList.first(where: { $0.label?.text == "inverse" }),
                    inverse.expression.trimmedDescription != "nil"
                {
                    resolvedInverseKeyPath = inverse.expression.trimmedDescription
                    var typedArguments = Array(argumentList)
                    if let index = typedArguments.firstIndex(where: { $0.label?.text == "inverse" }) {
                        typedArguments.remove(at: index)
                    }
                    let labels = typedArguments.map { argument in
                        let label = argument.label.map { "\($0.text): " } ?? ""
                        return label + argument.expression.trimmedDescription
                    }
                    let inverseName = inversePropertyName(inverse.expression)
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    resolvedMetadata =
                        "Schema.Relationship(\((labels + ["inverseName: \"\(inverseName)\""]).joined(separator: ", ")))"
                }
            }
            metadata = resolvedMetadata
            inverseKeyPath = resolvedInverseKeyPath
            hasExplicitAttribute = explicitAttribute
            hasExplicitRelationship = explicitRelationship
            isRelationship = explicitRelationship
            isTransient = transient
        }
    }

    private static func inversePropertyName(_ expression: ExprSyntax) -> String {
        if let keyPath = expression.as(KeyPathExprSyntax.self), let component = keyPath.components.last,
            let property = component.component.as(KeyPathPropertyComponentSyntax.self)
        {
            return property.declName.baseName.text
        }
        let name = expression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        return name.first == "`" && name.last == "`" ? String(name.dropFirst().dropLast()) : name
    }

    static func memberSources(_ declaration: ClassDeclSyntax, variant: InitializationVariant = .a) -> [String] {
        let modelName = declaration.name.text
        let properties = persistedProperties(in: declaration)
        let adapterRows = properties.compactMap { property -> String? in
            guard let type = propertyType(property.name, in: declaration) else { return nil }
            let isExplicitAttribute = property.hasExplicitAttribute
            let isRelationshipProperty =
                property.hasExplicitRelationship || property.metadata?.hasPrefix("Schema.Relationship") == true
            guard !isRelationshipProperty else { return nil }
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
            let isSet = type.trimmedDescription.hasPrefix("Set<")
            let builderClosure: String
            if isCollection {
                builderClosure = "{ endpoints in \(type.trimmedDescription)(endpoints) }"
            } else if isOptional {
                builderClosure = "{ endpoints in endpoints.first }"
            } else {
                builderClosure =
                    "{ endpoints in guard let endpoint = endpoints.first else { throw SwiftDataError.unsupportedSchemaProperty(\"Cannot clear nonoptional relationship '\(property.name)'.\") }; return endpoint }"
            }
            let inverseBuilderClosure =
                isCollection && isSet
                ? "{ endpoints in Set(endpoints) }"
                : (isCollection ? "{ endpoints in endpoints }" : builderClosure)
            let metadataArgument = relationshipMetadata.map { "metadata: \($0), " } ?? ""
            let inverseArgument =
                property.inverseKeyPath
                .map { ", explicitInverseKeyPath: " + $0 }
                ?? ""
            let adapterTail = (isCollection ? ", isToMany: true" : ", isToMany: false") + inverseArgument
            let adapter =
                "TypedRelationshipPropertyAdapter<\(modelName), \(type.trimmedDescription), \(destination.trimmedDescription)>"
            let row =
                "        \(adapter)(\"\(property.name)\", keyPath: \\\(modelName).\(property.name), \(metadataArgument)read: { model in model.\(property.name) }, endpoints: \(endpointClosure), build: \(builderClosure), inverseBuild: \(inverseBuilderClosure)\(adapterTail))"
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
            "Schema.PropertyMetadata(name: \"\(property.name)\", keypath: \\\((modelName)).\(property.name), defaultValue: \(property.initializer ?? "nil"), metadata: \(property.metadata ?? "nil"), isExplicitRelationship: \(property.hasExplicitRelationship))"
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
            "public static func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox] { relationshipAdapterCandidates() + inferredRelationshipAdapterCandidates() }",
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

    static func accessorSources(
        property: String,
        isRelationship: Bool = false,
        variant: InitializationVariant = .a
    ) -> [String] {
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
        let setter =
            isRelationship
            ? "self.setRelationshipValue(forKey: \\.\(property), to: newValue)"
            : "self.setValue(forKey: \\.\(property), to: newValue)"
        return [
            initializer,
            "get {\n    access(keyPath: \\.\(property))\n    return self.getValue(forKey: \\.\(property))\n}",
            "set {\n    withMutation(keyPath: \\.\(property)) {\n        \(setter)\n    }\n}",
        ]
    }

    static func accessorSources(property: Property, variant: InitializationVariant = .a) -> [String] {
        accessorSources(property: property.name, isRelationship: property.isRelationship, variant: variant)
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

private struct SchemaDirectiveDiagnostic: Error, DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "OpenSwiftDataMacros", id: "schema-directive") }
    var severity: DiagnosticSeverity { .error }

    init(_ message: String) { self.message = message }
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
