import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import ParityContracts

// Extracts the SwiftData public API surface from a `.swiftinterface` file and,
// for the `signature-precise` strategy, joins a symbol graph's USRs into the
// extracted symbols.

public enum APISurfaceExtractorError: Error, Equatable, Sendable {
    case unparseableInterface(diagnostics: [String])
}

public enum APISurfaceExtractor {
    /// Parses `interfaceFile` with SwiftParser, walks it with
    /// `SymbolExtractorVisitor`, drops `Excluded_Symbol`s, and returns the
    /// `ExtractedSurface` with precomputed lookup indexes.
    public static func extract(interfaceFile: URL) throws -> ExtractedSurface {
        let bytes = try Data(contentsOf: interfaceFile)
        let source = String(decoding: bytes, as: UTF8.self)
        let tree = Parser.parse(source: source)
        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        let errors = diagnostics.filter { $0.diagMessage.severity == .error }.map(\.message)
        guard errors.isEmpty else {
            throw APISurfaceExtractorError.unparseableInterface(diagnostics: errors)
        }
        let visitor = SymbolExtractorVisitor(viewMode: .sourceAccurate)
        visitor.walk(tree)
        let records = visitor.records
        let nonExcluded = records.filter { !$0.isExcluded }.map(\.symbol)
        let excludedCount = records.count - nonExcluded.count
        return ExtractedSurface(symbols: nonExcluded, excludedCount: excludedCount)
    }

    /// Joins symbol-graph USRs into `surface.symbolsByMangledName`. Reads all
    /// `*.symbols.json` files in `symbolGraphDirectory` (sorted by path) and
    /// matches each symbol-graph symbol to an `API_Symbol` by
    /// `(fullyQualifiedName, kind, arity)`. On any failure (no files, decode
    /// error, zero matches) the surface is left unchanged. Non-throwing per the
    /// design: failures mean `mangledName` stays empty and `signature-precise`
    /// degrades to `name-match`.
    public static func joinSymbolGraph(_ surface: inout ExtractedSurface, symbolGraphDirectory: URL) {
        var graphFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: symbolGraphDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "json" {
                graphFiles.append(url)
            }
        }
        graphFiles.sort { $0.path < $1.path }
        guard !graphFiles.isEmpty else { return }

        let decoder = JSONDecoder()
        var lookup: [String: [Int]] = [:]
        for (index, symbol) in surface.symbols.enumerated() {
            let key = "\(symbol.fullyQualifiedName)#\(symbol.kind.rawValue)#\(symbol.arity)"
            lookup[key, default: []].append(index)
        }

        var newSymbols = surface.symbols
        var newMangledMap: [String: API_Symbol] = [:]
        var matched = false
        for file in graphFiles {
            guard let data = try? Data(contentsOf: file),
                let graph = try? decoder.decode(SymbolGraphFile.self, from: data)
            else { continue }
            for sgSymbol in graph.symbols {
                let fqn = "SwiftData." + sgSymbol.pathComponents.joined(separator: ".")
                guard let kind = Self.kind(for: sgSymbol.kind.identifier) else { continue }
                let arity = sgSymbol.functionSignature?.parameters.count ?? 0
                let key = "\(fqn)#\(kind.rawValue)#\(arity)"
                guard let indices = lookup[key], !indices.isEmpty else { continue }
                for index in indices {
                    newSymbols[index].mangledName = sgSymbol.identifier.usr
                    newMangledMap[sgSymbol.identifier.usr] = newSymbols[index]
                    matched = true
                }
            }
        }
        guard matched else { return }
        surface = ExtractedSurface(symbols: newSymbols, excludedCount: surface.excludedCount)
        surface.symbolsByMangledName = newMangledMap
    }

    /// Maps a symbol-graph kind identifier (e.g. `swift.func`, `swift.struct`)
    /// to the corresponding `SymbolKind`. Returns `nil` for kinds the validator
    /// does not track.
    private static func kind(for identifier: String) -> SymbolKind? {
        switch identifier {
        case "swift.struct": .structKind
        case "swift.class": .classKind
        case "swift.enum": .enumKind
        case "swift.protocol": .protocolKind
        case "swift.actor": .actorKind
        case "swift.typealias": .typealiasKind
        case "swift.func", "swift.method", "swift.method.static", "swift.method.instance": .function
        case "swift.init", "swift.constructor": .initializer
        case "swift.property", "swift.var", "swift.var.instance", "swift.var.static", "swift.var.class": .variable
        case "swift.subscript": .subscriptKind
        case "swift.associatedtype": .associatedtype
        case "swift.macro": .macro
        case "swift.enum.case": .case
        default: nil
        }
    }
}

