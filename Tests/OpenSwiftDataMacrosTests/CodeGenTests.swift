@testable import OpenSwiftDataMacros
import SwiftParser
import SwiftSyntax
import XCTest

final class CodeGenTests: XCTestCase {
    func testModelActorMemberSourcesMatchExecutorContract() {
        XCTAssertEqual(
            CodeGen.modelActorMemberSources(actorName: "StoreActor"),
            [
                "nonisolated let modelExecutor: DefaultSerialModelExecutor",
                "nonisolated let modelContainer: ModelContainer",
                "init(modelContainer: ModelContainer) {\n"
                    + "    self.modelContainer = modelContainer\n"
                    + "    self.modelExecutor = DefaultSerialModelExecutor.make(container: modelContainer)\n"
                    + "}",
            ])
        XCTAssertEqual(
            CodeGen.modelActorExtensionSource(actorName: "StoreActor"), "extension StoreActor: ModelActor {}")
    }

    func testUniqueAndIndexDirectiveSourcesPreserveColumnOrder() throws {
        let unique = try parseDirective("#Unique(\\Model.second, \\Model.first)")
        let index = try parseDirective("#Index(\\Model.first, \\Model.second)")

        XCTAssertEqual(
            try CodeGen.schemaDirectiveSources(unique, kind: .unique, uniqueName: "uniqueConstraint"),
            ["let uniqueConstraint = Schema.Index(properties: [\"second\", \"first\"], isUnique: true)"])
        XCTAssertEqual(
            try CodeGen.schemaDirectiveSources(index, kind: .index, uniqueName: "ordinaryIndex"),
            ["let ordinaryIndex = Schema.Index(properties: [\"first\", \"second\"], isUnique: false)"])
    }

