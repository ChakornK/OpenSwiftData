import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct OpenSwiftDataMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ModelMacro.self,
        AttributeMacro.self,
        RelationshipMacro.self,
        TransientMacro.self,
        UniqueMacro.self,
        IndexMacro.self,
        ModelActorMacro.self,
        PersistedPropertyMacro.self,
    ]
}

struct ModelMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else { return [] }
        diagnoseGroupedBindingsForTesting(in: classDeclaration, context: context)
        let schemaIndexes = try CodeGen.schemaIndexSourcesValidating(in: classDeclaration)
        for member in classDeclaration.memberBlock.members {
            guard let directive = member.decl.as(MacroExpansionDeclSyntax.self) else { continue }
            let kind: CodeGen.SchemaDirectiveKind
            switch directive.macroName.trimmedDescription {
            case "Index": kind = .index
            case "Unique": kind = .unique
            default: continue
            }
            let properties = try CodeGen.schemaDirectiveProperties(directive, kind: kind)
            try CodeGen.validateSchemaDirectiveTargets(properties, kind: kind, in: classDeclaration)
        }
        return CodeGen.memberSources(classDeclaration, schemaIndexes: schemaIndexes).map(
            DeclSyntax.init(stringLiteral:))
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let variable = member.as(VariableDeclSyntax.self),
            let binding = variable.bindings.first, variable.bindings.count == 1,
            binding.pattern.is(IdentifierPatternSyntax.self),
            binding.accessorBlock == nil,
            !variable.modifiers.contains(where: { ["static", "class", "lazy"].contains($0.name.text) }),
            !variable.attributes.contains(where: { element in
                guard case let .attribute(attribute) = element else { return false }
                return attribute.attributeName.trimmedDescription == "Transient"
            })
        else { return [] }
        guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else { return [] }
        let rawPropertyName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
        let propertyName =
            rawPropertyName.first == "`" && rawPropertyName.last == "`"
            ? String(rawPropertyName.dropFirst().dropLast()) : rawPropertyName
        guard
            let slot = CodeGen.persistedProperties(in: classDeclaration).firstIndex(where: { $0.name == propertyName })
        else { return [] }
        let isRelationship = variable.attributes.contains { element in
            guard case let .attribute(attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == "Relationship"
        }
        return [
            AttributeSyntax(
                stringLiteral: isRelationship
                    ? "@_PersistedProperty(slot: \(slot), relationship: true)"
                    : "@_PersistedProperty(slot: \(slot))")
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        return CodeGen.extensionSources(declaration)
            .filter {
                $0.contains("PersistentModel") || $0.contains("RelationshipModel")
                    || $0.contains("Observation.Observable") || $0.contains("@unchecked Sendable")
            }
            .compactMap { DeclSyntax(stringLiteral: $0).as(ExtensionDeclSyntax.self) }
    }

    static func diagnoseGroupedBindingsForTesting(
        in declaration: ClassDeclSyntax,
        context: some MacroExpansionContext
    ) {
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), variable.bindings.count > 1 else {
                continue
            }
            let diagnostic = Diagnostic(
                node: Syntax(variable),
                message: GroupedBindingDiagnostic()
            )
            context.diagnose(diagnostic)
        }
    }
}

private struct GroupedBindingDiagnostic: DiagnosticMessage {
    let message =
        "@Model does not support variable declarations with multiple bindings; split each property into its own declaration"
    let diagnosticID = MessageID(domain: "OpenSwiftDataMacros", id: "grouped-model-bindings")
    let severity = DiagnosticSeverity.error
}

struct AttributeMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

struct RelationshipMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

struct TransientMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

struct UniqueMacro: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        _ = try CodeGen.schemaDirectiveProperties(node, kind: .unique)
        guard context.lexicalContext.contains(where: { $0.is(ClassDeclSyntax.self) }) else {
            throw SchemaDirectiveDiagnostic("#Unique must be declared inside an @Model type.")
        }
        return []
    }
}

struct IndexMacro: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        _ = try CodeGen.schemaDirectiveProperties(node, kind: .index)
        guard context.lexicalContext.contains(where: { $0.is(ClassDeclSyntax.self) }) else {
            throw SchemaDirectiveDiagnostic("#Index must be declared inside an @Model type.")
        }
        return []
    }
}

struct ModelActorMacro: MemberMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let actor = declaration.as(ActorDeclSyntax.self) else { return [] }
        return CodeGen.modelActorMemberSources(actorName: actor.name.text).map(DeclSyntax.init(stringLiteral:))
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let actor = declaration.as(ActorDeclSyntax.self) else { return [] }
        return [DeclSyntax(stringLiteral: CodeGen.modelActorExtensionSource(actorName: actor.name.text))]
            .compactMap { $0.as(ExtensionDeclSyntax.self) }
    }
}

struct PersistedPropertyMacro: AccessorMacro, PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self), variable.bindings.count == 1,
            let binding = variable.bindings.first,
            let propertyName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else { return [] }
        let isRelationship: Bool
        if case let .argumentList(arguments)? = node.arguments,
            let relationshipArgument = arguments.first(where: { $0.label?.text == "relationship" })
        {
            isRelationship = relationshipArgument.expression.trimmedDescription == "true"
        } else {
            isRelationship = false
        }
        let slot = node.arguments.flatMap { arguments -> Int? in
            guard case let .argumentList(list) = arguments,
                let argument = list.first(where: { $0.label?.text == "slot" })
            else { return nil }
            return Int(argument.expression.trimmedDescription)
        }
        return CodeGen.accessorSources(property: propertyName, slot: slot, isRelationship: isRelationship)
            .map(AccessorDeclSyntax.init(stringLiteral:))
    }

    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self), variable.bindings.count == 1,
            let binding = variable.bindings.first,
            let property = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else { return [] }
        return CodeGen.peerSources(property: property, variant: .c).map(DeclSyntax.init(stringLiteral:))
    }
}