// MARK: - Symbol graph JSON shapes

// Concrete Codable structs for the subset of `swift symbolgraph-extract` output
// the join needs.

struct SymbolGraphFile: Codable {
    let symbols: [SymbolGraphSymbol]
}

struct SymbolGraphSymbol: Codable {
    let identifier: SymbolGraphIdentifier
    let pathComponents: [String]
    let kind: SymbolGraphKind
    let functionSignature: SymbolGraphFunctionSignature?
}

struct SymbolGraphIdentifier: Codable {
    let usr: String
}

struct SymbolGraphKind: Codable {
    let identifier: String
}

struct SymbolGraphFunctionSignature: Codable {
    let parameters: [SymbolGraphParameter]
}

struct SymbolGraphParameter: Codable {}

// MARK: - SymbolExtractorVisitor

// Walks the parsed `.swiftinterface` and builds `API_Symbol` records. Carries
// the availability of each containing type on `typeStack` so members inherit
// their container's availability (max-of-minimums per platform; `@available(*,
// unavailable)` on a container excludes members unless they reintroduce).

final class SymbolExtractorVisitor: SyntaxVisitor {
    struct Record: Sendable {
        let symbol: API_Symbol
        let isExcluded: Bool
    }

    private var symbols: [API_Symbol] = []
    private var excludedFlags: [Bool] = []
    private var typeStack: [TypeContext] = []
    // Tracks whether the immediately enclosing type is public/open, so members
    // of `internal`/`private` containers are not emitted even if individually
    // marked `public` (Swift's access can't exceed the containing type).
    private var containerIsPublicStack: [Bool] = []

    var records: [Record] {
        zip(symbols, excludedFlags).map { Record(symbol: $0, isExcluded: $1) }
    }

