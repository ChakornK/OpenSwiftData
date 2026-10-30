import SwiftSyntax
import SwiftSyntaxBuilder
import Foundation
import SwiftDiagnostics

enum CodeGen {
    static func modelActorMemberSources(actorName: String) -> [String] {
        return [
            "nonisolated let modelExecutor: DefaultSerialModelExecutor",
            "nonisolated let modelContainer: ModelContainer",
            "init(modelContainer: ModelContainer) {\n    self.modelContainer = modelContainer\n    self.modelExecutor = DefaultSerialModelExecutor.make(container: modelContainer)\n}",
        ]
    }

    static func modelActorExtensionSource(actorName: String) -> String {
        "extension \(actorName): ModelActor {}"
    }

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

    static func schemaDirectiveProperties(
        _ node: some FreestandingMacroExpansionSyntax,
        kind: SchemaDirectiveKind
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
        return properties
    }

    static func validateSchemaDirectiveTargets(
        _ properties: [String], kind: SchemaDirectiveKind, in declaration: ClassDeclSyntax
    ) throws {
        let stored = Set(persistedProperties(in: declaration).map(\.name))
        for property in properties where !stored.contains(property) {
            throw SchemaDirectiveDiagnostic(
                "#\(kind.name) property '\(property)' must name a stored property of @Model '\(declaration.name.text)'."
            )
        }
    }

