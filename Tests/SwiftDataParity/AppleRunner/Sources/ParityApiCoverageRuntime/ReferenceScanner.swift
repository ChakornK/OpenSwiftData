import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

// Scans parity source and implementation directories for syntactic references
// to SwiftData API symbols. A reference is recorded only when its identifier
// matches a known `displayName`. Stoplisted names are gated on an import or a
// SwiftData-typed receiver. The scan is non-throwing: parse and read failures
// become entries in the returned `issues` list.

public enum ReferenceScanner {
    /// Scans `roots` for references to symbols whose `displayName` is in
    /// `knownDisplayNames`. Returns the references and any per-file issues
    /// (parse errors, read failures). Scan order is lexicographic by path so
    /// reference emission is deterministic.
    public static func scan(
        roots: [URL],
        repositoryRoot: URL,
        knownDisplayNames: Set<String>,
        knownTypeDisplayNames: Set<String>,
        nameStoplist: Set<String>
    ) -> (references: [Reference], issues: [String]) {
        var references: [Reference] = []
        var issues: [String] = []
        for root in roots {
            scanDirectory(
                root,
                repositoryRoot: repositoryRoot,
                knownDisplayNames: knownDisplayNames,
                knownTypeDisplayNames: knownTypeDisplayNames,
                nameStoplist: nameStoplist,
                references: &references,
                issues: &issues
            )
        }
        return (references, issues)
    }

    /// Recursively walks `directory`, mirroring `ParitySourceDiscovery`'s
    /// file walk: sorts children by path, skips symlinks and hidden entries,
    /// recurses into subdirectories, collects `.swift` files.
    private static func scanDirectory(
        _ directory: URL,
        repositoryRoot: URL,
        knownDisplayNames: Set<String>,
        knownTypeDisplayNames: Set<String>,
        nameStoplist: Set<String>,
        references: inout [Reference],
        issues: inout [String]
    ) {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.path < $1.path }
        } catch {
            return
        }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                scanDirectory(
                    child,
                    repositoryRoot: repositoryRoot,
                    knownDisplayNames: knownDisplayNames,
                    knownTypeDisplayNames: knownTypeDisplayNames,
                    nameStoplist: nameStoplist,
                    references: &references,
                    issues: &issues
                )
            } else if values?.isRegularFile == true && child.pathExtension == "swift" {
                scanFile(
                    child,
                    repositoryRoot: repositoryRoot,
                    knownDisplayNames: knownDisplayNames,
                    knownTypeDisplayNames: knownTypeDisplayNames,
                    nameStoplist: nameStoplist,
                    references: &references,
                    issues: &issues
                )
            }
        }
    }

    /// Parses and scans a single `.swift` file. Parse/read failures append an
    /// issue and skip the file. The file is parsed exactly once; the same tree
    /// is walked by `ImportCollector` then `ReferenceVisitor`.
    private static func scanFile(
        _ file: URL,
        repositoryRoot: URL,
        knownDisplayNames: Set<String>,
        knownTypeDisplayNames: Set<String>,
        nameStoplist: Set<String>,
        references: inout [Reference],
        issues: inout [String]
    ) {
        let relativePath = relativePath(file: file, repositoryRoot: repositoryRoot)
        let source: String
        do {
            source = try String(contentsOf: file, encoding: .utf8)
        } catch {
            issues.append("\(relativePath): \(error)")
            return
        }
        let tree = Parser.parse(source: source)
        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        let errors = diagnostics.filter { $0.diagMessage.severity == .error }.map(\.message)
        if !errors.isEmpty {
            issues.append("\(relativePath): \(errors.joined(separator: "; "))")
            return
        }
        let converter = SourceLocationConverter(fileName: file.path, tree: tree)
        let importCollector = ImportCollector(viewMode: .sourceAccurate)
        importCollector.walk(tree)
        let visitor = ReferenceVisitor(
            knownDisplayNames: knownDisplayNames,
            knownTypeDisplayNames: knownTypeDisplayNames,
            nameStoplist: nameStoplist,
            importsSwiftDataFamily: importCollector.importsSwiftDataFamily,
            converter: converter,
            relativePath: relativePath
        )
        visitor.walk(tree)
        references.append(contentsOf: visitor.references)
    }

    /// Computes the repository-root-relative POSIX path of `file`.
    private static func relativePath(file: URL, repositoryRoot: URL) -> String {
        let rootPath = repositoryRoot.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        let stripped = String(filePath.dropFirst(rootPath.count))
        return stripped.hasPrefix("/") ? String(stripped.dropFirst()) : stripped
    }
}

// MARK: - ImportCollector

/// Collects whether a source file imports a SwiftData-family module
/// (`SwiftData`, `OpenSwiftData`, or `OpenSwiftDataSQLite`).
final class ImportCollector: SyntaxVisitor {
    private(set) var importsSwiftDataFamily = false

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let path = node.path.map(\.name.text)
        if path.contains("SwiftData") || path.contains("OpenSwiftData") || path.contains("OpenSwiftDataSQLite") {
            importsSwiftDataFamily = true
        }
        return .visitChildren
    }
}

// MARK: - ReferenceVisitor

