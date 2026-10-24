import SwiftSyntax
import SwiftSyntaxBuilder

enum CodeGen {
    struct Property {
        let name: String
        let initializer: String?
        let metadata: String?
        let isTransient: Bool
        let isComputed: Bool
        let isStatic: Bool
        let isLazy: Bool

        init(
            name: String,
            initializer: String? = nil,
            metadata: String? = nil,
            isTransient: Bool = false,
            isComputed: Bool = false,
            isStatic: Bool = false,
            isLazy: Bool = false
        ) {
            self.name = name
            self.initializer = initializer
            self.metadata = metadata
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
            var transient = false
            for element in attributes {
                guard case let .attribute(attribute) = element,
                    let arguments = attribute.arguments,
                    case let .argumentList(argumentList) = arguments
                else {
                    if case let .attribute(attribute) = element,
                        attribute.attributeName.trimmedDescription == "Transient"
                    {
                        transient = true
                    }
                    continue
                }

                let attributeName = attribute.attributeName.trimmedDescription
                guard attributeName == "Attribute" || attributeName == "Relationship" else { continue }
                let metadataArguments = argumentList.trimmedDescription.trimmingWhitespace()
                resolvedMetadata = "Schema.\(attributeName)(\(metadataArguments))"
            }
            metadata = resolvedMetadata
            isTransient = transient
        }
    }

    static func memberSources(_ declaration: ClassDeclSyntax, variant: InitializationVariant = .a) -> [String] {
        let modelName = declaration.name.text
        let properties = persistedProperties(in: declaration)
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
            backingInitializer,
            "@Transient\nprivate let _$observationRegistrar = Observation.ObservationRegistrar()",
            "internal nonisolated func access<_M>(keyPath: KeyPath<\(modelName), _M>) {\n    _$observationRegistrar.access(self, keyPath: keyPath)\n}",
            "internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<\(modelName), _M>, _ mutation: () throws -> _MR) rethrows -> _MR {\n    try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)\n}",
            "struct _SwiftDataNoType {}",
        ]
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
            "extension \(modelName): Observation.Observable {}",
            "extension \(modelName): @unchecked Sendable {}",
        ]
    }

    static func extensionSources(modelName: String) -> [String] {
        [
            "extension \(modelName): PersistentModel {}",
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
