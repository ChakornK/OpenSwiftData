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
                "public static func persistenceAdapters() -> [any PersistencePropertyAdapter<Trip>] {\n    [\n        TypedPropertyAdapter<Trip, String>(\"name\", keyPath: \\Trip.name, encode: { model in try PersistentValue.encode(model.name) }, decode: { value, model in model.name = try PersistentValue.decode(String.self, from: value) }, decodeValue: { value in (try PersistentValue.decode(String.self, from: value)) as Any }),\n        TypedPropertyAdapter<Trip, Int>(\"days\", keyPath: \\Trip.days, encode: { model in try PersistentValue.encode(model.days) }, decode: { value, model in model.days = try PersistentValue.decode(Int.self, from: value) }, decodeValue: { value in (try PersistentValue.decode(Int.self, from: value)) as Any }),\n        TypedPropertyAdapter<Trip, String?>(\"notes\", keyPath: \\Trip.notes, encode: { model in try PersistentValue.encode(model.notes) }, decode: { value, model in model.notes = try PersistentValue.decode(String?.self, from: value) }, decodeValue: { value in (try PersistentValue.decode(String?.self, from: value)) as Any })\n    ]\n}",
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

    func testInverseKeyPathIsPreservedWithoutSynthesizedName() throws {
        let declaration = try parseClass(
            """
            final class Model {
                @Relationship(inverse: \\.Destination.someProperty) var destination: Destination?
                @Relationship(inverse: \\.Destination.`class`) var escaped: Destination?
            }
            """)

        XCTAssertEqual(
            CodeGen.persistedProperties(in: declaration).map(\.metadata),
            [
                "Schema.Relationship(inverse: \\.Destination.someProperty)",
                "Schema.Relationship(inverse: \\.Destination.`class`)",
            ])
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
            CodeGen.memberSources(declaration, variant: .b)[4],
            """
            public init(backingData: any BackingData<Trip>) {
                _$backingData = backingData
                _name = _SwiftDataNoType()
                _days = _SwiftDataNoType()
            }
            """)
    }

    func testTypedAdaptersAreGeneratedForPersistedAttributes() throws {
        let declaration = try parseClass("final class Model { var count: Int = 0 }")
        let adapters = try XCTUnwrap(CodeGen.memberSources(declaration).first { $0.contains("persistenceAdapters()") })
        XCTAssertTrue(adapters.contains("TypedPropertyAdapter<Model, Int>"))
        XCTAssertTrue(adapters.contains("PersistentValue.encode(model.count)"))
    }

    func testExplicitAttributeCustomTypesGetAdaptersAndRelationshipsDoNot() throws {
        let declaration = try parseClass(
            """
            final class Garage {
                var owner: Person?
                var cars: [Car] = []
                var payload: Payload
                @Attribute var storedPayload: Payload
            }
            """)

        let adapters =
            CodeGen.memberSources(declaration).first {
                $0.contains("persistenceAdapters()")
            } ?? ""
        XCTAssertFalse(adapters.contains("TypedPropertyAdapter<Garage, Person?>(\"owner\""))
        XCTAssertFalse(adapters.contains("TypedPropertyAdapter<Garage, [Car]>(\"cars\""))
        XCTAssertTrue(adapters.contains("storedPayload"))
        XCTAssertTrue(adapters.contains("PersistentValue.decode(Payload.self, from: value)"))
    }

    func testRelationshipAdaptersUseMetadataAndActualModelTypes() throws {
        let declaration = try parseClass(
            """
            final class Parcel {
                var unrelatedString: String
                var destination: Destination?
                @Relationship var explicitlyMarked: String?
                @Relationship() var explicitlyMarkedWithEmptyArguments: String?
                @Attribute(.transformable(by: "Codec")) var payload: Payload
            }
            """)

        let generatedAdapters = try XCTUnwrap(
            CodeGen.memberSources(declaration).first {
                $0.contains("persistenceAdapters()")
            })
        XCTAssertTrue(generatedAdapters.contains("unrelatedString"))
        XCTAssertFalse(generatedAdapters.contains("destination"))
        XCTAssertFalse(generatedAdapters.contains("explicitlyMarked"))
        XCTAssertFalse(generatedAdapters.contains("explicitlyMarkedWithEmptyArguments"))
        XCTAssertTrue(generatedAdapters.contains("payload"))
    }

    func testArbitrarySupportedScalarTypeIsNotMisclassifiedByItsName() throws {
        let declaration = try parseClass(
            """
            final class TripMeter {
                var destinationCode: String
                var stopCount: Int
            }
            """)

        let adapters = try XCTUnwrap(
            CodeGen.memberSources(declaration).first {
                $0.contains("persistenceAdapters()")
            })
        XCTAssertTrue(adapters.contains("PersistentValue.encode(model.destinationCode)"))
        XCTAssertTrue(adapters.contains("PersistentValue.encode(model.stopCount)"))
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