    func testSchemaDirectiveSourcesRejectNestedAndRepeatedKeyPaths() throws {
        let nested = try parseDirective("#Unique(\\Model.child.value)")
        XCTAssertThrowsError(try CodeGen.schemaDirectiveSources(nested, kind: .unique, uniqueName: "unique"))

        let repeated = try parseDirective("#Index(\\Model.value, \\Model.value)")
        XCTAssertThrowsError(try CodeGen.schemaDirectiveSources(repeated, kind: .index, uniqueName: "index"))
    }

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
            CodeGen.memberSources(declaration).filter { !$0.contains("inferredRelationshipAdapterCandidates()") },
            [
                "@Transient\nprivate var _$backingData: any BackingData<Trip> = Trip.createBackingData()",
                "public var persistentBackingData: any BackingData<Trip> {\n    get { _$backingData }\n    set { _$backingData = newValue }\n}",
                "public static func schemaMetadata() -> [Schema.PropertyMetadata] {\n    return [\n        Schema.PropertyMetadata(name: \"name\", keypath: \\Trip.name, defaultValue: nil, metadata: nil, isExplicitRelationship: false),\n        Schema.PropertyMetadata(name: \"days\", keypath: \\Trip.days, defaultValue: 1, metadata: nil, isExplicitRelationship: false),\n        Schema.PropertyMetadata(name: \"notes\", keypath: \\Trip.notes, defaultValue: nil, metadata: nil, isExplicitRelationship: false),\n        Schema.PropertyMetadata(name: \"stops\", keypath: \\Trip.stops, defaultValue: [], metadata: Schema.Relationship(deleteRule: .cascade, inverseName: \"trip\"), isExplicitRelationship: true)\n    ]\n}",
                "public static func persistenceAdapters() -> [any PersistencePropertyAdapter<Trip>] {\n    [\n        TypedPropertyAdapter<Trip, String>(\"name\", keyPath: \\Trip.name, encode: { model in try PersistentValue.encode(model.name) }, decode: { value, model in model.name = try PersistentValue.decode(String.self, from: value) }, decodeValue: { value in (try PersistentValue.decode(String.self, from: value)) as Any }),\n        TypedPropertyAdapter<Trip, Int>(\"days\", keyPath: \\Trip.days, encode: { model in try PersistentValue.encode(model.days) }, decode: { value, model in model.days = try PersistentValue.decode(Int.self, from: value) }, decodeValue: { value in (try PersistentValue.decode(Int.self, from: value)) as Any }),\n        TypedPropertyAdapter<Trip, String?>(\"notes\", keyPath: \\Trip.notes, encode: { model in try PersistentValue.encode(model.notes) }, decode: { value, model in model.notes = try PersistentValue.decode(String?.self, from: value) }, decodeValue: { value in (try PersistentValue.decode(String?.self, from: value)) as Any })\n    ]\n}",
                "public static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    [\n        RelationshipAdapterBox<Trip>(TypedRelationshipPropertyAdapter<Trip, [Stop], Stop>(\"stops\", keyPath: \\Trip.stops, metadata: Schema.Relationship(deleteRule: .cascade, inverseName: \"trip\"), read: { model in model.stops }, endpoints: { value in value }, build: { endpoints in [Stop](endpoints) }, inverseBuild: { endpoints in endpoints }, isToMany: true, explicitInverseKeyPath: \\Stop.trip))\n    ]\n}",
                "public init(backingData: any BackingData<Trip>) {\n    _$backingData = backingData\n}",
                "@Transient\nprivate let _$observationRegistrar = Observation.ObservationRegistrar()",
                "internal nonisolated func access<_M>(keyPath: KeyPath<Trip, _M>) {\n    _$observationRegistrar.access(self, keyPath: keyPath)\n}",
                "internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<Trip, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {\n    try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)\n}",
                "struct _SwiftDataNoType {}",
            ])
    }

    func testRelationshipCandidateMethodIsOmittedWhenThereAreNoExplicitRelationships() throws {
        let declaration = try parseClass(
            """
            final class Person {
                var name: String
            }
            """)

        XCTAssertFalse(
            CodeGen.memberSources(declaration).contains { $0.contains("relationshipAdapterCandidates() ->") })
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
        let metadata = CodeGen.persistedProperties(in: declaration).map(\.metadata)
        XCTAssertEqual(
            metadata,
            [
                "Schema.Attribute(.unique)",
                "Schema.Attribute(.transformable(by: \"Codec\"))",
                "Schema.Relationship(deleteRule: .deny, minimumModelCount: 1, inverseName: \"people\")",
            ])
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
                "Schema.Relationship(inverseName: \"someProperty\")",
                "Schema.Relationship(inverseName: \"`class`\")",
            ])
    }

    func testExplicitInverseKeyPathIgnoresCommasInOtherArguments() throws {
        let declaration = try parseClass(
            """
            final class Trip {
                @Relationship(originalName: "a,b", inverse: \\Stop.trip) var stops: [Stop] = []
            }
            """)
        XCTAssertEqual(
            CodeGen.memberSources(declaration).first { $0.contains("relationshipAdapterCandidates()") },
            "public static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    [\n        RelationshipAdapterBox<Trip>(TypedRelationshipPropertyAdapter<Trip, [Stop], Stop>(\"stops\", keyPath: \\Trip.stops, metadata: Schema.Relationship(originalName: \"a,b\", inverseName: \"trip\"), read: { model in model.stops }, endpoints: { value in value }, build: { endpoints in [Stop](endpoints) }, inverseBuild: { endpoints in endpoints }, isToMany: true, explicitInverseKeyPath: \\Stop.trip))\n    ]\n}"
        )
    }

    func testExplicitInverseKeyPathPreservesBacktickEscapedNames() throws {
        let declaration = try parseClass(
            """
            final class Model {
                @Relationship(inverse: \\Dest.`class`) var dest: Dest?
            }
            """)
        XCTAssertEqual(CodeGen.persistedProperties(in: declaration).map(\.inverseKeyPath), ["\\Dest.`class`"])
        XCTAssertEqual(
            CodeGen.memberSources(declaration).first { $0.contains("relationshipAdapterCandidates()") },
            "public static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    [\n        RelationshipAdapterBox<Model>(TypedRelationshipPropertyAdapter<Model, Dest?, Dest>(\"dest\", keyPath: \\Model.dest, metadata: Schema.Relationship(inverseName: \"`class`\"), read: { model in model.dest }, endpoints: { value in value.map { [$0] } ?? [] }, build: { endpoints in endpoints.first }, inverseBuild: { endpoints in endpoints.first }, isToMany: false, explicitInverseKeyPath: \\Dest.`class`))\n    ]\n}"
        )
    }

    func testInversePropertyNameEscapesGeneratedStringLiteral() throws {
        let declaration = try parseClass(
            #"""
            final class Model {
                @Relationship(inverse: \.Dest.`quote"slash\\name`) var dest: Dest?
            }
            """#)
        let generated = try XCTUnwrap(
            CodeGen.memberSources(declaration).first { $0.contains("relationshipAdapterCandidates()") })

        XCTAssertTrue(
            generated.contains(#"inverseName: "`quote\"slash\\\\name`""#),
            generated
        )
    }

    func testNilInverseEmitsNoExplicitInverseKeyPath() throws {
        let declaration = try parseClass(
            """
            final class Model {
                @Relationship(inverse: nil) var dest: Dest?
            }
            """)
        XCTAssertEqual(CodeGen.persistedProperties(in: declaration).map(\.inverseKeyPath), [nil])
        XCTAssertEqual(
            CodeGen.memberSources(declaration).first { $0.contains("relationshipAdapterCandidates()") },
            "public static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {\n    [\n        RelationshipAdapterBox<Model>(TypedRelationshipPropertyAdapter<Model, Dest?, Dest>(\"dest\", keyPath: \\Model.dest, metadata: Schema.Relationship(inverse: nil), read: { model in model.dest }, endpoints: { value in value.map { [$0] } ?? [] }, build: { endpoints in endpoints.first }, inverseBuild: { endpoints in endpoints.first }, isToMany: false))\n    ]\n}"
        )
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
                    Schema.PropertyMetadata(name: "value", keypath: \\Metadata.value, defaultValue: nil, metadata: Schema.Relationship(deleteRule: .cascade), isExplicitRelationship: true)
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
            CodeGen.memberSources(declaration, variant: .b).first { $0.contains("public init(backingData:") } ?? "",
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

    func testRelationshipAdaptersGenerateOnlyExplicitBareArraysAndSets() throws {
        let declaration = try parseClass(
            """
            final class Household {
                @Relationship var pets: [Pet]
                @Relationship var favorites: Set<Pet> = []
                var inferredPets = [Pet]()
                var strings = [String]()
                var stringSet = Set<String>()
            }
            """)

        let generated =
            CodeGen.memberSources(declaration).first(where: {
                $0.contains("relationshipAdapterCandidates()")
            }) ?? ""
        XCTAssertTrue(
            generated.contains(
                "RelationshipAdapterBox<Household>(TypedRelationshipPropertyAdapter<Household, [Pet], Pet>"))
        XCTAssertTrue(
            generated.contains(
                "RelationshipAdapterBox<Household>(TypedRelationshipPropertyAdapter<Household, Set<Pet>, Pet>"))
        let inferred =
            CodeGen.memberSources(declaration).first(where: {
                $0.contains("inferredRelationshipAdapterCandidates() ->")
            }) ?? ""
        XCTAssertTrue(inferred.isEmpty)
        XCTAssertFalse(
            CodeGen.memberSources(declaration).contains {
                $0.contains("inferredRelationshipAdapterCandidates() ->")
            })
        XCTAssertTrue(generated.contains("pets"))
        XCTAssertTrue(generated.contains("favorites"))
        XCTAssertFalse(generated.contains("inferredPets"))
        XCTAssertFalse(generated.contains("strings"))
        XCTAssertFalse(generated.contains("stringSet"))
        XCTAssertFalse(inferred.contains("strings"))
        XCTAssertFalse(inferred.contains("stringSet"))
        XCTAssertNil(CodeGen.persistedProperties(in: declaration).first { $0.name == "pets" }?.metadata)
    }

    func testUnsupportedScalarRelationshipHasNoGeneratedAdapterCandidate() throws {
        let declaration = try parseClass(
            """
            final class Parcel {
                @Relationship var code: String
            }
            """)
        let generated =
            CodeGen.memberSources(declaration).first {
                $0.contains("relationshipAdapterCandidates()")
            } ?? ""
        XCTAssertFalse(generated.contains("code"))
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

    func testRelationshipAccessorSourceUsesGraphSetter() {
        XCTAssertTrue(
            CodeGen.accessorSources(property: "pets", isRelationship: true)[2].contains("setRelationshipValue"))
        XCTAssertTrue(CodeGen.accessorSources(property: "title", isRelationship: false)[2].contains("self.setValue"))
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
                "extension Trip: RelationshipModel {}",
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

    private func parseDirective(_ source: String) throws -> MacroExpansionExprSyntax {
        let file = Parser.parse(source: source)
        return try XCTUnwrap(file.statements.first?.item.as(ExprSyntax.self)?.as(MacroExpansionExprSyntax.self))
    }
}