    static func schemaIndexSourcesValidating(in declaration: ClassDeclSyntax) throws -> String? {
        var indexes: [[String]] = []
        var uniqueIndexes: [[String]] = []
        var seenIndexes: Set<String> = []
        var seenUnique: Set<String> = []
        for member in declaration.memberBlock.members {
            guard let directive = member.decl.as(MacroExpansionDeclSyntax.self) else { continue }
            let kind: SchemaDirectiveKind
            switch directive.macroName.trimmedDescription {
            case "Index": kind = .index
            case "Unique": kind = .unique
            default: continue
            }
            let properties = try schemaDirectiveProperties(directive, kind: kind)
            try validateSchemaDirectiveTargets(properties, kind: kind, in: declaration)
            let key = properties.joined(separator: "\u{0}")
            if kind.isUnique {
                if seenUnique.insert(key).inserted { uniqueIndexes.append(properties) }
            } else if seenIndexes.insert(key).inserted {
                indexes.append(properties)
            }
        }
        let rows = (uniqueIndexes.map { ($0, true) } + indexes.map { ($0, false) }).map { properties, unique in
            "Schema.Index(properties: [\(properties.map { "\"\(escapeSwiftString($0))\"" }.joined(separator: ", "))], isUnique: \(unique))"
        }
        guard !rows.isEmpty else { return nil }
        return "public static func schemaIndexes() -> [Schema.Index] { [\(rows.joined(separator: ", "))] }"
    }

    private static func escapeSwiftString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    struct Property {
        let name: String
        let escapedName: String
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
        let isFlattened: Bool
        let attributeOptionNames: [String]

        init(
            name: String,
            escapedName: String? = nil,
            initializer: String? = nil,
            metadata: String? = nil,
            inverseKeyPath: String? = nil,
            hasExplicitAttribute: Bool = false,
            hasExplicitRelationship: Bool = false,
            isRelationship: Bool = false,
            isTransient: Bool = false,
            isComputed: Bool = false,
            isStatic: Bool = false,
            isLazy: Bool = false,
            isFlattened: Bool = false,
            attributeOptionNames: [String] = []
        ) {
            self.name = name
            self.escapedName = escapedName ?? name
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
            self.isFlattened = isFlattened
            self.attributeOptionNames = attributeOptionNames
        }

        init(_ binding: PatternBindingSyntax, attributes: AttributeListSyntax, modifiers: DeclModifierListSyntax) {
            let rawName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
            escapedName = rawName
            name = rawName.first == "`" && rawName.last == "`" ? String(rawName.dropFirst().dropLast()) : rawName
            initializer = binding.initializer?.value.trimmedDescription
            isComputed = binding.accessorBlock != nil
            isStatic = modifiers.contains { ["static", "class"].contains($0.name.text) }
            isLazy = modifiers.contains { $0.name.text == "lazy" }

            var resolvedMetadata: String?
            var resolvedInverseKeyPath: String?
            var explicitAttribute = false
            var explicitRelationship = false
            var transient = false
            var flattened = false
            var attributeOptionNames: [String] = []
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
                    attributeOptionNames = []
                }
                if attributeName == "Attribute" {
                    explicitAttribute = true
                }
                let metadataArguments = argumentList.trimmedDescription.trimmingWhitespace()
                if attributeName == "Attribute", metadataArguments.contains(".flattened") {
                    flattened = true
                }
                if attributeName == "Attribute" {
                    attributeOptionNames = argumentList.compactMap { argument in
                        guard argument.label == nil,
                            let member = argument.expression.as(MemberAccessExprSyntax.self)
                        else { return nil }
                        return member.declName.baseName.text
                    }
                }
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
            isFlattened = flattened
            self.attributeOptionNames = attributeOptionNames
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

    static func memberSources(
        _ declaration: ClassDeclSyntax, variant: InitializationVariant = .a,
        schemaIndexes: String? = nil,
        superclassName: String? = nil
    ) -> [String] {
        let modelName = declaration.name.text
        let isFinal = declaration.modifiers.contains(where: { $0.name.text == "final" })
        let isSubclass = superclassName != nil
        let isOpen = declaration.modifiers.contains(where: { $0.name.text == "open" })
        let isPublic = isOpen || declaration.modifiers.contains(where: { $0.name.text == "public" })
        let declarationKind = isSubclass ? "override class" : (isFinal ? "static" : "class")
        let typeMemberAccess = isOpen ? "open" : "public"
        let typeOverrideAccess = isOpen ? "open override" : "public override"
        let typeDeclarationAccess = isFinal ? "public static" : "\(typeMemberAccess) class"
        let slotDeclarationAccess = isFinal ? "public static" : "\(typeMemberAccess) class"
        let methodDeclarationAccess = isFinal ? "public static" : "\(typeMemberAccess) class"
        let instanceMemberAccess = isOpen ? "open" : "public"
        let instanceOverrideAccess = isOpen ? "open override" : "public override"
        let associatedModelSource = isFinal || isSubclass ? nil : "public typealias Model = \(modelName)"
        let properties = persistedProperties(in: declaration)
        let descriptorRows = properties.enumerated().map { slot, property in
            let typeName = propertyType(property.name, in: declaration)?.trimmedDescription ?? "Any"
            let propertyType = propertyType(property.name, in: declaration)
            let inferredRelationship =
                propertyType.map {
                    !property.hasExplicitAttribute && !property.isFlattened && !isSupportedScalarType($0)
                } ?? false
            let kind = property.isRelationship || inferredRelationship ? ".relationship" : ".attribute"
            let options = property.attributeOptionNames.map { "\"\(escapeSwiftString($0))\"" }.joined(separator: ", ")
            let descriptorSlot = isSubclass ? "super.propertyDescriptors.count + \(slot)" : String(slot)
            return
                "PropertyDescriptor(slot: \(descriptorSlot), name: \"\(escapeSwiftString(property.name))\", keyPath: \\\((modelName)).\(property.escapedName), kind: \(kind), codec: \(typeName).self, options: [\(options)])"
        }
        let descriptorBody = "[\(descriptorRows.joined(separator: ", "))]"
        let descriptorSource: String? = {
            guard isSubclass else {
                if isFinal {
                    return descriptorRows.isEmpty
                        ? nil
                        : "public static let propertyDescriptors: [PropertyDescriptor] = \(descriptorBody)"
                }
                return "\(typeDeclarationAccess) var propertyDescriptors: [PropertyDescriptor] { \(descriptorBody) }"
            }
            return
                "\(typeOverrideAccess) class var propertyDescriptors: [PropertyDescriptor] { super.propertyDescriptors + \(descriptorBody) }"
        }()
        let slotLookupSource: String? = {
            guard isSubclass || !isFinal || !descriptorRows.isEmpty else { return nil }
            let lookup =
                isFinal
                ? "propertyDescriptors.first(where: { $0.keyPath == keyPath })?.slot"
                : "(propertyDescriptorsByKeyPath())[keyPath]?.slot ?? propertyDescriptors.first(where: { $0.keyPath == keyPath })?.slot"
            return
                "\(isSubclass ? typeOverrideAccess + " class" : slotDeclarationAccess) func propertySlot(forKeyPath keyPath: AnyKeyPath) -> Int? { \(lookup) }"
        }()
        let adapterRows = properties.compactMap { property -> String? in
            guard let type = propertyType(property.name, in: declaration) else { return nil }
            if property.isFlattened { return nil }
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
            isSubclass || (adapterRows.isEmpty && isFinal)
            ? nil
            : "\(typeDeclarationAccess) func persistenceAdapters() -> [any PersistencePropertyAdapter<\(modelName)>] {\n    [\n\(adapterRows.joined(separator: ",\n"))\n    ]\n}"
        let erasedAdapterRows = adapterRows.map { "ErasedPersistencePropertyAdapter(\($0.trimmingWhitespace()))" }
        let erasedAdapterSource: String = {
            if isSubclass {
                return
                    "\(typeOverrideAccess) class func erasedPersistenceAdapters() -> [any AnyPersistencePropertyAdapter] { super.erasedPersistenceAdapters() + [\(erasedAdapterRows.joined(separator: ", "))] }"
            }
            return
                "\(typeDeclarationAccess) func erasedPersistenceAdapters() -> [any AnyPersistencePropertyAdapter] { persistenceAdapters().map(ErasedPersistencePropertyAdapter.init) }"
        }()
        let flattenedAdapterRows = properties.compactMap { property -> String? in
            guard property.isFlattened, let type = propertyType(property.name, in: declaration) else { return nil }
            guard type.as(OptionalTypeSyntax.self) == nil else { return nil }
            let typeName = type.trimmedDescription
            let memberName = property.escapedName
            let propertyLiteral = escapeSwiftString(property.name)
            return
                "        \(typeName).flattenedComponents.map { $0.modelAdapter(propertyName: \"\(propertyLiteral)\", propertyKeyPath: \\\(modelName).\(memberName), setComposite: { value, model in model.\(memberName) = value }) }"
        }
        let flattenedAdapterSource: String? = {
            let own =
                flattenedAdapterRows.isEmpty
                ? "[]"
                : "[\n\(flattenedAdapterRows.joined(separator: ",\n"))\n    ].flatMap { $0 }"
            if isSubclass {
                return
                    "\(typeOverrideAccess) class func flattenedPropertyAdapters() -> [any AnyFlattenedPropertyAdapter] { super.flattenedPropertyAdapters() + \(own) }"
            }
            guard !flattenedAdapterRows.isEmpty || !isFinal else { return nil }
            return
                "\(typeDeclarationAccess) func flattenedPropertyAdapters() -> [any AnyFlattenedPropertyAdapter] {\n    \(own)\n}"
        }()
        let relationshipRows = properties.compactMap { property -> String? in
            guard let type = propertyType(property.name, in: declaration) else { return nil }
            guard !property.hasExplicitAttribute else { return nil }
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
            guard isSimpleModelType, !isSupportedScalarType(destination),
                explicitRelationship || (isCollection && !explicitAttribute)
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
        let relationshipAdapterSource: String? = {
            let own = "[\n\(explicitBoxRows.joined(separator: ",\n"))\n    ]"
            if isSubclass {
                return
                    "\(typeOverrideAccess) class func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] { super.relationshipAdapterCandidates() + \(own) }"
            }
            guard !explicitBoxRows.isEmpty || !isFinal else { return nil }
            return
                "\(typeDeclarationAccess) func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    \(own)\n}"
        }()
        let inferredRelationshipAdapterSource: String? = {
            let own = "[\n\(inferredBoxRows.joined(separator: ",\n"))\n    ]"
            if isSubclass {
                return
                    "\(typeOverrideAccess) class func inferredRelationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] { super.inferredRelationshipAdapterCandidates() + \(own) }"
            }
            guard !inferredBoxRows.isEmpty || !isFinal else { return nil }
            return
                "\(typeDeclarationAccess) func inferredRelationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    \(own)\n}"
        }()
        let metadataRows = properties.map { property in
            let components =
                property.isFlattened && propertyType(property.name, in: declaration)?.as(OptionalTypeSyntax.self) == nil
                ? ", flattenedComponents: \(propertyType(property.name, in: declaration)?.trimmedDescription ?? "")"
                    + ".flattenedComponentsForSchema.map { component in Schema.Attribute.Component(name: component.0, columnName: \"\(escapeSwiftString(property.name))_\\(component.0)\", type: component.1) }"
                : ""
            let metadata = property.metadata ?? "nil"
            let isOptional = propertyType(property.name, in: declaration)?.as(OptionalTypeSyntax.self) != nil
            let codableMetadata =
                !property.isFlattened && !property.hasExplicitRelationship
                    && propertyType(property.name, in: declaration).map { type in
                        !isSupportedScalarType(type)
                            && !(isOptional
                                && type.as(OptionalTypeSyntax.self).map {
                                    isSupportedScalarType($0.wrappedType)
                                } == true)
                    } == true
                ? "Schema.Attribute(.codable)" : metadata
            let options =
                property.attributeOptionNames.isEmpty
                ? "" : ", options: [" + property.attributeOptionNames.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            return
                "Schema.PropertyMetadata(name: \"\(property.name)\", keypath: \\\((modelName)).\(property.escapedName), defaultValue: \(property.initializer ?? "nil"), metadata: \(codableMetadata), isExplicitRelationship: \(property.hasExplicitRelationship)\(options)\(components))"
        }
        let ownMetadata = "[\n        \(metadataRows.joined(separator: ",\n        "))\n    ]"
        let metadataBody =
            isSubclass
            ? "    return super.schemaMetadata() + \(ownMetadata)"
            : (metadataRows.isEmpty ? "    return []" : "    return \(ownMetadata)")
        let schemaIndexes = schemaIndexesSource(
            schemaIndexes, declarationKind: declarationKind, superclassName: superclassName,
            memberAccess: typeMemberAccess, overrideAccess: typeOverrideAccess)
        let initializerAssignments: [String] =
            variant == .b
            ? properties.map { "    _\($0.name) = _SwiftDataNoType()" }
            : []
        let backingInitializer =
            ([
                "public \(isFinal ? "" : "required ")init(backingData: any BackingData<\(modelName)>) {",
                "    _$backingData = backingData",
            ] + initializerAssignments + ["}"]).joined(separator: "\n")
        let parentModelSource =
            isFinal
            ? nil
            : "\(typeMemberAccess) class var parentModel: (any PersistentModel.Type)? { nil }"
        let backingAccess = isFinal ? "private" : "internal"
        let registrarAccess = isFinal ? "private" : "internal"
        let keyPathTableName = "__\(modelName.replacingOccurrences(of: "`", with: ""))PropertyDescriptors"
        let superclassIdentifier = superclassName.map(simpleTypeIdentifier)
        let resolverAccess = isOpen ? "open" : (isPublic ? "public" : "")
        let resolverOverrideAccess = isOpen ? "open override" : (isPublic ? "public override" : "override")
        let tableAccess = isPublic ? "public " : ""
        let keyPathTableBuilder: String? = {
            guard isSubclass || !isFinal else { return nil }
            let inherited =
                superclassIdentifier.map {
                    "var descriptors = \($0).__\($0.replacingOccurrences(of: "`", with: ""))PropertyDescriptors(Root.self)\n"
                } ?? "var descriptors: [AnyKeyPath: PropertyDescriptor] = [:]\n"
            let additions = properties.enumerated().map { slot, property in
                let typeName = propertyType(property.name, in: declaration)?.trimmedDescription ?? "Any"
                let propertyType = propertyType(property.name, in: declaration)
                let inferredRelationship =
                    propertyType.map {
                        !property.hasExplicitAttribute && !property.isFlattened && !isSupportedScalarType($0)
                    } ?? false
                let kind = property.isRelationship || inferredRelationship ? ".relationship" : ".attribute"
                let options = property.attributeOptionNames.map {
                    "\"\(escapeSwiftString($0))\""
                }.joined(separator: ", ")
                let slotExpression =
                    superclassIdentifier.map { "\($0).propertyDescriptors.count + \(slot)" }
                    ?? String(slot)
                return
                    "        descriptors[\\Root.\(property.escapedName) as AnyKeyPath] = PropertyDescriptor(slot: \(slotExpression), name: \"\(escapeSwiftString(property.name))\", keyPath: \\Root.\(property.escapedName), kind: \(kind), codec: \(typeName).self, options: [\(options)])"
            }.joined(separator: "\n")
            return
                "\(tableAccess)static func \(keyPathTableName)<Root: \(modelName)>(_: Root.Type) -> [AnyKeyPath: PropertyDescriptor] {\n    \(inherited)\(additions)\n        return descriptors\n    }"
        }()
        let keyPathNameResolver =
            isSubclass
            ? "\(resolverOverrideAccess) class func propertyDescriptorsByKeyPath() -> [AnyKeyPath: PropertyDescriptor] { \(keyPathTableName)(Self.self) }"
            : (isFinal
                ? nil
                : "\(resolverAccess) class func propertyDescriptorsByKeyPath() -> [AnyKeyPath: PropertyDescriptor] { \(keyPathTableName)(Self.self) }")

        if isSubclass {
            return subclassMemberSources(
                modelName: modelName,
                superclassName: superclassIdentifier ?? "",
                metadataBody: metadataBody,
                descriptorRows: descriptorRows,
                properties: properties,
                schemaIndexes: schemaIndexes,
                erasedAdapterRows: adapterRows,
                flattenedAdapterRows: flattenedAdapterRows,
                explicitBoxRows: explicitBoxRows,
                inferredBoxRows: inferredBoxRows,
                keyPathTableBuilder: keyPathTableBuilder ?? "",
                keyPathNameResolver: keyPathNameResolver ?? "",
                typeMemberAccess: typeMemberAccess,
                typeOverrideAccess: typeOverrideAccess,
                instanceOverrideAccess: instanceOverrideAccess)
        }

        return [
            "@Transient\n\(backingAccess) var _$backingData: any BackingData<\(modelName)> = \(modelName).createBackingData()",
            "public var persistentBackingData: any BackingData<\(modelName)> {\n    get { _$backingData }\n    set { _$backingData = newValue }\n}",
            associatedModelSource,
            "\(methodDeclarationAccess) func schemaMetadata() -> [Schema.PropertyMetadata] {\n\(metadataBody)\n}",
            keyPathTableBuilder,
            keyPathNameResolver,
            descriptorSource,
            slotLookupSource,
            schemaIndexes,
            adapterSource,
            erasedAdapterSource,
            flattenedAdapterSource,
            relationshipAdapterSource,
            inferredRelationshipAdapterSource,
            "\(methodDeclarationAccess) func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox] { relationshipAdapterCandidates() + inferredRelationshipAdapterCandidates() }",
            parentModelSource,
            isFinal
                ? nil
                : "\(instanceMemberAccess) func prepareForPersistence() {}",
            backingInitializer,
            "@Transient\n\(registrarAccess) let _$observationRegistrar = Observation.ObservationRegistrar()",
            "\(isPublic ? "public " : "internal ")nonisolated func access<Root: \(modelName), _M>(keyPath: KeyPath<Root, _M>) where Root: Observable {\n    guard let subject = self as? Root else { return }\n    _$observationRegistrar.access(subject, keyPath: keyPath)\n}",
            "\(isPublic ? "public " : "internal ")nonisolated func withMutation<Root: \(modelName), _M, _MR>(keyPath: KeyPath<Root, _M>, _ mutation: () throws -> _MR) rethrows -> _MR where Root: Observable {\n    guard let subject = self as? Root else { return try mutation() }\n    return try _$observationRegistrar.withMutation(of: subject, keyPath: keyPath, mutation)\n}",
            "struct _SwiftDataNoType {}",
        ].compactMap { $0 }
    }

    private static func subclassMemberSources(
        modelName: String,
        superclassName: String,
        metadataBody: String,
        descriptorRows: [String],
        properties: [Property],
        schemaIndexes: String?,
        erasedAdapterRows: [String],
        flattenedAdapterRows: [String],
        explicitBoxRows: [String],
        inferredBoxRows: [String],
        keyPathTableBuilder: String,
        keyPathNameResolver: String,
        typeMemberAccess: String,
        typeOverrideAccess: String,
        instanceOverrideAccess: String
    ) -> [String] {
        let ownDescriptors = "[\(descriptorRows.joined(separator: ", "))]"
        let descriptors =
            "\(typeOverrideAccess) class var propertyDescriptors: [PropertyDescriptor] { super.propertyDescriptors + \(ownDescriptors) }"
        let ownErasedAdapters = erasedAdapterRows.map {
            "ErasedPersistencePropertyAdapter(\($0.trimmingWhitespace()))"
        }
        let erasedAdapters =
            "\(typeOverrideAccess) class func erasedPersistenceAdapters() -> [any AnyPersistencePropertyAdapter] { super.erasedPersistenceAdapters() + [\(ownErasedAdapters.joined(separator: ", "))] }"
        let ownFlattenedAdapters =
            flattenedAdapterRows.isEmpty
            ? "[]"
            : "[\n\(flattenedAdapterRows.joined(separator: ",\n"))\n    ].flatMap { $0 }"
        let flattenedAdapters =
            "\(typeOverrideAccess) class func flattenedPropertyAdapters() -> [any AnyFlattenedPropertyAdapter] { super.flattenedPropertyAdapters() + \(ownFlattenedAdapters) }"
        let ownRelationships = "[\n\(explicitBoxRows.joined(separator: ",\n"))\n    ]"
        let relationships =
            "\(typeOverrideAccess) class func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] { super.relationshipAdapterCandidates() + \(ownRelationships) }"
        let ownInferredRelationships = "[\n\(inferredBoxRows.joined(separator: ",\n"))\n    ]"
        let inferredRelationships =
            "\(typeOverrideAccess) class func inferredRelationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] { super.inferredRelationshipAdapterCandidates() + \(ownInferredRelationships) }"
        let inheritedIndexes =
            schemaIndexes
            ?? "\(typeOverrideAccess) class func schemaIndexes() -> [Schema.Index] { super.schemaIndexes() }"
        let initializer =
            "public required init(backingData: any BackingData<\(superclassName).Model>) {\n"
            + "    super.init(backingData: backingData)\n}"
        let prepareValues = properties.map { property in
            let name = property.escapedName
            return
                "        if let pending = _\(property.name) { setInheritedValue(keyPath: \\\(modelName).\(name), to: pending); _\(property.name) = nil }"
        }
        let prepare =
            (["\(instanceOverrideAccess) func prepareForPersistence() {", "    super.prepareForPersistence()"]
            + prepareValues
            + ["}"]).joined(separator: "\n")
        return [
            initializer,
            "\(typeOverrideAccess) class func schemaMetadata() -> [Schema.PropertyMetadata] {\n\(metadataBody)\n}",
            descriptors,
            "\(typeOverrideAccess) class func propertySlot(forKeyPath keyPath: AnyKeyPath) -> Int? { propertyDescriptorsByKeyPath()[keyPath]?.slot ?? propertyDescriptors.first(where: { $0.keyPath == keyPath })?.slot }",
            inheritedIndexes,
            keyPathTableBuilder,
            keyPathNameResolver,
            erasedAdapters,
            flattenedAdapters,
            relationships,
            inferredRelationships,
            "\(typeOverrideAccess) class func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox] { relationshipAdapterCandidates() + inferredRelationshipAdapterCandidates() }",
            "\(typeOverrideAccess) class var parentModel: (any PersistentModel.Type)? { \(superclassName).self }",
            prepare,
        ]
    }

    private static func schemaIndexesSource(
        _ source: String?, declarationKind: String, superclassName: String?, memberAccess: String,
        overrideAccess: String
    ) -> String? {
        guard let source else {
            if superclassName != nil {
                return "\(overrideAccess) class func schemaIndexes() -> [Schema.Index] { super.schemaIndexes() }"
            }
            return declarationKind == "class"
                ? "\(memberAccess) class func schemaIndexes() -> [Schema.Index] { [] }"
                : nil
        }
        guard superclassName != nil else {
            return declarationKind == "class"
                ? source.replacingOccurrences(of: "public static func", with: "\(memberAccess) class func")
                : source
        }
        let prefix = "public static func schemaIndexes() -> [Schema.Index] { "
        guard source.hasPrefix(prefix), source.hasSuffix(" }") else { return source }
        let own = String(source.dropFirst(prefix.count).dropLast(2))
        return "\(overrideAccess) class func schemaIndexes() -> [Schema.Index] { super.schemaIndexes() + \(own) }"
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
                guard let raw = $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return false }
                let normalized = raw.first == "`" && raw.last == "`" ? String(raw.dropFirst().dropLast()) : raw
                return normalized == name
            })?.typeAnnotation?.type
        }.first
    }

    private static func simpleTypeIdentifier(_ typeName: String) -> String {
        let lastComponent = typeName.split(separator: ".").last.map(String.init) ?? typeName
        return lastComponent.split(separator: "<", maxSplits: 1).first.map(String.init) ?? lastComponent
    }

    static func accessorSources(
        property: String,
        modelName: String = "",
        slot: Int? = nil,
        isRelationship: Bool = false,
        inherited: Bool = false,
        valueType: String? = nil,
        variant: InitializationVariant = .a
    ) -> [String] {
        if inherited {
            let keyPath = "\\\(modelName).\(property)"
            let getter =
                "if let pending = _\(property) { return pending }\n    return getInheritedValue(keyPath: \(keyPath), property: \"\(escapeSwiftString(property))\", as: \(valueType ?? "Any").self)"
            let setter =
                isRelationship
                ? "setInheritedRelationshipValue(forKey: \(keyPath), to: newValue)"
                : "setInheritedValue(keyPath: \(keyPath), to: newValue)"
            return [
                "@storageRestrictions(initializes: _\(property))\ninit(initialValue) {\n    _\(property) = initialValue\n}",
                "get {\n    access(keyPath: \(keyPath))\n    \(getter)\n}",
                "set {\n    withMutation(keyPath: \(keyPath)) {\n        _\(property) = nil\n        self.\(setter)\n    }\n}",
            ]
        }
        let storageRestriction =
            variant == .c
            ? "@storageRestrictions(accesses: _$backingData)"
            : "@storageRestrictions(accesses: _$backingData, initializes: _\(property))"
        let initializationAssignment = variant == .c ? [] : ["    _\(property) = _SwiftDataNoType()"]
        let initialValueWrite =
            slot.map {
                "    _$backingData.setValue(at: \($0), forKey: \\.\(property), to: initialValue)"
            } ?? "    _$backingData.setValue(forKey: \\.\(property), to: initialValue)"
        let initializer =
            ([
                "\(storageRestriction)",
                "init(initialValue) {",
                initialValueWrite,
            ] + initializationAssignment + ["}"]).joined(separator: "\n")
        let setter =
            isRelationship
            ? "self.setRelationshipValue(forKey: \\.\(property), to: newValue)"
            : slot.map { "self.setValue(at: \($0), forKey: \\.\(property), to: newValue)" }
                ?? "self.setValue(forKey: \\.\(property), to: newValue)"
        let getter =
            slot.map { "self.getValue(at: \($0), forKey: \\.\(property))" }
            ?? "self.getValue(forKey: \\.\(property))"
        return [
            initializer,
            "get {\n    access(keyPath: \\.\(property))\n    return \(getter)\n}",
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

    static func peerSources(property: String, valueType: String, inherited: Bool) -> [String] {
        inherited
            ? ["@Transient\nprivate var _\(property): \(valueType)?"]
            : peerSources(property: property, variant: .c)
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

struct SchemaDirectiveDiagnostic: Error, DiagnosticMessage {
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
