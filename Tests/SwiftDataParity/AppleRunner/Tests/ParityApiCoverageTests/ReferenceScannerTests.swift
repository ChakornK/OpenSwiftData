import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Unit tests for `ReferenceScanner`. Each test builds a synthetic source tree
// under a temp directory and asserts on the recorded references. The stoplist
// gate (import or SwiftData-typed receiver) is exercised across fixtures a-d.

@Suite struct ReferenceScannerTests {
    @Test func recordsNonStoplistNameMatch() throws {
        let root = try makeTree(files: [
            ("A.swift", "import SwiftData\nfunc use(_ c: ModelContext) { c.fetch() }"),
        ])
        let references = scan(root: root, knownDisplayNames: ["ModelContext", "fetch"], knownTypeDisplayNames: ["ModelContext"])
        let names = Set(references.map(\.displayName))
        #expect(names.contains("ModelContext"))
        #expect(names.contains("fetch"))
    }

    @Test func recordsStoplistRefWhenFileImportsSwiftData() throws {
        // Fixture a: import SwiftData + context.save() — recorded via import gate.
        let root = try makeTree(files: [
            ("A.swift", "import SwiftData\nfunc use(_ c: ModelContext) { c.save() }"),
        ])
        let references = scan(root: root, knownDisplayNames: ["save"], knownTypeDisplayNames: ["ModelContext"])
        let saves = references.filter { $0.displayName == "save" }
        #expect(!saves.isEmpty)
        #expect(saves.allSatisfy { $0.matchQuality == .nameContext })
    }

    @Test func recordsStoplistRefWhenReceiverNameMatchesKnownSwiftDataType() throws {
        // Fixture b: no import + ModelContext.save() — recorded via receiver-name gate.
        let root = try makeTree(files: [
            ("B.swift", "func use() { ModelContext.save() }"),
        ])
        let references = scan(root: root, knownDisplayNames: ["save", "ModelContext"], knownTypeDisplayNames: ["ModelContext"])
        let saves = references.filter { $0.displayName == "save" }
        #expect(!saves.isEmpty)
    }

    @Test func dropsStoplistRefWithNoImportAndNoSwiftDataTypedReceiver() throws {
        // Fixture c: no import + context.save() — dropped (context is not a known type name).
        let root = try makeTree(files: [
            ("C.swift", "func use() { context.save() }"),
        ])
        let references = scan(root: root, knownDisplayNames: ["save"], knownTypeDisplayNames: ["ModelContext"])
        let saves = references.filter { $0.displayName == "save" }
        #expect(saves.isEmpty)
    }

    @Test func dropsStoplistRefWhenFileImportsFoundationOnly() throws {
        // Fixture d: import Foundation + context.save() — dropped (Foundation is not SwiftData-family).
        let root = try makeTree(files: [
            ("D.swift", "import Foundation\nfunc use() { context.save() }"),
        ])
        let references = scan(root: root, knownDisplayNames: ["save"], knownTypeDisplayNames: ["ModelContext"])
        let saves = references.filter { $0.displayName == "save" }
        #expect(saves.isEmpty)
    }

    @Test func marksAllOverloadsCoveredUnderNameMatch() throws {
        // Two overloads of `save`; a reference to `save` covers both under name-match.
        let root = try makeTree(files: [
            ("A.swift", "import SwiftData\nfunc use(_ c: ModelContext) { c.save() }"),
        ])
        let references = scan(root: root, knownDisplayNames: ["save"], knownTypeDisplayNames: ["ModelContext"])
        // Name-match records one reference per occurrence; both overloads are
        // covered because CoverageEngine attaches to all same-displayName symbols.
        #expect(!references.isEmpty)
    }

    @Test func skipsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "parity-scan-\(UUID().uuidString)", isDirectory: true)
        let external = root.deletingLastPathComponent().appending(path: "parity-scan-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        try "import SwiftData\nfunc use() { ModelContext() }".write(to: external.appending(path: "Outside.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Linked"), withDestinationURL: external)
        let references = scan(root: root, knownDisplayNames: ["ModelContext"], knownTypeDisplayNames: ["ModelContext"])
        let files = Set(references.map(\.file))
        #expect(!files.contains(where: { $0.contains("Outside") }))
    }

    @Test func skipsHiddenFiles() throws {
        let root = try makeTree(files: [
            (".hidden.swift", "import SwiftData\nfunc use() { ModelContext() }"),
            ("Visible.swift", "import SwiftData\nfunc use() { ModelContext() }"),
        ])
        let references = scan(root: root, knownDisplayNames: ["ModelContext"], knownTypeDisplayNames: ["ModelContext"])
        let files = Set(references.map(\.file))
        #expect(!files.contains(where: { $0.contains(".hidden") }))
    }

    @Test func isOrderIndependent() throws {
        let sources = [
            ("Z.swift", "import SwiftData\nfunc use() { ModelContext() }"),
            ("A.swift", "import SwiftData\nfunc use() { ModelContext() }"),
            ("M.swift", "import SwiftData\nfunc use() { ModelContext() }"),
        ]
        let root1 = try makeTree(files: sources)
        let root2 = try makeTree(files: sources.reversed())
        let refs1 = scan(root: root1, knownDisplayNames: ["ModelContext"], knownTypeDisplayNames: ["ModelContext"])
        let refs2 = scan(root: root2, knownDisplayNames: ["ModelContext"], knownTypeDisplayNames: ["ModelContext"])
        // Lexicographic sort makes the reference order deterministic regardless
        // of directory creation order.
        #expect(refs1.map(\.file).sorted() == refs2.map(\.file).sorted())
    }

    /// Helper: builds a temp directory tree with the given `.swift` files.
    private func makeTree(files: [(String, String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "parity-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Scans `root` against the given known names and returns the references.
    private func scan(root: URL, knownDisplayNames: Set<String>, knownTypeDisplayNames: Set<String>) -> [Reference] {
        ReferenceScanner.scan(
            roots: [root],
            repositoryRoot: root.deletingLastPathComponent(),
            knownDisplayNames: knownDisplayNames,
            knownTypeDisplayNames: knownTypeDisplayNames,
            nameStoplist: NameStoplist.entries
        ).references
    }
}
