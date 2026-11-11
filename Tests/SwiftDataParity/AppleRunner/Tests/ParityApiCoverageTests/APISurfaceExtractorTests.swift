import Foundation
import ParityApiCoverageRuntime
import ParityContracts
import SwiftSyntax
import Testing

// Unit tests for `APISurfaceExtractor`. Each test writes a synthetic
// `.swiftinterface` string to a temp file, extracts the surface, and asserts
// on the emitted `API_Symbol`s. No real macOS SDK is required.

@Suite struct APISurfaceExtractorTests {
    @Test func emitsOneSymbolPerPublicDeclaration() throws {
        let interface = """
        public struct Foo {
            public var x: Int
            public func bar() {}
            public init() {}
        }
        internal struct Hidden {
            public func baz() {}
        }
        """
        let surface = try extract(interface)
        let displayNames = Set(surface.symbols.map(\.displayName))
        #expect(displayNames.contains("Foo"))
        #expect(displayNames.contains("x"))
        #expect(displayNames.contains("bar"))
        #expect(displayNames.contains("init"))
        #expect(!displayNames.contains("Hidden"))
        #expect(!displayNames.contains("baz"))
        #expect(surface.excludedCount == 0)
    }

    @Test func attributesExtensionMembersToExtendedTypeNotProtocol() throws {
        let interface = """
        public struct ModelConfiguration {}
        extension ModelConfiguration : Swift::CustomDebugStringConvertible {
            public var debugDescription: String { "" }
        }
        """
        let surface = try extract(interface)
        let debugDesc = surface.symbols.first { $0.displayName == "debugDescription" }
        #expect(debugDesc != nil)
        #expect(debugDesc?.fullyQualifiedName == "SwiftData.ModelConfiguration.debugDescription")
        #expect(debugDesc?.kind == .variable)
    }

    @Test func stripsModuleQualifiersFromFullyQualifiedNamePreservesThemInSourceSignature() throws {
        let interface = """
        public struct Container {
            public var url: Foundation::URL
        }
        """
        let surface = try extract(interface)
        let url = surface.symbols.first { $0.displayName == "url" }
        #expect(url?.fullyQualifiedName == "SwiftData.Container.url")
        #expect(url?.sourceSignature.contains("Foundation::URL") == true)
    }

    @Test func normalizesShorthandAvailableToMajorDotZero() throws {
        let interface = """
        @available(macOS 14, iOS 17, *)
        public struct AvailableStruct {
            public var v: Int
        }
        """
        let surface = try extract(interface)
        let symbol = surface.symbols.first { $0.displayName == "AvailableStruct" }
        #expect(symbol?.platformAvailability.macOS == "14.0")
        #expect(symbol?.platformAvailability.iOS == "17.0")
    }

    @Test func handlesLonghandIntroducedDeprecated() throws {
        let interface = """
        @available(macOS, introduced: 14.0, deprecated: 100000.0)
        public struct DeprecatedStruct {
            public var v: Int
        }
        """
        let surface = try extract(interface)
        let symbol = surface.symbols.first { $0.displayName == "DeprecatedStruct" }
        #expect(symbol?.platformAvailability.macOS == "14.0")
        #expect(symbol?.platformAvailability.deprecated == true)
    }

    @Test func ignoresSwiftVersionAvailability() throws {
        let interface = """
        @available(swift 5.9)
        public struct SwiftVersionStruct {
            public var v: Int
        }
        """
        let surface = try extract(interface)
        let symbol = surface.symbols.first { $0.displayName == "SwiftVersionStruct" }
        #expect(symbol?.platformAvailability.macOS == nil)
        #expect(symbol?.platformAvailability.unavailable == false)
    }

    @Test func dropsExcludedSymbolsAndCountsThem() throws {
        let interface = """
        @available(*, unavailable)
        public struct UnavailableStruct {
            public var v: Int
        }
        public struct AvailableStruct {
            public var v: Int
        }
        """
        let surface = try extract(interface)
        let names = Set(surface.symbols.map(\.displayName))
        #expect(!names.contains("UnavailableStruct"))
        #expect(names.contains("AvailableStruct"))
        #expect(surface.excludedCount >= 1)
    }

    @Test func doesNotExcludeTypeWhoseConformanceExtensionIsUnavailable() throws {
        let interface = """
        public struct Bar {}
        @available(*, unavailable)
        extension Bar : Swift::Sendable {
            public var x: Int { 0 }
        }
        """
        let surface = try extract(interface)
        let bar = surface.symbols.first { $0.displayName == "Bar" && $0.kind == .structKind }
        #expect(bar != nil)
        // The member `x` inside the unavailable conformance extension is excluded.
        let x = surface.symbols.first { $0.displayName == "x" }
        #expect(x == nil)
        #expect(surface.excludedCount >= 1)
    }

    @Test func marksDeprecatedSymbols() throws {
        let interface = """
        @available(macOS, introduced: 14.0, deprecated: 100000.0, message: "use something else")
        public struct Dep {
            public var v: Int
        }
        """
        let surface = try extract(interface)
        let dep = surface.symbols.first { $0.displayName == "Dep" }
        #expect(dep?.platformAvailability.deprecated == true)
        let v = surface.symbols.first { $0.displayName == "v" }
        #expect(v?.platformAvailability.deprecated == true)
    }

    @Test func emitsDistinctSymbolsForOverloads() throws {
        let interface = """
        public struct Overloader {
            public func save() {}
            public func save(_ context: Int) {}
        }
        """
        let surface = try extract(interface)
        let saves = surface.symbols.filter { $0.displayName == "save" && $0.kind == .function }
        #expect(saves.count == 2)
        let arities = Set(saves.map(\.arity))
        #expect(arities == [0, 1])
        let signatures = Set(saves.map(\.sourceSignature))
        #expect(signatures.count == 2)
    }

    /// Helper: writes the interface to a temp file and extracts the surface.
    private func extract(_ source: String) throws -> ExtractedSurface {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "parity-extract-\(UUID().uuidString).swiftinterface")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try APISurfaceExtractor.extract(interfaceFile: url)
    }
}
