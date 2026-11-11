import Foundation
import Testing
import ParityApiCoverageRuntime
import SwiftParser
import SwiftSyntax

@Suite struct HashIntoDropTests {
    private func extract(_ source: String) throws -> ExtractedSurface {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hash-drop-\(UUID().uuidString).swiftinterface")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try APISurfaceExtractor.extract(interfaceFile: url)
    }

    @Test func dropsSynthesizedMemberHashIntoOnHashableStruct() throws {
        // Uses the real .swiftinterface form: `Swift::Hasher` (module-qualified
        // with `::`) and `Swift.Hashable`.
        let source = """
        public struct Foo : Swift.Hashable {
            public func hash(into hasher: inout Swift::Hasher) { }
        }
        """
        let surface = try extract(source)
        let hashSymbols = surface.symbols.filter { $0.displayName == "hash" }
        #expect(hashSymbols.isEmpty)
    }

    @Test func doesNotDropTopLevelHashInto() throws {
        let source = """
        public func hash(into hasher: inout Swift::Hasher) { }
        """
        let surface = try extract(source)
        let hashSymbols = surface.symbols.filter { $0.displayName == "hash" }
        #expect(hashSymbols.count == 1)
        #expect(hashSymbols.first?.kind == .function)
    }

    @Test func doesNotDropHashIntoWithNonHasherParam() throws {
        // `secondName` is `other`, not `hasher` → not the synthesized form.
        let source = """
        public struct Bar {
            public func hash(into other: inout Swift::Int) { }
        }
        """
        let surface = try extract(source)
        let hashSymbols = surface.symbols.filter { $0.displayName == "hash" }
        #expect(hashSymbols.count == 1)
    }

    @Test func doesNotDropHashIntoWithTwoParameters() throws {
        let source = """
        public struct Baz {
            public func hash(into hasher: inout Swift::Hasher, extra: Swift.Int) { }
        }
        """
        let surface = try extract(source)
        let hashSymbols = surface.symbols.filter { $0.displayName == "hash" }
        #expect(hashSymbols.count == 1)
    }

    @Test func dropsBothOverloadsWhenTwoCodingKeysTypesDeclareHashInto() throws {
        let source = """
        public struct Outer1 {
            public enum CodingKeys : Swift.Hashable {
                public func hash(into hasher: inout Swift::Hasher) { }
            }
        }
        public struct Outer2 {
            public enum CodingKeys : Swift.Hashable {
                public func hash(into hasher: inout Swift::Hasher) { }
            }
        }
        """
        let surface = try extract(source)
        let hashSymbols = surface.symbols.filter { $0.displayName == "hash" }
        #expect(hashSymbols.isEmpty)
    }
}