/// Records references to known `displayName`s. Stoplisted names are gated on
/// an import or a SwiftData-typed receiver. `FunctionCallExprSyntax` is not
/// visited directly; its `calledExpression` is already a `DeclReferenceExpr`
/// or `MemberAccessExpr`, and visiting both would double-count.
final class ReferenceVisitor: SyntaxVisitor {
    private(set) var references: [Reference] = []

    private let knownDisplayNames: Set<String>
    private let knownTypeDisplayNames: Set<String>
    private let nameStoplist: Set<String>
    private let importsSwiftDataFamily: Bool
    private let converter: SourceLocationConverter
    private let relativePath: String

    init(
        knownDisplayNames: Set<String>,
        knownTypeDisplayNames: Set<String>,
        nameStoplist: Set<String>,
        importsSwiftDataFamily: Bool,
        converter: SourceLocationConverter,
        relativePath: String
    ) {
        self.knownDisplayNames = knownDisplayNames
        self.knownTypeDisplayNames = knownTypeDisplayNames
        self.nameStoplist = nameStoplist
        self.importsSwiftDataFamily = importsSwiftDataFamily
        self.converter = converter
        self.relativePath = relativePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, matchQuality: .name, node: node)
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, matchQuality: .name, node: node)
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // Skip a `DeclReferenceExpr` that is the `declName` of a
        // `MemberAccessExpr` — the member access visit handles it (and applies
        // the stoplist gate). Visiting both would double-count.
        if node.parent?.as(MemberAccessExprSyntax.self) != nil {
            return .visitChildren
        }
        record(name: node.baseName.text, matchQuality: .name, node: node)
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // For a member access, the receiver base may name a known SwiftData
        // type, which gates stoplisted members even without an import.
        let memberName = node.declName.baseName.text
        let receiverName = receiverIdentifier(of: node.base)
        let receiverIsKnownType = receiverName.map { knownTypeDisplayNames.contains($0) } ?? false
        if nameStoplist.contains(memberName) {
            if importsSwiftDataFamily || receiverIsKnownType {
                record(name: memberName, matchQuality: .nameContext, node: node)
            }
        } else {
            record(name: memberName, matchQuality: .name, node: node)
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Subscript calls (e.g. `results[0]`, `tombstone[\.code]`,
        // `self[id, as: T.self]`) do not contain a `subscript` keyword token;
        // only subscript declarations do (in `SubscriptDeclSyntax`, which
        // the scanner does not visit). The literal display name `"subscript"`
        // matches every `subscript`-kind `API_Symbol` via `name-match`.
        record(name: "subscript", matchQuality: .name, node: node)
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        // `#Unique<...>(...)` at class-member declaration position parses as
        // `MacroExpansionDeclSyntax`; `macroName.text` is the macro name
        // without `#` (e.g. `"Unique"`). Only names in `knownDisplayNames` are
        // recorded (the `record` helper gates).
        record(name: node.macroName.text, matchQuality: .name, node: node)
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        // `#expect(...)`, `#Predicate { ... }`, `#require(...)` parse as
        // `MacroExpansionExprSyntax`. Only names in `knownDisplayNames` are
        // recorded (the `record` helper gates), so `#expect`/`#require` are
        // filtered out.
        record(name: node.macroName.text, matchQuality: .name, node: node)
        return .visitChildren
    }

    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // `~=` is the pattern-match operator. It is always a
        // `BinaryOperatorExprSyntax` whose `operator.text == "~="`. Filter on
        // the operator text so other binary operators are not passed to
        // `record`.
        if node.operator.text == "~=" {
            record(name: "~=", matchQuality: .name, node: node)
        }
        return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        // `@_PersistedProperty(...)`, `@_TransformablePersistedProperty`,
        // `@Model`, `@Attribute(.unique)`, etc. The attribute name is the
        // `attributeName` TypeSyntax without `@`. Extract from
        // `IdentifierTypeSyntax` (the common form) or `MemberTypeSyntax`
        // (for `@Foo.Bar`, not present in scanned sources but handled for
        // completeness). Only names in `knownDisplayNames` are recorded.
        if let identifierType = node.attributeName.as(IdentifierTypeSyntax.self) {
            record(name: identifierType.name.text, matchQuality: .name, node: node)
        } else if let memberType = node.attributeName.as(MemberTypeSyntax.self) {
            record(name: memberType.name.text, matchQuality: .name, node: node)
        }
        return .visitChildren
    }

    /// Records a reference for `name` when it matches a known `displayName`.
    /// `node` provides the source location via the converter.
    private func record(name: String, matchQuality: Reference.MatchQuality, node: some SyntaxProtocol) {
        let stripped = backtickStrip(name)
        guard knownDisplayNames.contains(stripped) else { return }
        let loc = node.startLocation(converter: converter)
        references.append(Reference(
            file: relativePath,
            line: loc.line,
            column: loc.column,
            displayName: stripped,
            matchQuality: matchQuality
        ))
    }

    private func backtickStrip(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "\\`"))
    }

    /// Recursively unwraps a member-access/decl-reference/parenthesized base
    /// expression to find the receiver's identifier text, if any.
    private func receiverIdentifier(of expr: ExprSyntax?) -> String? {
        guard let expr else { return nil }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return receiverIdentifier(of: member.base)
        }
        if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            return backtickStrip(declRef.baseName.text)
        }
        if let tuple = expr.as(TupleExprSyntax.self), let first = tuple.elements.first {
            return receiverIdentifier(of: first.expression)
        }
        return nil
    }
}
