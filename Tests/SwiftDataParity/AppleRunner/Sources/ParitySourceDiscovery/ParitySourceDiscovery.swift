import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

public enum ParitySourceDiscovery {
    public enum DiscoveryError: Error, Equatable, Sendable, CustomStringConvertible {
        case duplicateIdentity(String, String)
        case malformedSource(String, [String])

        public var description: String {
            switch self {
            case let .duplicateIdentity(identity, file): "Duplicate parity identity \(identity) in \(file)"
            case let .malformedSource(file, diagnostics): "Malformed Swift source in \(file): \(diagnostics.joined(separator: "; "))"
            }
        }
    }

    public static func discover(in directory: URL) throws -> Set<String> {
        let files = try swiftFiles(in: directory).sorted { $0.path < $1.path }

        var result = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let syntax = Parser.parse(source: source)
            let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: syntax)
            guard !diagnostics.contains(where: { $0.diagMessage.severity == .error }) else {
                throw DiscoveryError.malformedSource(file.path, diagnostics.map(\.message))
            }
            let visitor = SuiteTestVisitor(viewMode: .sourceAccurate)
            visitor.walk(syntax)
            for identity in visitor.identities {
                guard result.insert(identity).inserted else {
                    throw DiscoveryError.duplicateIdentity(identity, file.path)
                }
            }
        }
        return result
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        var files: [URL] = []
        for child in children.sorted(by: { $0.path < $1.path }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                files += try swiftFiles(in: child)
            } else if values.isRegularFile == true && child.pathExtension == "swift" {
                files.append(child)
            }
        }
        return files
    }
}

private final class SuiteTestVisitor: SyntaxVisitor {
    private var suiteStack: [String] = []
    private(set) var identities: [String] = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        suiteStack.append(hasAttribute("Suite", in: node.attributes) ? node.name.text : "")
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { _ = suiteStack.popLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        suiteStack.append(hasAttribute("Suite", in: node.attributes) ? node.name.text : "")
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { _ = suiteStack.popLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        suiteStack.append(hasAttribute("Suite", in: node.attributes) ? node.name.text : "")
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { _ = suiteStack.popLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let suite = suiteStack.last, !suite.isEmpty, hasAttribute("Test", in: node.attributes) else {
            return .visitChildren
        }
        let name = node.name.description.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        identities.append("\(suite)/\(name)")
        return .visitChildren
    }

    private func hasAttribute(_ expected: String, in attributes: AttributeListSyntax) -> Bool {
        for element in attributes {
            guard case let .attribute(attribute) = element else { continue }
            if attribute.attributeName.trimmedDescription == expected { return true }
        }
        return false
    }
}
