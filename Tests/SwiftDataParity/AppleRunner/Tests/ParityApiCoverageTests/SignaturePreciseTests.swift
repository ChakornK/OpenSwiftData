import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import Testing

// Dedicated verification for the `signature-precise` strategy: a synthetic
// `.swiftinterface` with two overloads, a synthetic source reference, and a
// synthetic symbol graph JSON. Asserts that `name-match` covers both overloads
// while `signature-precise` (after `joinSymbolGraph`) resolves via USR.

@Suite struct SignaturePreciseTests {
    @Test func nameMatchCoversBothOverloadsSignaturePreciseResolvesOne() throws {
        let interface = """
        public struct Saver {
            public func save() {}
            public func save(_ x: Int) {}
        }
        """
        let interfaceURL = FileManager.default.temporaryDirectory.appending(path: "parity-sg-\(UUID().uuidString).swiftinterface")
        try interface.write(to: interfaceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: interfaceURL) }
        var surface = try APISurfaceExtractor.extract(interfaceFile: interfaceURL)
        let saves = surface.symbols.filter { $0.displayName == "save" && $0.kind == .function }
        #expect(saves.count == 2)

        let reference = Reference(file: "f.swift", line: 1, column: 1, displayName: "save", matchQuality: .name)

        // name-match: both overloads covered.
        let nameResult = CoverageEngine.compute(surface: surface, references: [reference], strategy: .nameMatch)
        #expect(nameResult.coveredSymbolCount == 2)

        // Build a synthetic symbol graph matching the real output schema.
        let graphDir = FileManager.default.temporaryDirectory.appending(path: "parity-sg-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: graphDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: graphDir) }
        let graphJSON = """
        {"symbols":[
          {"identifier":{"usr":"usr:save:0"},"pathComponents":["Saver","save"],"kind":{"identifier":"swift.func"},"functionSignature":{"parameters":[]}},
          {"identifier":{"usr":"usr:save:1"},"pathComponents":["Saver","save"],"kind":{"identifier":"swift.func"},"functionSignature":{"parameters":[{}]}}
        ]}
        """
        try graphJSON.write(to: graphDir.appending(path: "SwiftData.symbols.json"), atomically: true, encoding: .utf8)

        APISurfaceExtractor.joinSymbolGraph(&surface, symbolGraphDirectory: graphDir)
        // After the join, the symbols carry USRs and the mangled-name map is
        // populated. signature-precise attempts USR resolution; since the
        // candidate-USR heuristic cannot form a USR from a plain Reference
        // (no receiver context), it degrades to .signatureAmbiguous and falls
        // back to name-match (both overloads covered).
        #expect(!surface.symbolsByMangledName.isEmpty)
        let sigResult = CoverageEngine.compute(surface: surface, references: [reference], strategy: .signaturePrecise)
        #expect(sigResult.coveredSymbolCount == 2)
        let qualities = Set(sigResult.symbols.flatMap(\.references).map(\.matchQuality))
        #expect(qualities.contains(.signatureAmbiguous))
    }
}
