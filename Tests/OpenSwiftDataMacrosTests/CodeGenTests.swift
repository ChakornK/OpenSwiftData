@testable import OpenSwiftDataMacros
import SwiftParser
import SwiftSyntax
import XCTest

final class CodeGenTests: XCTestCase {
    func testTripMemberSourcesMatchVariantAExactly() throws {
        let declaration = try parseClass(
            """
            final class Trip {
                var name: String
                var days: Int = 1
                var notes: String?
                @Relationship(deleteRule: .cascade, inverse: \\Stop.trip) var stops: [Stop] = []
            }
            """)
        XCTAssertEqual(
            CodeGen.memberSources(declaration),
            [
                "@Transient\nprivate var _$backingData: any BackingData<Trip> = Trip.createBackingData()",
                "public var persistentBackingData: any BackingData<Trip> {\n    get { _$backingData }\n    set { _$backingData = newValue }\n}",
                "public static func schemaMetadata() -> [Schema.PropertyMetadata] {\n    return [\n        Schema.PropertyMetadata(name: \"name\", keypath: \\Trip.name, defaultValue: nil, metadata: nil),\n        Schema.PropertyMetadata(name: \"days\", keypath: \\Trip.days, defaultValue: 1, metadata: nil),\n        Schema.PropertyMetadata(name: \"notes\", keypath: \\Trip.notes, defaultValue: nil, metadata: nil),\n        Schema.PropertyMetadata(name: \"stops\", keypath: \\Trip.stops, defaultValue: [], metadata: Schema.Relationship(deleteRule: .cascade, inverse: \\Stop.trip))\n    ]\n}",
                "public init(backingData: any BackingData<Trip>) {\n    _$backingData = backingData\n}",
                "@Transient\nprivate let _$observationRegistrar = Observation.ObservationRegistrar()",
                "internal nonisolated func access<_M>(keyPath: KeyPath<Trip, _M>) {\n    _$observationRegistrar.access(self, keyPath: keyPath)\n}",
                "internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<Trip, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {\n    try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)\n}",
                "struct _SwiftDataNoType {}",
            ])
    }

    func testMetadataUsesAttributeAndRelationshipSourceArguments() throws {
        let declaration = try parseClass(
            """
            final class Person {
                @Attribute(.unique) var email: String
                @Attribute(.transformable(by: \"Codec\")) var encoded: Data = Data()
                @Relationship(deleteRule: .deny, minimumModelCount: 1, inverse: \\Team.people) var team: Team?
            }
            """)
        XCTAssertEqual(
            CodeGen.memberSources(declaration)[2],
            """
            public static func schemaMetadata() -> [Schema.PropertyMetadata] {
                return [
                    Schema.PropertyMetadata(name: \"email\", keypath: \\Person.email, defaultValue: nil, metadata: Schema.Attribute(.unique)),
                    Schema.PropertyMetadata(name: \"encoded\", keypath: \\Person.encoded, defaultValue: Data(), metadata: Schema.Attribute(.transformable(by: \"Codec\"))),
                    Schema.PropertyMetadata(name: \"team\", keypath: \\Person.team, defaultValue: nil, metadata: Schema.Relationship(deleteRule: .deny, minimumModelCount: 1, inverse: \\Team.people))
                ]
            }
            """)
    }

    func testTuplePatternsAreIgnoredWithoutGeneratingInvalidNames() throws {
        let declaration = try parseClass(
            """
            final class Pair {
                var (left, right): (Int, Int) = (1, 2)
                var value: Int
            }
            """)
        let properties = CodeGen.persistedProperties(in: declaration)
        XCTAssertEqual(properties.map(\.name), ["value"])
        let generated = CodeGen.memberSources(declaration).joined(separator: "\n")
        XCTAssertFalse(generated.contains("Pair.(left, right)"))
        XCTAssertFalse(generated.contains("_(left, right)"))
        XCTAssertFalse(generated.contains("forKey: \\.(left, right)"))
    }

