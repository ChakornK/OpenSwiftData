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
        let superclassName = classDeclaration.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription
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
        let members = CodeGen.memberSources(
            classDeclaration, schemaIndexes: schemaIndexes, superclassName: superclassName)
        return members.map(
            DeclSyntax.init(stringLiteral:))
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else { return [] }
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
        let isInheritedModel = classDeclaration.inheritanceClause?.inheritedTypes.isEmpty == false
        let modelName = classDeclaration.name.text
        return [
            AttributeSyntax(
                stringLiteral: isRelationship
                    ? "@_PersistedProperty(slot: \(slot), relationship: true, inherited: \(isInheritedModel), modelName: \"\(modelName)\")"
                    : "@_PersistedProperty(slot: \(slot), inherited: \(isInheritedModel), modelName: \"\(modelName)\")")
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else { return [] }
        if classDeclaration.inheritanceClause?.inheritedTypes.isEmpty == false {
            return CodeGen.extensionSources(classDeclaration)
                .filter { $0.contains("extension PersistentModel where Self:") || $0.contains("@unchecked Sendable") }
                .compactMap { DeclSyntax(stringLiteral: $0).as(ExtensionDeclSyntax.self) }
        }
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

private struct UnsupportedModelInheritanceDiagnostic: DiagnosticMessage {
    let message = "@Model currently requires a final class without a superclass"
    let diagnosticID = MessageID(domain: "OpenSwiftDataMacros", id: "unsupported-model-inheritance")
    let severity = DiagnosticSeverity.error
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
        let inherited =
            node.arguments.flatMap { arguments -> Bool? in
                guard case let .argumentList(list) = arguments,
                    let argument = list.first(where: { $0.label?.text == "inherited" })
                else { return nil }
                return argument.expression.trimmedDescription == "true"
            } ?? false
        let modelName =
            node.arguments.flatMap { arguments -> String? in
                guard case let .argumentList(list) = arguments,
                    let argument = list.first(where: { $0.label?.text == "modelName" }),
                    let literal = argument.expression.as(StringLiteralExprSyntax.self)
                else { return nil }
                return literal.segments.first?.as(StringSegmentSyntax.self)?.content.text
            } ?? ""
        let valueType = variable.bindings.first?.typeAnnotation?.type.trimmedDescription
        return CodeGen.accessorSources(
            property: propertyName, modelName: modelName, slot: slot,
            isRelationship: isRelationship, inherited: inherited, valueType: valueType
        )
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
        let inherited =
            node.arguments.flatMap { arguments -> Bool? in
                guard case let .argumentList(list) = arguments,
                    let argument = list.first(where: { $0.label?.text == "inherited" })
                else { return nil }
                return argument.expression.trimmedDescription == "true"
            } ?? false
        let valueType = binding.typeAnnotation?.type.trimmedDescription ?? "Any"
        return CodeGen.peerSources(property: property, valueType: valueType, inherited: inherited)
            .map(DeclSyntax.init(stringLiteral:))
    }
}