    // MARK: Type declarations (push/pop the type stack)

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushAndEmitType(name: node.name.text, kind: .structKind, attributes: node.attributes, modifiers: node.modifiers, signature: node.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast(); containerIsPublicStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushAndEmitType(name: node.name.text, kind: .classKind, attributes: node.attributes, modifiers: node.modifiers, signature: node.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast(); containerIsPublicStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushAndEmitType(name: node.name.text, kind: .enumKind, attributes: node.attributes, modifiers: node.modifiers, signature: node.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast(); containerIsPublicStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushAndEmitType(name: node.name.text, kind: .protocolKind, attributes: node.attributes, modifiers: node.modifiers, signature: node.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) { typeStack.removeLast(); containerIsPublicStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushAndEmitType(name: node.name.text, kind: .actorKind, attributes: node.attributes, modifiers: node.modifiers, signature: node.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast(); containerIsPublicStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // For an extension, the context is the EXTENDED type (left of any
        // conformance), not the protocol. Members declared inside an
        // unavailable conformance extension are excluded, but the extended type
        // itself is not. Extension members are public by default (extensions
        // don't restrict member access beyond the type's own access).
        let extendedName = node.extendedType.trimmedDescription
        let contribution = parseAvailability(from: node.attributes)
        let availability = contributionToAvailability(contribution)
        let qualified = "SwiftData." + stripModuleQualifier(extendedName)
        let context = TypeContext(fullyQualifiedName: qualified, kind: .structKind, availability: availability)
        typeStack.append(context)
        containerIsPublicStack.append(true)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast(); containerIsPublicStack.removeLast() }

    // MARK: Member declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers), !isSpiAnnotated(node.attributes) {
            emitMember(
                displayName: node.name.text,
                kind: .function,
                sourceSignature: node.trimmedDescription,
                arity: node.signature.parameterClause.parameters.count,
                attributes: node.attributes
            )
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers), !isSpiAnnotated(node.attributes) {
            emitMember(
                displayName: "init",
                kind: .initializer,
                sourceSignature: node.trimmedDescription,
                arity: node.signature.parameterClause.parameters.count,
                attributes: node.attributes
            )
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers), !isSpiAnnotated(node.attributes) {
            for binding in node.bindings {
                if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                    emitMember(
                        displayName: pattern.identifier.text,
                        kind: .variable,
                        sourceSignature: node.trimmedDescription,
                        arity: 0,
                        attributes: node.attributes
                    )
                }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers), !isSpiAnnotated(node.attributes) {
            emitMember(
                displayName: "subscript",
                kind: .subscriptKind,
                sourceSignature: node.trimmedDescription,
                arity: node.parameterClause.parameters.count,
                attributes: node.attributes
            )
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers), !isSpiAnnotated(node.attributes) {
            emitMember(
                displayName: node.name.text,
                kind: .typealiasKind,
                sourceSignature: node.trimmedDescription,
                arity: 0,
                attributes: node.attributes
            )
        }
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers), !isSpiAnnotated(node.attributes) {
            emitMember(
                displayName: node.name.text,
                kind: .associatedtype,
                sourceSignature: node.trimmedDescription,
                arity: 0,
                attributes: node.attributes
            )
        }
        return .visitChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers), !isSpiAnnotated(node.attributes) {
            emitMember(
                displayName: node.name.text,
                kind: .macro,
                sourceSignature: node.trimmedDescription,
                arity: node.signature.parameterClause.parameters.count,
                attributes: node.attributes
            )
        }
        return .visitChildren
    }

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        // Cases inherit access and availability from the containing enum at the
        // top of `typeStack`. SPI annotations on the enum itself are checked
        // when the enum is pushed; case elements have no attributes of their
        // own in a `.swiftinterface`.
        guard !typeStack.isEmpty else { return .visitChildren }
        emitMember(
            displayName: node.name.text,
            kind: .case,
            sourceSignature: node.trimmedDescription,
            arity: node.parameterClause?.parameters.count ?? 0,
            attributes: AttributeListSyntax([])
        )
        return .visitChildren
    }

    // MARK: Helpers

    private func pushType(name: String, kind: SymbolKind, attributes: AttributeListSyntax) {
        let contribution = parseAvailability(from: attributes)
        let availability = contributionToAvailability(contribution)
        let qualified = "SwiftData." + stripModuleQualifier(name)
        typeStack.append(TypeContext(fullyQualifiedName: qualified, kind: kind, availability: availability))
    }

    /// Emits a type declaration as a symbol (when public) and pushes its
    /// context onto the type stack so members inherit its availability.
    private func pushAndEmitType(
        name: String,
        kind: SymbolKind,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        signature: String
    ) {
        let containerIsPublic = isPublic(modifiers) && !isSpiAnnotated(attributes)
        if containerIsPublic {
            emitMember(
                displayName: name,
                kind: kind,
                sourceSignature: signature,
                arity: 0,
                attributes: attributes
            )
        }
        pushType(name: name, kind: kind, attributes: attributes)
        containerIsPublicStack.append(containerIsPublic)
    }

    private func emitMember(
        displayName: String,
        kind: SymbolKind,
        sourceSignature: String,
        arity: Int,
        attributes: AttributeListSyntax
    ) {
        // Skip members of a non-public container. Top-level declarations have
        // no container (empty stack) and are emitted unconditionally; their
        // own access is checked at the call site.
        if let containerIsPublic = containerIsPublicStack.last, !containerIsPublic {
            return
        }
        let own = parseAvailability(from: attributes)
        let merged = mergeAvailability(own: own)
        let fqn = qualifiedName(forMember: displayName)
        let symbol = API_Symbol(
            kind: kind,
            displayName: backtickStrip(displayName),
            fullyQualifiedName: fqn,
            sourceSignature: sourceSignature,
            platformAvailability: merged.availability,
            arity: arity,
            mangledName: "",
            deprecated: merged.deprecated
        )
        symbols.append(symbol)
        excludedFlags.append(merged.excluded)
    }

    /// The fully-qualified name for a member: the containing type's qualified
    /// name (top of the stack) joined with the member's base identifier, with
    /// module qualifiers stripped. Always `SwiftData.`-prefixed.
    private func qualifiedName(forMember base: String) -> String {
        let stripped = stripModuleQualifier(base)
        if let parent = typeStack.last {
            return "\(parent.fullyQualifiedName).\(stripped)"
        }
        return "SwiftData.\(stripped)"
    }

    /// Strips module qualifiers (`SwiftData::`, `Foundation::`, `Swift::`,
    /// `_Concurrency::`, `Observation::`) from a type name.
    private func stripModuleQualifier(_ name: String) -> String {
        let qualifiers = ["SwiftData::", "Foundation::", "Swift::", "_Concurrency::", "Observation::"]
        var result = name
        for qualifier in qualifiers where result.hasPrefix(qualifier) {
            result = String(result.dropFirst(qualifier.count))
        }
        return result
    }

    /// Removes backticks from a display name.
    private func backtickStrip(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "\\`"))
    }

    /// Returns `true` when the modifiers contain `public` or `open`.
    private func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "public" || $0.name.text == "open" }
    }

    /// Returns `true` when the declaration is annotated `@_spi(...)`.
    private func isSpiAnnotated(_ attributes: AttributeListSyntax) -> Bool {
        for element in attributes {
            if case let .attribute(attribute) = element,
                attribute.attributeName.trimmedDescription == "_spi"
            {
                return true
            }
        }
        return false
    }

    // MARK: Availability parsing and merging

    /// Parsed availability contribution from a set of `@available(...)` attributes.
    struct AvailabilityContribution {
        var macOS: String?
        var iOS: String?
        var tvOS: String?
        var watchOS: String?
        var visionOS: String?
        var starUnavailable: Bool = false
        var deprecated: Bool = false
    }

    /// The merged result for a symbol: the effective availability plus whether
    /// the symbol is excluded (unavailable on every platform it targets).
    struct MergedAvailability {
        let availability: PlatformAvailability
        let excluded: Bool
        let deprecated: Bool
    }

    /// Parses every `@available(...)` attribute on the declaration into a
    /// single contribution. Non-availability attributes are ignored.
    private func parseAvailability(from attributes: AttributeListSyntax) -> AvailabilityContribution {
        var contribution = AvailabilityContribution()
        for element in attributes {
            if case let .attribute(attribute) = element,
                attribute.attributeName.trimmedDescription == "available",
                case let .availability(arguments) = attribute.arguments
            {
                mergeArguments(arguments, into: &contribution)
            }
        }
        return contribution
    }

    /// Parses one `@available(...)` argument list into `contribution`.
    private func mergeArguments(_ arguments: AvailabilityArgumentListSyntax, into contribution: inout AvailabilityContribution) {
        var currentPlatform: String?
        let knownPlatforms: Set<String> = ["macOS", "iOS", "tvOS", "watchOS", "visionOS", "swift"]
        for argument in arguments {
            switch argument.argument {
            case .availabilityVersionRestriction(let platformVersion):
                let platform = platformVersion.platform.text
                currentPlatform = platform
                if let version = platformVersion.version {
                    contribution.setPlatform(platform, normalize(version))
                } else {
                    contribution.markPlatform(platform)
                }
            case .availabilityLabeledArgument(let labeled):
                applyLabeled(labeled, currentPlatform: currentPlatform, into: &contribution)
            case .token(let token):
                // A bare identifier may be a platform name (longhand form like
                // `@available(macOS, introduced: 14.0)` where `macOS` parses as
                // a token rather than a `PlatformVersionSyntax`). Track it as
                // the current platform so subsequent labeled args (`introduced:`,
                // `deprecated:`, `unavailable:`) apply to it.
                let text = token.text
                if knownPlatforms.contains(text) {
                    currentPlatform = text
                    contribution.markPlatform(text)
                } else {
                    applyToken(token, currentPlatform: currentPlatform, into: &contribution)
                }
            @unknown default:
                continue
            }
        }
    }

    private func applyLabeled(_ labeled: AvailabilityLabeledArgumentSyntax, currentPlatform: String?, into contribution: inout AvailabilityContribution) {
        let label = labeled.label.text
        switch label {
        case "introduced":
            if let platform = currentPlatform, case .version(let version) = labeled.value {
                contribution.setPlatform(platform, normalize(version))
            }
        case "deprecated":
            contribution.deprecated = true
        case "obsoleted":
            contribution.deprecated = true
        case "unavailable":
            if let platform = currentPlatform {
                contribution.setUnavailable(platform)
            } else {
                contribution.starUnavailable = true
            }
        case "renamed", "message":
            break
        default:
            break
        }
    }

    private func applyToken(_ token: TokenSyntax, currentPlatform: String?, into contribution: inout AvailabilityContribution) {
        let text = token.text
        if text == "*" {
            // `*` alone marks no platform; combined with `deprecated`/`unavailable`
            // handled by subsequent tokens.
        } else if text == "deprecated" {
            contribution.deprecated = true
        } else if text == "unavailable" {
            contribution.starUnavailable = true
        }
        // `swift` (e.g. `@available(swift 5.9)`) is handled as a platform with no
        // version above; `swift` is not a tracked platform so `setPlatform`
        // ignores it.
    }

    /// Normalizes a `VersionTupleSyntax` to `major.minor` (bare major →
    /// `major.0`). Tokens not matching `^\d+(\.\d+)?$` become `nil`.
    private func normalize(_ version: VersionTupleSyntax) -> String? {
        let major = version.major.text
        let components = version.components
        if components.isEmpty {
            return "\(major).0"
        }
        var parts = [major]
        for component in components {
            parts.append(component.number.text)
        }
        let joined = parts.joined(separator: ".")
        let regex = try? NSRegularExpression(pattern: #"^\d+(\.\d+)?$"#)
        guard let regex, regex.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)) != nil else {
            return nil
        }
        return joined
    }

    /// Merges a member's own availability with the containing types' availability
    /// (max-of-minimums per platform; container `*`-unavailable propagates
    /// unless the member reintroduces a platform).
    private func mergeAvailability(own: AvailabilityContribution) -> MergedAvailability {
        var macOS = own.macOS
        var iOS = own.iOS
        var tvOS = own.tvOS
        var watchOS = own.watchOS
        var visionOS = own.visionOS
        var starUnavailable = own.starUnavailable
        var deprecated = own.deprecated

        for context in typeStack {
            macOS = maxVersion(macOS, context.availability.macOS)
            iOS = maxVersion(iOS, context.availability.iOS)
            tvOS = maxVersion(tvOS, context.availability.tvOS)
            watchOS = maxVersion(watchOS, context.availability.watchOS)
            visionOS = maxVersion(visionOS, context.availability.visionOS)
            if context.availability.unavailable { starUnavailable = true }
            if context.availability.deprecated { deprecated = true }
        }

        // Platforms the member reintroduces (own version non-nil) override a
        // container's `*`-unavailable.
        let reintroduced: Set<String> = {
            var set = Set<String>()
            if own.macOS != nil { set.insert("macOS") }
            if own.iOS != nil { set.insert("iOS") }
            if own.tvOS != nil { set.insert("tvOS") }
            if own.watchOS != nil { set.insert("watchOS") }
            if own.visionOS != nil { set.insert("visionOS") }
            return set
        }()

        var mentioned: Set<String> = []
        if macOS != nil { mentioned.insert("macOS") }
        if iOS != nil { mentioned.insert("iOS") }
        if tvOS != nil { mentioned.insert("tvOS") }
        if watchOS != nil { mentioned.insert("watchOS") }
        if visionOS != nil { mentioned.insert("visionOS") }

        // Platforms effectively unavailable: those mentioned but not
        // reintroduced, when `starUnavailable` is set.
        let effectiveUnavailable: Set<String> = starUnavailable
            ? mentioned.subtracting(reintroduced)
            : []

        let excluded: Bool
        if mentioned.isEmpty {
            excluded = starUnavailable
        } else {
            excluded = mentioned.isSubset(of: effectiveUnavailable)
        }

        let availability = PlatformAvailability(
            macOS: macOS,
            iOS: iOS,
            tvOS: tvOS,
            watchOS: watchOS,
            visionOS: visionOS,
            unavailable: starUnavailable && reintroduced.isEmpty,
            deprecated: deprecated
        )
        return MergedAvailability(availability: availability, excluded: excluded, deprecated: deprecated)
    }

    /// Returns the greater of two `major.minor` version strings (numeric
    /// component-wise). `nil` is treated as "no constraint".
    private func maxVersion(_ a: String?, _ b: String?) -> String? {
        switch (a, b) {
        case (nil, let other): return other
        case (let other, nil): return other
        case (let a?, let b?):
            let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
            let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
            let count = max(aParts.count, bParts.count)
            for i in 0..<count {
                let av = i < aParts.count ? aParts[i] : 0
                let bv = i < bParts.count ? bParts[i] : 0
                if bv > av { return b }
                if av > bv { return a }
            }
            return a
        }
    }

    /// Converts a contribution (own availability) into a `PlatformAvailability`
    /// for a `TypeContext`. Types do not merge across a stack here; the merge
    /// happens for members.
    private func contributionToAvailability(_ contribution: AvailabilityContribution) -> PlatformAvailability {
        PlatformAvailability(
            macOS: contribution.macOS,
            iOS: contribution.iOS,
            tvOS: contribution.tvOS,
            watchOS: contribution.watchOS,
            visionOS: contribution.visionOS,
            unavailable: contribution.starUnavailable,
            deprecated: contribution.deprecated
        )
    }
}

// MARK: - AvailabilityContribution helpers

extension SymbolExtractorVisitor.AvailabilityContribution {
    mutating func setPlatform(_ name: String, _ version: String?) {
        switch name {
        case "macOS": macOS = version ?? macOS
        case "iOS": iOS = version ?? iOS
        case "tvOS": tvOS = version ?? tvOS
        case "watchOS": watchOS = version ?? watchOS
        case "visionOS": visionOS = version ?? visionOS
        default: break
        }
    }

    mutating func markPlatform(_ name: String) {
        switch name {
        case "macOS": if macOS == nil { macOS = "0.0" }
        case "iOS": if iOS == nil { iOS = "0.0" }
        case "tvOS": if tvOS == nil { tvOS = "0.0" }
        case "watchOS": if watchOS == nil { watchOS = "0.0" }
        case "visionOS": if visionOS == nil { visionOS = "0.0" }
        default: break
        }
    }

    mutating func setUnavailable(_ name: String) {
        switch name {
        case "macOS": macOS = nil
        case "iOS": iOS = nil
        case "tvOS": tvOS = nil
        case "watchOS": watchOS = nil
        case "visionOS": visionOS = nil
        default: break
        }
    }
}