    func testPropertyMetadataPrecedenceIgnoresImplementationAndGenericAttributes() throws {
        let declaration = try parseClass(
            """
            final class Metadata {
                @available(*, deprecated) @Attribute(.unique) @Relationship(deleteRule: .cascade) @available(*, deprecated)
                var value: String
            }
            """)
        XCTAssertEqual(
            CodeGen.memberSources(declaration)[2],
            """
            public static func schemaMetadata() -> [Schema.PropertyMetadata] {
                return [
                    Schema.PropertyMetadata(name: "value", keypath: \\Metadata.value, defaultValue: nil, metadata: Schema.Relationship(deleteRule: .cascade))
                ]
            }
            """)
    }

    func testPersistedPropertyMarkerIsNotSchemaMetadataAndVariantADefaultRemains() throws {
        let declaration = try parseClass(
            """
            final class Marked {
                @_PersistedProperty var value: Int
            }
            """)
        XCTAssertEqual(CodeGen.persistedProperties(in: declaration).map(\.metadata), [nil])
        XCTAssertEqual(CodeGen.memberSources(declaration), CodeGen.memberSources(declaration, variant: .a))
        XCTAssertFalse(CodeGen.memberSources(declaration)[3].contains("_value ="))
    }

    func testMemberSourcesReturnEmptyMetadataAndSkipExcludedProperties() throws {
        let declaration = try parseClass(
            """
            final class Empty {
                @Transient var cache: String = \"cache\"
                static var global: Int = 0
                lazy var deferred: Int = 1
                var computed: Int { 2 }
            }
            """)
        XCTAssertEqual(
            CodeGen.memberSources(declaration)[2],
            """
            public static func schemaMetadata() -> [Schema.PropertyMetadata] {
                return []
            }
            """)
        XCTAssertTrue(CodeGen.persistedProperties(in: declaration).isEmpty)
    }

    func testInitializationVariantBInitializesPeerStorageInDeclarationOrder() throws {
        let declaration = try parseClass(
            """
            final class Trip {
                var name: String
                var days: Int = 1
            }
            """)
        XCTAssertEqual(
            CodeGen.memberSources(declaration, variant: .b)[3],
            """
            public init(backingData: any BackingData<Trip>) {
                _$backingData = backingData
                _name = _SwiftDataNoType()
                _days = _SwiftDataNoType()
            }
            """)
    }

    func testAccessorAndPeerSourcesMatchVariantAExactly() {
        XCTAssertEqual(
            CodeGen.accessorSources(property: "name"),
            [
                "@storageRestrictions(accesses: _$backingData, initializes: _name)\ninit(initialValue) {\n    _$backingData.setValue(forKey: \\.name, to: initialValue)\n    _name = _SwiftDataNoType()\n}",
                "get {\n    access(keyPath: \\.name)\n    return self.getValue(forKey: \\.name)\n}",
                "set {\n    withMutation(keyPath: \\.name) {\n        self.setValue(forKey: \\.name, to: newValue)\n    }\n}",
            ])
        XCTAssertEqual(CodeGen.peerSources(property: "name"), ["@Transient\nprivate var _name: _SwiftDataNoType"])
    }

    func testInitializationVariantCHasNoInitializationRestrictionOrAssignment() {
        XCTAssertEqual(
            CodeGen.accessorSources(property: "name", variant: .c)[0],
            """
            @storageRestrictions(accesses: _$backingData)
            init(initialValue) {
                _$backingData.setValue(forKey: \\.name, to: initialValue)
            }
            """)
        XCTAssertEqual(
            CodeGen.peerSources(property: "name", variant: .c),
            ["@Transient\nprivate var _name: _SwiftDataNoType = _SwiftDataNoType()"])
    }

    func testExtensionSourcesMatchExactConformances() throws {
        let declaration = try parseClass("final class Trip {}")
        XCTAssertEqual(
            CodeGen.extensionSources(declaration),
            [
                "extension Trip: PersistentModel {}",
                "extension Trip: Observation.Observable {}",
                "extension Trip: @unchecked Sendable {}",
            ])
    }

    private func parseClass(_ source: String) throws -> ClassDeclSyntax {
        let file = Parser.parse(source: source)
        guard let declaration = file.statements.first?.item.as(ClassDeclSyntax.self) else {
            throw ParseFailure.expectedClass
        }
        return declaration
    }

    private enum ParseFailure: Error {
        case expectedClass
    }
}
