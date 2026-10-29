import XCTest
@testable import OpenSwiftData
import OpenSwiftDataSQLite

@Model
final class PersistenceTestModel {
    var title: String
    var count: Int = 0
    init(title: String) { self.title = title }
}

@Model
final class PredicateDoubleFixture {
    var score: Double
    init(score: Double) { self.score = score }
}

@Model
final class ReverseOrderPersistenceFixture {
    var zebra: String
    var alpha: Int
    var middle: String
    var optionalValue: String?

    init(zebra: String, alpha: Int, middle: String, optionalValue: String?) {
        self.zebra = zebra
        self.alpha = alpha
        self.middle = middle
        self.optionalValue = optionalValue
    }
}

struct CodablePayload: Codable, Equatable {
    let label: String
    let count: Int
}

@Model
final class ExplicitCodableAttributeFixture {
    @Attribute(.transformable(by: "Codec")) var payload: CodablePayload

    init(payload: CodablePayload) { self.payload = payload }
}

@Model
final class ExternalDataFixture {
    var label: String
    @Attribute(.externalStorage) var payload: Data

    init(label: String, payload: Data) {
        self.label = label
        self.payload = payload
    }
}

@Model
final class InvalidExternalDataOptionFixture {
    @Attribute(.externalStorage) var payload: String
    init(payload: String) { self.payload = payload }
}

@Model
final class FailedWritePersistenceFixture {
    @Attribute(.unique) var key: String
    init(key: String) { self.key = key }
}

@Model
final class ConflictingUniqueKeysFixture {
    @Attribute(.unique) var email: String
    @Attribute(.unique) var username: String

    init(email: String, username: String) {
        self.email = email
        self.username = username
    }
}

@Model
final class UpsertRelationshipOwnerFixture {
    @Attribute(.unique) var key: String
    @Relationship(inverse: nil) var destination: UpsertRelationshipDestinationFixture?

    init(key: String) { self.key = key }
}

@Model
final class UpsertRelationshipDestinationFixture {
    var name: String

    init(name: String) { self.name = name }
}

@Model
final class PersistentRelationshipOwner {
    var title: String
    @Relationship(deleteRule: .nullify, inverse: \PersistentRelationshipChild.owner)
    var children: [PersistentRelationshipChild] = []
    @Relationship(inverse: nil) var favorite: PersistentRelationshipChild?

    init(title: String) { self.title = title }
}

@Model
final class PersistentRelationshipChild {
    var title: String
    @Relationship var owner: PersistentRelationshipOwner?

    init(title: String) { self.title = title }
}

@Model
final class PersistentTagGroup {
    var name: String
    @Relationship var tags: [PersistentTag] = []

    init(name: String) { self.name = name }
}

@Model
final class PersistentTag {
    var name: String
    @Relationship(inverse: \PersistentTagGroup.tags) var groups: [PersistentTagGroup] = []

    init(name: String) { self.name = name }
}

struct FlattenedDimensions: Codable, Sendable, FlattenableComposite, Equatable {
    let width: Int
    let label: String

    static var flattenedComponents: [FlattenedComponent<Self>] {
        [
            FlattenedComponent(
                "width", keyPath: \.width,
                set: { value, current in FlattenedDimensions(width: value, label: current.label) }),
            FlattenedComponent(
                "label", keyPath: \.label,
                set: { value, current in FlattenedDimensions(width: current.width, label: value) }),
        ]
    }

    static func emptyFlattenedValue() throws -> Self {
        FlattenedDimensions(width: 0, label: "")
    }

    static var flattenedComponentsForSchema: [(String, String)] {
        [("width", "Int"), ("label", "String")]
    }
}

struct FlattenedPayload: Codable, Sendable, FlattenableComposite, Equatable {
    let bytes: Data

    static var flattenedComponents: [FlattenedComponent<Self>] {
        [
            FlattenedComponent(
                "bytes", keyPath: \.bytes,
                set: { value, _ in FlattenedPayload(bytes: value) })
        ]
    }

    static func emptyFlattenedValue() throws -> Self { FlattenedPayload(bytes: Data()) }
}

struct DuplicateFlattenedComponents: Codable, Sendable, FlattenableComposite {
    let value: Int
    static var flattenedComponents: [FlattenedComponent<Self>] {
        [
            FlattenedComponent(
                "value", keyPath: \.value, set: { value, _ in DuplicateFlattenedComponents(value: value) }),
            FlattenedComponent(
                "value", keyPath: \.value, set: { value, _ in DuplicateFlattenedComponents(value: value) }),
        ]
    }
    static func emptyFlattenedValue() throws -> Self { DuplicateFlattenedComponents(value: 0) }
}

struct NestedFlattenedComposite: Codable, Sendable, FlattenableComposite {
    let inner: CodableBlobFixture
    static var flattenedComponents: [FlattenedComponent<Self>] {
        [
            FlattenedComponent(
                "inner", keyPath: \.inner,
                set: { value, _ in NestedFlattenedComposite(inner: value) })
        ]
    }
    static func emptyFlattenedValue() throws -> Self {
        NestedFlattenedComposite(inner: CodableBlobFixture(value: 0))
    }
}

@Model
final class UnsupportedFlattenedLeafFixture {
    @Attribute(.flattened) var value: NestedFlattenedComposite
    init(value: NestedFlattenedComposite) { self.value = value }
}

@Model
final class DuplicateFlattenedFixture {
    @Attribute(.flattened) var composite: DuplicateFlattenedComponents
    init(composite: DuplicateFlattenedComponents) { self.composite = composite }
}

@Model
final class FlattenedPayloadFixture {
    @Attribute(.flattened) var payload: FlattenedPayload
    init(payload: FlattenedPayload) { self.payload = payload }
}

@Model
final class FlattenedCompositeFixture {
    @Attribute(.flattened) var dimensions: FlattenedDimensions

    init(dimensions: FlattenedDimensions) { self.dimensions = dimensions }
}

struct CodableBlobFixture: Codable, Sendable, Equatable {
    let value: Int
}

@Model
final class CodableBlobFallbackFixture {
    var value: CodableBlobFixture
    init(value: CodableBlobFixture) { self.value = value }
}

@Model
final class OptionalFlattenedCompositeFixture {
    @Attribute(.flattened) var dimensions: FlattenedDimensions?
    init(dimensions: FlattenedDimensions?) { self.dimensions = dimensions }
}

@Model
final class FlattenedCompositeOwnerFixture {
    var name: String
    @Relationship var dimensions: FlattenedCompositeFixture?

    init(name: String, dimensions: FlattenedCompositeFixture? = nil) {
        self.name = name
        self.dimensions = dimensions
    }
}

@Model
final class LazyCascadeOwnerFixture {
    var title: String
    @Relationship(deleteRule: .cascade, inverse: nil) var children: [LazyCascadeChildFixture] = []

    init(title: String) { self.title = title }
}

@Model
final class LazyCascadeChildFixture {
    var title: String
    init(title: String) { self.title = title }
}

final class ContextPersistenceTests: XCTestCase {
    @MainActor
    func testFlattenedCodableCompositePersistsAndSupportsLeafPredicate() throws {
        let container = try ModelContainer(
            for: FlattenedCompositeFixture.self,
            configurations: .sqliteMemory("flattened-codable-composite"))
        let entity = try XCTUnwrap(container.schema.entity(forName: "FlattenedCompositeFixture"))
        let attribute = try XCTUnwrap(entity.attributes.first(where: { $0.name == "dimensions" }))
        XCTAssertTrue(attribute.options.contains(.flattened))
        XCTAssertEqual(attribute.components.map(\.columnName), ["dimensions_label", "dimensions_width"])
        let physicalColumns = try container.store?.read {
            try $0.rows("PRAGMA table_info(ZFLATTENEDCOMPOSITEFIXTURE)", arguments: [])
        }
        XCTAssertEqual(
            physicalColumns?.compactMap { row in
                guard case let .text(name)? = row.dropFirst(1).first else { return nil }
                return name
            }.filter { $0.hasPrefix("ZDIMENSIONS_") },
            ["ZDIMENSIONS_LABEL", "ZDIMENSIONS_WIDTH"])

        let context = container.mainContext
        let fixture = FlattenedCompositeFixture(dimensions: FlattenedDimensions(width: 8, label: "initial"))
        context.insert(fixture)
        do {
            try context.save()
        } catch {
            XCTFail("Initial flattened save failed: \(error)")
            return
        }
        let storedColumns = try container.store?.read {
            try $0.rows(
                "SELECT Z_PK, Z_OPT, ZDIMENSIONS_WIDTH, ZDIMENSIONS_LABEL FROM ZFLATTENEDCOMPOSITEFIXTURE",
                arguments: [])
        }
        XCTAssertEqual(storedColumns, [[.int(1), .int(1), .int(8), .text("initial")]])

        let reader = container.makeContext()
        let storedOnly: [FlattenedCompositeFixture]
        do {
            storedOnly = try reader.fetch(FetchDescriptor<FlattenedCompositeFixture>(includePendingChanges: false))
        } catch {
            XCTFail("Flattened stored-only fetch failed: \(error)")
            return
        }
        XCTAssertEqual(storedOnly.count, 1)
        XCTAssertEqual(storedOnly.first?.dimensions, FlattenedDimensions(width: 8, label: "initial"))
        let leafPartial = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<FlattenedCompositeFixture>(
                    includePendingChanges: false, propertiesToFetch: [\.dimensions.width])
            ).first)
        XCTAssertEqual(leafPartial.dimensions, FlattenedDimensions(width: 8, label: "initial"))
        let width = 8
        let descriptor = FetchDescriptor<FlattenedCompositeFixture>(
            predicate: #Predicate { $0.dimensions.width == width })
        let fetched: FlattenedCompositeFixture
        do {
            fetched = try XCTUnwrap(reader.fetch(descriptor).first)
        } catch {
            XCTFail("Flattened predicate fetch failed: \(error)")
            return
        }
        XCTAssertEqual(fetched.dimensions, FlattenedDimensions(width: 8, label: "initial"))
        let labelPredicate = #Predicate<FlattenedCompositeFixture> { $0.dimensions.label == "initial" }
        let sortedLeaf = try reader.fetch(
            FetchDescriptor<FlattenedCompositeFixture>(sortBy: [SortDescriptor(\.dimensions.width)]))
        XCTAssertEqual(sortedLeaf.map(\.dimensions.width), [8])
        XCTAssertEqual(
            try reader.fetch(FetchDescriptor<FlattenedCompositeFixture>(predicate: labelPredicate)).count, 1)

        let wholeValue = FlattenedDimensions(width: 8, label: "initial")
        let wholeCompositeDescriptor = FetchDescriptor<FlattenedCompositeFixture>(
            predicate: #Predicate { $0.dimensions == wholeValue })
        XCTAssertThrowsError(try reader.fetch(wholeCompositeDescriptor)) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected unsupportedPredicate, got \(error)")
            }
        }

        fixture.dimensions = FlattenedDimensions(width: 12, label: "updated")
        try context.save()
        try reader.processPendingChanges()
        XCTAssertEqual(fetched.dimensions, FlattenedDimensions(width: 12, label: "updated"))
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<FlattenedCompositeFixture>()), 1)
        let updatedWidth = 12
        XCTAssertEqual(
            try reader.fetch(
                FetchDescriptor<FlattenedCompositeFixture>(
                    predicate: #Predicate { $0.dimensions.width == updatedWidth })
            ).count,
            1)
    }

    @MainActor
    func testFlattenedLeafSortMergesStoredAndPendingValues() throws {
        let container = try ModelContainer(
            for: FlattenedCompositeFixture.self, configurations: .sqliteMemory("flattened-leaf-sort"))
        let context = container.mainContext
        for width in [10, 2] {
            context.insert(
                FlattenedCompositeFixture(
                    dimensions: FlattenedDimensions(width: width, label: "stored-\(width)")))
        }
        try context.save()
        context.insert(FlattenedCompositeFixture(dimensions: FlattenedDimensions(width: 20, label: "pending-20")))
        context.insert(FlattenedCompositeFixture(dimensions: FlattenedDimensions(width: 3, label: "pending-3")))

        let descriptor = FetchDescriptor<FlattenedCompositeFixture>(sortBy: [SortDescriptor(\.dimensions.width)])
        XCTAssertEqual(try context.fetch(descriptor).map(\.dimensions.width), [2, 3, 10, 20])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, 4)
        XCTAssertEqual(try context.fetchCount(descriptor), 4)
    }

    @MainActor
    func testFlattenedDataLeafEqualityMatchesStoredAndPendingRows() throws {
        let container = try ModelContainer(
            for: FlattenedPayloadFixture.self, configurations: .sqliteMemory("flattened-data-leaf"))
        let context = container.mainContext
        let first = FlattenedPayloadFixture(payload: FlattenedPayload(bytes: Data([1, 2, 3])))
        let second = FlattenedPayloadFixture(payload: FlattenedPayload(bytes: Data()))
        context.insert(first)
        context.insert(second)
        try context.save()

        let needle = Data([1, 2, 3])
        let equal = FetchDescriptor<FlattenedPayloadFixture>(
            predicate: #Predicate { $0.payload.bytes == needle })
        let notEqual = FetchDescriptor<FlattenedPayloadFixture>(
            predicate: #Predicate { $0.payload.bytes != needle })
        XCTAssertEqual(try context.fetch(equal).count, 1)
        XCTAssertEqual(try context.fetch(notEqual).count, 1)
        let pending = FlattenedPayloadFixture(payload: FlattenedPayload(bytes: Data([1, 2, 3])))
        context.insert(pending)
        XCTAssertEqual(try context.fetch(equal).count, 2)
        XCTAssertEqual(try context.fetch(notEqual).count, 1)
    }

    @MainActor
    func testLazyRelationshipFaultLoadsFlattenedDestinationColumns() throws {
        let container = try ModelContainer(
            for: FlattenedCompositeOwnerFixture.self, FlattenedCompositeFixture.self,
            configurations: .sqliteMemory("flattened-relationship-fault"))
        let owner = FlattenedCompositeOwnerFixture(name: "owner")
        let dimensions = FlattenedCompositeFixture(dimensions: FlattenedDimensions(width: 7, label: "faulted"))
        container.mainContext.insert(owner)
        owner.dimensions = dimensions
        try container.mainContext.save()

        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<FlattenedCompositeOwnerFixture>()).first)
        XCTAssertEqual(fetchedOwner.dimensions?.dimensions, FlattenedDimensions(width: 7, label: "faulted"))
        let fetchedDestination = try XCTUnwrap(
            reader.fetch(FetchDescriptor<FlattenedCompositeFixture>()).first)
        XCTAssertTrue(fetchedOwner.dimensions === fetchedDestination)

        let prefetchReader = container.makeContext()
        let prefetchedOwner = try XCTUnwrap(
            prefetchReader.fetch(
                FetchDescriptor<FlattenedCompositeOwnerFixture>(relationshipKeyPathsForPrefetching: [\.dimensions])
            ).first)
        XCTAssertEqual(prefetchedOwner.dimensions?.dimensions, FlattenedDimensions(width: 7, label: "faulted"))
        let prefetchedDestination = try XCTUnwrap(
            prefetchReader.fetch(FetchDescriptor<FlattenedCompositeFixture>()).first)
        XCTAssertTrue(prefetchedOwner.dimensions === prefetchedDestination)
    }

    @MainActor
    func testUnflattenedCodableCompositeRemainsBlobBacked() throws {
        let container = try ModelContainer(
            for: CodableBlobFallbackFixture.self, configurations: .sqliteMemory("codable-blob-fallback"))
        let attribute = try XCTUnwrap(
            container.schema.entity(forName: "CodableBlobFallbackFixture")?.attributes.first)
        XCTAssertFalse(attribute.options.contains(.flattened))
        XCTAssertTrue(attribute.components.isEmpty)
        let context = container.mainContext
        context.insert(CodableBlobFallbackFixture(value: CodableBlobFixture(value: 42)))
        try context.save()
        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<CodableBlobFallbackFixture>()).first)
        XCTAssertEqual(fetched.value, CodableBlobFixture(value: 42))
    }

    @MainActor
    func testOptionalFlattenedCompositeFailsSchemaValidation() {
        XCTAssertThrowsError(
            try ModelContainer(
                for: OptionalFlattenedCompositeFixture.self,
                configurations: .sqliteMemory("optional-flattened-composite"))
        ) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    @MainActor
    func testDuplicateFlattenedComponentManifestFailsSchemaValidation() {
        XCTAssertThrowsError(
            try ModelContainer(
                for: DuplicateFlattenedFixture.self,
                configurations: .sqliteMemory("duplicate-flattened-components"))
        ) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    @MainActor
    func testUnsupportedFlattenedLeafTypeFailsSchemaValidation() {
        XCTAssertThrowsError(
            try ModelContainer(
                for: UnsupportedFlattenedLeafFixture.self,
                configurations: .sqliteMemory("unsupported-flattened-leaf"))
        ) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    @MainActor
    func testMixedIntegerAndDoubleSortComparisonPreservesInt64Precision() {
        let context = ModelContext()
        XCTAssertEqual(context.compareSortValues(.int((1 << 53) + 1), .double(0x1p53)), .orderedDescending)
        XCTAssertEqual(context.compareSortValues(.int(Int64.max), .double(0x1p63)), .orderedAscending)
        XCTAssertEqual(context.compareSortValues(.int(Int64.min), .double(-0x1p63)), .orderedSame)
        XCTAssertEqual(context.compareSortValues(.double(.nan), .null), .orderedSame)
    }

    func testPendingPredicateNumericComparisonPreservesInt64Precision() throws {
        let property = PredicatePlan.property("value")
        let exactDouble = PredicatePlan.value(.double(0x1p53))
        let greater = PredicatePlan.comparison(.greaterThan, property, exactDouble)
        let equal = PredicatePlan.comparison(.equal, property, exactDouble)
        let notEqual = PredicatePlan.comparison(.notEqual, property, exactDouble)

        XCTAssertTrue(try RuntimePredicateEvaluator.matches(greater, values: ["value": .int((1 << 53) + 1)]))
        XCTAssertFalse(try RuntimePredicateEvaluator.matches(equal, values: ["value": .int((1 << 53) + 1)]))
        XCTAssertTrue(try RuntimePredicateEvaluator.matches(notEqual, values: ["value": .int((1 << 53) + 1)]))
        XCTAssertFalse(try RuntimePredicateEvaluator.matches(greater, values: ["value": .double(.nan)]))
    }

    func testPendingStringPredicateTreatsNullAsUnknown() throws {
        let plan = PredicatePlan.stringContains(.property("title"), .value(.text("swift")))
        XCTAssertFalse(try RuntimePredicateEvaluator.matches(plan, values: ["title": .null]))
    }

    func testConditionalPendingPredicateUsesSqlCaseNullBranchSemantics() throws {
        let plan = PredicatePlan.conditional(
            .comparison(.greaterThan, .property("count"), .value(.int(5))),
            .comparison(.equal, .property("title"), .value(.text("yes"))),
            .comparison(.equal, .property("title"), .value(.text("no"))))

        XCTAssertTrue(try RuntimePredicateEvaluator.matches(plan, values: ["count": .int(6), "title": .text("yes")]))
        XCTAssertTrue(try RuntimePredicateEvaluator.matches(plan, values: ["count": .int(4), "title": .text("no")]))
        XCTAssertTrue(try RuntimePredicateEvaluator.matches(plan, values: ["count": .null, "title": .text("no")]))
        XCTAssertFalse(try RuntimePredicateEvaluator.matches(plan, values: ["count": .null, "title": .text("yes")]))
    }

    @MainActor
    func testOptionalCapturedPredicateValuesCompileForNilAndSome() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("optional-captured-predicate"))
        let context = container.mainContext
        context.insert(ReverseOrderPersistenceFixture(zebra: "nil", alpha: 1, middle: "m", optionalValue: nil))
        context.insert(ReverseOrderPersistenceFixture(zebra: "some", alpha: 2, middle: "m", optionalValue: "value"))
        try context.save()

        let nilCapture: String? = nil
        let nilPredicate = #Predicate<ReverseOrderPersistenceFixture> { $0.optionalValue == nilCapture }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: nilPredicate)).map(\.alpha), [1])

        let someCapture: String? = "value"
        let somePredicate = #Predicate<ReverseOrderPersistenceFixture> { $0.optionalValue == someCapture }
        let schema = try XCTUnwrap(
            container.schema.entity(forName: String(describing: ReverseOrderPersistenceFixture.self)))
        let tree = try PredicateRuntimeTreeBuilder.build(
            somePredicate.expression, modelType: ReverseOrderPersistenceFixture.self, entity: schema)
        guard let store = container.store as? any RuntimeQueryStore else {
            return XCTFail("Expected query-capable store")
        }
        let compiled = try store.compile(
            RuntimePredicateRequest(
                entityName: schema.name,
                root: tree.root,
                ordering: [],
                typedCaptures: tree.captures,
                captureEncoding: .typed,
                attributeNames: Set(schema.attributes.map(\.name)),
                attributeTypes: Dictionary(uniqueKeysWithValues: schema.attributes.map { ($0.name, $0.type) })))
        XCTAssertEqual(compiled.sql, "(t0.ZOPTIONALVALUE = ?)")
        XCTAssertEqual(compiled.arguments, [.text("value")])
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: somePredicate)).map(\.alpha), [2])
    }

    @MainActor
    func testFetchedDirtyModelIsReevaluatedAgainstPendingPredicate() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("dirty-fetched-predicate"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "dirty")
        model.count = 1
        context.insert(model)
        try context.save()

        let original = #Predicate<PersistenceTestModel> { $0.count == 1 }
        let matching: [PersistenceTestModel] = try context.fetch(FetchDescriptor(predicate: original))
        XCTAssertTrue(matching.first === model)
        model.count = 9

        XCTAssertTrue(try context.fetch(FetchDescriptor(predicate: original)).isEmpty)
        XCTAssertTrue(try context.fetchIdentifiers(FetchDescriptor(predicate: original)).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor(predicate: original)), 0)
    }

    @MainActor
    func testExplicitCodableAttributeSQLiteRoundTrip() throws {
        let container = try ModelContainer(
            for: ExplicitCodableAttributeFixture.self, configurations: .sqliteMemory("codable-attribute"))
        let payload = CodablePayload(label: "round-trip", count: 37)
        let model = ExplicitCodableAttributeFixture(payload: payload)
        container.mainContext.insert(model)
        try container.mainContext.save()
        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<ExplicitCodableAttributeFixture>()).first)
        XCTAssertEqual(fetched.payload, payload)
    }

    @MainActor
    func testExternalDataPersistsReopensAndCleansReplacedPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataExternalData-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("store.sqlite")
        let firstPayload = Data(repeating: 1, count: 131_073)
        let secondPayload = Data(repeating: 2, count: 131_074)

        let firstContainer = try ModelContainer(
            for: ExternalDataFixture.self,
            configurations: .sqliteFile("external-data", url: storeURL))
        let firstContext = firstContainer.mainContext
        firstContext.insert(ExternalDataFixture(label: "payload", payload: firstPayload))
        try firstContext.save()

        let sidecarDirectory = directory.appendingPathComponent("store.sqlite.external", isDirectory: true)
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path)
        XCTAssertEqual(originalFiles.filter { $0.hasPrefix("data-") && $0.hasSuffix(".blob") }.count, 1)
        let readerContainer = try ModelContainer(
            for: ExternalDataFixture.self,
            configurations: .sqliteFile("external-data-reader", url: storeURL))
        let reader = readerContainer.makeContext()
        XCTAssertEqual(try reader.fetch(FetchDescriptor<ExternalDataFixture>()).first?.payload, firstPayload)

        let changed = try XCTUnwrap(firstContext.fetch(FetchDescriptor<ExternalDataFixture>()).first)
        changed.payload = secondPayload
        try firstContext.save()
        XCTAssertEqual(try reader.fetch(FetchDescriptor<ExternalDataFixture>()).first?.payload, secondPayload)
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path)
            .filter { $0.hasPrefix("data-") && $0.hasSuffix(".blob") }
        XCTAssertEqual(remainingFiles.count, 1)
        XCTAssertNotEqual(Set(remainingFiles), Set(originalFiles))
    }

    @MainActor
    func testExternalStorageOptionRejectsNonDataProperty() {
        XCTAssertThrowsError(
            try ModelContainer(
                for: InvalidExternalDataOptionFixture.self,
                configurations: .sqliteMemory("invalid-external-storage-type"))
        ) { error in
            guard case SwiftDataError.unsupportedSchemaProperty = error else {
                return XCTFail("Expected unsupportedSchemaProperty, got \(error)")
            }
        }
    }

    @MainActor
    func testInsertedModelSavesFetchesAndReusesIdentity() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("context-test"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "persisted")
        let temporaryID = model.persistentModelID
        context.insert(model)
        try context.save()

        XCTAssertFalse(model.persistentModelID.isTemporary)
        XCTAssertNotEqual(model.persistentModelID, temporaryID)
        XCTAssertEqual(model.persistentModelID.storeIdentifier, "context-test")
        let fetched = try context.fetch(FetchDescriptor<PersistenceTestModel>())
        XCTAssertTrue(fetched.first === model)
        XCTAssertTrue(try context.model(for: model.persistentModelID) as PersistenceTestModel? === model)
    }

    @MainActor
    func testFetchDescriptorLimitOffsetSortAndConvenienceQueries() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("fetch-descriptor"))
        let context = container.mainContext
        for title in ["c", "a", "b"] {
            context.insert(PersistenceTestModel(title: title))
        }
        try context.save()

        let descriptor = FetchDescriptor<PersistenceTestModel>(
            sortBy: [SortDescriptor(\.title)], fetchLimit: 1, fetchOffset: 1)
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.map(\.title), ["b"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), fetched.map(\.persistentModelID))
        let countDescriptor = FetchDescriptor<PersistenceTestModel>(includePendingChanges: false)
        XCTAssertEqual(try context.fetchCount(countDescriptor), 3)
        XCTAssertEqual(try context.fetchIdentifiers(countDescriptor).count, 3)
        var enumerated: [String] = []
        try context.enumerate(descriptor, batchSize: 1, allowEscapingMutations: true) { enumerated.append($0.title) }
        XCTAssertEqual(enumerated, ["b"])
        let offsetOnly = FetchDescriptor<PersistenceTestModel>(fetchOffset: 1, includePendingChanges: false)
        XCTAssertEqual(try context.fetch(offsetOnly).count, 2)
        XCTAssertEqual(try context.fetchIdentifiers(offsetOnly).count, 2)
        XCTAssertEqual(try context.fetchCount(offsetOnly), 2)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PersistenceTestModel>(fetchLimit: 0, includePendingChanges: false)),
            0)
        let limitedPage = FetchDescriptor<PersistenceTestModel>(
            sortBy: [SortDescriptor(\.title)], fetchLimit: 1, fetchOffset: 1, includePendingChanges: false)
        XCTAssertEqual(try context.fetch(limitedPage).map(\.title), ["b"])
        XCTAssertEqual(try context.fetchIdentifiers(limitedPage).count, 1)
        XCTAssertEqual(try context.fetchCount(limitedPage), 1)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PersistenceTestModel>(fetchLimit: 0, includePendingChanges: false)),
            0)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<PersistenceTestModel>(fetchOffset: 10, includePendingChanges: false)),
            0)
    }

    @MainActor
    func testPredicateFetchAppliesPredicateToStoredRows() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("stored-fetch-predicate"))
        let context = container.mainContext
        for count in [0, 3, 7] {
            let model = PersistenceTestModel(title: "count-\(count)")
            model.count = count
            context.insert(model)
        }
        try context.save()
        let predicate = #Predicate<PersistenceTestModel> { $0.count >= 5 }
        let descriptor = FetchDescriptor<PersistenceTestModel>(predicate: predicate)

        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["count-7"])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, 1)
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
    }

    @MainActor
    func testSQLitePredicateFetchCompilesAndBindsCapturedValues() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("predicate-fetch"))
        let context = container.mainContext
        for (title, count) in [("low", 1), ("match-a", 5), ("match-b", 8)] {
            let model = PersistenceTestModel(title: title)
            model.count = count
            context.insert(model)
        }
        try context.save()

        let predicate = #Predicate<PersistenceTestModel> { $0.count >= 5 }
        let descriptor = FetchDescriptor<PersistenceTestModel>(predicate: predicate, includePendingChanges: false)
        let rows = try context.fetch(descriptor)

        XCTAssertEqual(rows.map(\.title), ["match-a", "match-b"])
    }

    @MainActor
    func testTypedPredicateCapturesPreserveDoublePrecision() throws {
        let container = try ModelContainer(
            for: PredicateDoubleFixture.self, configurations: .sqliteMemory("typed-predicate-capture"))
        let exact = 1.0000000000000002
        container.mainContext.insert(PredicateDoubleFixture(score: exact))
        container.mainContext.insert(PredicateDoubleFixture(score: 1.0000000000000004))
        try container.mainContext.save()

        let predicate = #Predicate<PredicateDoubleFixture> { $0.score == exact }
        let descriptor = FetchDescriptor<PredicateDoubleFixture>(predicate: predicate, includePendingChanges: false)
        let entity = try XCTUnwrap(container.schema.entity(forName: String(describing: PredicateDoubleFixture.self)))
        let tree = try PredicateRuntimeTreeBuilder.build(
            predicate.expression, modelType: PredicateDoubleFixture.self, entity: entity)

        XCTAssertTrue(tree.captures.values.contains(.double(exact)))
        XCTAssertEqual(try container.mainContext.fetch(descriptor).map(\.score), [exact])
    }

    @MainActor
    func testPendingStringEqualityMatchesSQLiteBinarySemantics() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("string-byte-equality"))
        let context = container.mainContext
        let composed = PersistenceTestModel(title: "é")
        context.insert(composed)
        try context.save()
        let decomposed = PersistenceTestModel(title: "e\u{301}")
        context.insert(decomposed)
        let predicate = #Predicate<PersistenceTestModel> { $0.title == "é" }
        let descriptor = FetchDescriptor<PersistenceTestModel>(predicate: predicate)

        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["é"])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), [composed.persistentModelID])
    }

    @MainActor
    func testLocalizedStandardContainsMatchesStoredAndPendingRows() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("localized-contains"))
        let context = container.mainContext
        context.insert(PersistenceTestModel(title: "Café Society"))
        context.insert(PersistenceTestModel(title: "Other"))
        try context.save()
        context.insert(PersistenceTestModel(title: "CAFE racer"))

        let descriptor = FetchDescriptor<PersistenceTestModel>(
            predicate: localizedStandardContains(\.title, "cafe"))
        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["Café Society", "CAFE racer"])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, 2)
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
    }

    @MainActor
    func testStringContainsUsesSwiftCanonicalGraphemeSemantics() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("string-contains-grapheme"))
        let context = container.mainContext
        context.insert(PersistenceTestModel(title: "café"))
        try context.save()
        context.insert(PersistenceTestModel(title: "cafe\u{301}"))

        let canonicalNeedle = "e\u{301}"
        let containsComposed = FetchDescriptor<PersistenceTestModel>(
            predicate: #Predicate { $0.title.contains(canonicalNeedle) })
        let expectedCanonical = ["café", "cafe\u{301}"].filter { $0.contains(canonicalNeedle) }
        XCTAssertEqual(try context.fetch(containsComposed).map(\.title), expectedCanonical)
        XCTAssertEqual(try context.fetchIdentifiers(containsComposed).count, expectedCanonical.count)

        let partialCluster = FetchDescriptor<PersistenceTestModel>(
            predicate: #Predicate { $0.title.contains("e") })
        let expectedPartial = ["café", "cafe\u{301}"].filter { $0.contains("e") }
        XCTAssertEqual(try context.fetch(partialCluster).map(\.title), expectedPartial)
    }

    @MainActor
    func testStringStartsWithUsesSwiftCanonicalGraphemeSemantics() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("string-prefix-grapheme"))
        let context = container.mainContext
        context.insert(PersistenceTestModel(title: "éclair"))
        try context.save()
        context.insert(PersistenceTestModel(title: "e\u{301}clair"))

        let prefix = "e\u{301}"
        let descriptor = FetchDescriptor<PersistenceTestModel>(predicate: #Predicate { $0.title.starts(with: prefix) })
        let candidates = ["éclair", "e\u{301}clair"]
        let expected = candidates.filter { $0.starts(with: prefix) }
        XCTAssertEqual(try context.fetch(descriptor).map(\.title), expected)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, expected.count)
    }

    @MainActor
    func testConditionalPredicateMatchesStoredAndPendingRows() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("conditional-predicate"))
        let context = container.mainContext
        let storedTrue = PersistenceTestModel(title: "yes")
        storedTrue.count = 6
        let storedFalse = PersistenceTestModel(title: "no")
        storedFalse.count = 4
        context.insert(storedTrue)
        context.insert(storedFalse)
        try context.save()
        let pending = PersistenceTestModel(title: "yes")
        pending.count = 8
        context.insert(pending)

        let threshold = 5
        let descriptor = FetchDescriptor<PersistenceTestModel>(
            predicate: #Predicate {
                $0.count > threshold ? $0.title == "yes" : $0.title == "no"
            }, sortBy: [SortDescriptor(\.count)])

        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["no", "yes", "yes"])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, 3)
        XCTAssertEqual(try context.fetchCount(descriptor), 3)
    }

    @MainActor
    func testStoreHubRefreshesCleanModelsOnNextContextAccess() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("store-hub-clean-refresh"))
        let writer = container.mainContext
        let first = PersistenceTestModel(title: "first")
        let second = PersistenceTestModel(title: "second")
        writer.insert(first)
        writer.insert(second)
        try writer.save()

        let reader = container.makeContext()
        let readerFirst = try XCTUnwrap(
            reader.fetch(FetchDescriptor<PersistenceTestModel>()).first {
                $0.title == "first"
            })
        let readerSecond = try XCTUnwrap(
            reader.fetch(FetchDescriptor<PersistenceTestModel>()).first {
                $0.title == "second"
            })
        first.title = "updated"
        try writer.save()

        try reader.processPendingChanges()
        XCTAssertEqual(readerFirst.title, "updated")
        XCTAssertEqual(readerSecond.title, "second")
        XCTAssertFalse(reader.hasChanges)
    }

    @MainActor
    func testStoreHubPreservesDirtyModelsDuringCrossContextMerge() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("store-hub-dirty-preservation"))
        let writer = container.mainContext
        let model = PersistenceTestModel(title: "stored")
        writer.insert(model)
        try writer.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        fetched.title = "local"
        model.title = "remote"
        try writer.save()

        try reader.processPendingChanges()
        XCTAssertEqual(fetched.title, "local")
        XCTAssertTrue(fetched.hasChanges)
    }

    @MainActor
    func testStoreHubPropagatesInsertedAndDeletedKeys() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("store-hub-insert-delete"))
        let writer = container.mainContext
        let reader = container.makeContext()

        let inserted = PersistenceTestModel(title: "inserted")
        writer.insert(inserted)
        try writer.save()
        let fetchedInserted = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        XCTAssertEqual(fetchedInserted.persistentModelID, inserted.persistentModelID)

        writer.delete(inserted)
        try writer.save()
        try reader.processPendingChanges()
        XCTAssertNil(try reader.model(for: fetchedInserted.persistentModelID) as PersistenceTestModel?)
        XCTAssertNil(fetchedInserted.modelContext)
    }

    @MainActor
    func testCrossContextDeleteMarksHeldModelDeleted() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("store-hub-held-delete"))
        let writer = container.mainContext
        let model = PersistenceTestModel(title: "held")
        writer.insert(model)
        try writer.save()

        let reader = container.makeContext()
        let held = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        let identifier = held.persistentModelID
        writer.delete(model)
        try writer.save()

        try reader.processPendingChanges()
        XCTAssertTrue(held.isDeleted)
        XCTAssertNil(try reader.model(for: identifier) as PersistenceTestModel?)
        XCTAssertNil(held.modelContext)
    }

    @MainActor
    func testStoreHubDoesNotMergeChangesAcrossDistinctStores() throws {
        let firstContainer = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("store-hub-isolation-first"))
        let secondContainer = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("store-hub-isolation-second"))
        let first = PersistenceTestModel(title: "first")
        let second = PersistenceTestModel(title: "second")
        firstContainer.mainContext.insert(first)
        secondContainer.mainContext.insert(second)
        try firstContainer.mainContext.save()
        try secondContainer.mainContext.save()

        let reader = firstContainer.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        second.title = "changed elsewhere"
        try secondContainer.mainContext.save()
        try reader.processPendingChanges()

        XCTAssertEqual(fetched.title, "first")
    }

    @MainActor
    func testStoreHubPublishesRelationshipOnlyChanges() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("store-hub-relationship-only"))
        let writer = container.mainContext
        let firstOwner = PersistentRelationshipOwner(title: "first")
        let secondOwner = PersistentRelationshipOwner(title: "second")
        let child = PersistentRelationshipChild(title: "child")
        writer.insert(firstOwner)
        writer.insert(secondOwner)
        firstOwner.children = [child]
        try writer.save()

        let reader = container.makeContext()
        let fetchedOwners = try reader.fetch(
            FetchDescriptor<PersistentRelationshipOwner>(sortBy: [SortDescriptor(\.title)]))
        let fetchedChild = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        XCTAssertEqual(fetchedChild.owner?.title, "first")
        XCTAssertEqual(fetchedOwners.first?.children.map(\.title), ["child"])

        let writerChild = try XCTUnwrap(writer.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        writerChild.owner = secondOwner
        try writer.save()

        try reader.processPendingChanges()
        XCTAssertEqual(fetchedChild.owner?.title, "second")
        XCTAssertTrue(fetchedOwners.first?.children.isEmpty == true)
        XCTAssertEqual(fetchedOwners.last?.children.map(\.title), ["child"])
    }

    @MainActor
    func testFailedStoreWriteDoesNotPublishChangeSet() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("store-hub-failed-write"))
        let writer = container.mainContext
        let reader = container.makeContext()
        try container.store?.write { connection in
            try connection.execute(
                "CREATE TRIGGER FAIL_PERSISTENCE_TEST BEFORE INSERT ON ZPERSISTENCETESTMODEL "
                    + "BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
                arguments: [])
        }
        writer.insert(PersistenceTestModel(title: "rejected"))
        XCTAssertThrowsError(try writer.save())
        try reader.processPendingChanges()
        XCTAssertTrue(writer.hasChanges)
        XCTAssertTrue(try reader.fetch(FetchDescriptor<PersistenceTestModel>()).isEmpty)
        try container.store?.write { connection in
            try connection.execute("DROP TRIGGER FAIL_PERSISTENCE_TEST", arguments: [])
        }
    }

    @MainActor
    func testClosedIntegerRangePredicateMatchesStoredAndPendingRows() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("integer-range-predicate"))
        let context = container.mainContext
        let storedLow = PersistenceTestModel(title: "low")
        storedLow.count = 1
        let storedInRange = PersistenceTestModel(title: "stored-in-range")
        storedInRange.count = 4
        let storedHigh = PersistenceTestModel(title: "high")
        storedHigh.count = 9
        context.insert(storedLow)
        context.insert(storedInRange)
        context.insert(storedHigh)
        try context.save()
        let pending = PersistenceTestModel(title: "pending-in-range")
        pending.count = 7
        context.insert(pending)

        let descriptor = FetchDescriptor<PersistenceTestModel>(
            predicate: #Predicate { (2...7).contains($0.count) }, sortBy: [SortDescriptor(\.count)])
        XCTAssertEqual(try context.fetch(descriptor).map(\.count), [4, 7])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, 2)
        XCTAssertEqual(try context.fetchCount(descriptor), 2)

        let reversedBounds = FetchDescriptor<PersistenceTestModel>(
            predicate: #Predicate { (7...2).contains($0.count) })
        XCTAssertTrue(try context.fetch(reversedBounds).isEmpty)
    }

    @MainActor
    func testHalfOpenIntegerRangeExcludesUpperBound() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("half-open-range-predicate"))
        let context = container.mainContext
        for count in [1, 2, 6, 7] {
            let model = PersistenceTestModel(title: "range-\(count)")
            model.count = count
            context.insert(model)
        }
        try context.save()
        let pending = PersistenceTestModel(title: "range-pending")
        pending.count = 6
        context.insert(pending)
        let descriptor = FetchDescriptor<PersistenceTestModel>(
            predicate: #Predicate { (2..<7).contains($0.count) }, sortBy: [SortDescriptor(\.count)])

        XCTAssertEqual(try context.fetch(descriptor).map(\.count), [2, 6, 6])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, 3)
        XCTAssertEqual(try context.fetchCount(descriptor), 3)
    }

    @MainActor
    func testSelectiveRelationshipPrefetchFaultsOtherRelationshipsOnAccess() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("selective-relationship-prefetch"))
        let owner = PersistentRelationshipOwner(title: "owner")
        let child = PersistentRelationshipChild(title: "child")
        let favorite = PersistentRelationshipChild(title: "favorite")
        container.mainContext.insert(owner)
        owner.children = [child]
        owner.favorite = favorite
        try container.mainContext.save()

        let reader = container.makeContext()
        let descriptor = FetchDescriptor<PersistentRelationshipOwner>(
            relationshipKeyPathsForPrefetching: [\.children])
        let fetched = try XCTUnwrap(reader.fetch(descriptor).first)
        XCTAssertEqual(fetched.children.map(\.title), ["child"])
        XCTAssertEqual(fetched.favorite?.title, "favorite")
        XCTAssertEqual(fetched.children.first?.owner?.persistentModelID, fetched.persistentModelID)
    }

    @MainActor
    func testManyToManyRelationshipFaultResolvesInverseWithoutEagerPrefetch() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-lazy-relationship"))
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        container.mainContext.insert(group)
        group.tags = [tag]
        try container.mainContext.save()

        let reader = container.makeContext()
        let descriptor = FetchDescriptor<PersistentTagGroup>(relationshipKeyPathsForPrefetching: [\.tags])
        let fetchedGroup = try XCTUnwrap(reader.fetch(descriptor).first)
        let fetchedTag = try XCTUnwrap(fetchedGroup.tags.first)
        XCTAssertEqual(fetchedTag.name, "tag")
        XCTAssertEqual(fetchedTag.groups.map(\.persistentModelID), [fetchedGroup.persistentModelID])
        let independentlyFetchedTag = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTag>()).first)
        XCTAssertTrue(fetchedTag === independentlyFetchedTag)
    }

    @MainActor
    func testUnrequestedRelationshipLoadsWhenAccessedAfterFetch() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("unrequested-lazy-relationship"))
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        container.mainContext.insert(group)
        group.tags = [tag]
        try container.mainContext.save()

        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetchedGroup.name, "group")
        XCTAssertEqual(fetchedGroup.tags.map(\.name), ["tag"])
    }

    @MainActor
    func testPendingRelationshipOverlayWinsOverUnloadedRelationshipFault() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("pending-lazy-relationship-overlay"))
        let group = PersistentTagGroup(name: "group")
        let persisted = PersistentTag(name: "persisted")
        container.mainContext.insert(group)
        group.tags = [persisted]
        try container.mainContext.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        let replacement = PersistentTag(name: "replacement")
        reader.insert(replacement)
        fetched.tags = [replacement]

        XCTAssertEqual(fetched.tags.map(\.name), ["replacement"])
        XCTAssertEqual(fetched.hasChanges, true)
        try reader.save()
        XCTAssertEqual(try reader.fetch(FetchDescriptor<PersistentTagGroup>()).first?.tags.map(\.name), ["replacement"])
    }

    @MainActor
    func testLazyInverseFaultReplaysReassignmentOldAndNewEndpoints() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("lazy-inverse-event-replay"))
        let owner = PersistentRelationshipOwner(title: "old")
        let child = PersistentRelationshipChild(title: "child")
        container.mainContext.insert(owner)
        owner.children = [child]
        try container.mainContext.save()

        let reader = container.makeContext()
        let oldOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        let pendingNewOwner = PersistentRelationshipOwner(title: "new")
        reader.insert(pendingNewOwner)
        let pendingChild = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        pendingChild.owner = pendingNewOwner

        XCTAssertTrue(oldOwner.children.isEmpty)
        XCTAssertEqual(pendingChild.owner?.persistentModelID, pendingNewOwner.persistentModelID)
        XCTAssertEqual(pendingNewOwner.children.map(\.persistentModelID), [pendingChild.persistentModelID])
        let fetchedNewOwner = try XCTUnwrap(
            reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first {
                $0.title == "new"
            })
        XCTAssertTrue(fetchedNewOwner === pendingNewOwner)
    }

    @MainActor
    func testLoadingUnrelatedInverseDoesNotReplaceToOneRelationship() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("lazy-unrelated-to-one-inverse"))
        let firstOwner = PersistentRelationshipOwner(title: "first")
        let secondOwner = PersistentRelationshipOwner(title: "second")
        let child = PersistentRelationshipChild(title: "child")
        container.mainContext.insert(firstOwner)
        firstOwner.children = [child]
        container.mainContext.insert(secondOwner)
        try container.mainContext.save()

        let reader = container.makeContext()
        let owners = try reader.fetch(
            FetchDescriptor<PersistentRelationshipOwner>(sortBy: [SortDescriptor(\.title)]))
        let fetchedFirst = try XCTUnwrap(owners.first)
        let fetchedSecond = try XCTUnwrap(owners.last)
        let fetchedChild = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        XCTAssertEqual(fetchedChild.owner?.persistentModelID, fetchedFirst.persistentModelID)

        XCTAssertTrue(fetchedSecond.children.isEmpty)
        XCTAssertEqual(fetchedChild.owner?.persistentModelID, fetchedFirst.persistentModelID)
    }

    @MainActor
    func testDeleteRuleReadsUnprefetchedToManyRelationshipFault() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("delete-unprefetched-relationship"))
        let owner = PersistentRelationshipOwner(title: "owner")
        let child = PersistentRelationshipChild(title: "child")
        container.mainContext.insert(owner)
        owner.children = [child]
        try container.mainContext.save()

        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(fetchedOwner.children.map(\.title), ["child"])
        let fetchedChild = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        XCTAssertEqual(fetchedChild.owner?.persistentModelID, fetchedOwner.persistentModelID)
        reader.delete(fetchedOwner)
        try reader.processPendingChanges()
        XCTAssertNil(fetchedChild.owner)
    }

    @MainActor
    func testCascadeDeleteDiscoversUnprefetchedToManyEndpoints() throws {
        let container = try ModelContainer(
            for: LazyCascadeOwnerFixture.self, LazyCascadeChildFixture.self,
            configurations: .sqliteMemory("lazy-cascade-delete"))
        let owner = LazyCascadeOwnerFixture(title: "owner")
        let child = LazyCascadeChildFixture(title: "child")
        container.mainContext.insert(owner)
        owner.children = [child]
        try container.mainContext.save()

        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<LazyCascadeOwnerFixture>()).first)
        reader.delete(fetchedOwner)
        try reader.processPendingChanges()

        XCTAssertTrue(reader.deletedModelsArray.contains { $0 === fetchedOwner })
        let remainingChildren = try reader.fetch(FetchDescriptor<LazyCascadeChildFixture>())
        XCTAssertTrue(remainingChildren.isEmpty)
    }

    @MainActor
    func testPendingOptionalNilMutationIsNotReplacedByStoredValue() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("pending-optional-nil"))
        let context = container.mainContext
        let model = ReverseOrderPersistenceFixture(zebra: "item", alpha: 1, middle: "m", optionalValue: "stored")
        context.insert(model)
        try context.save()

        model.optionalValue = nil
        XCTAssertNil(model.optionalValue)
        XCTAssertTrue(model.hasChanges)
        try context.save()
        XCTAssertNil(try context.fetch(FetchDescriptor<ReverseOrderPersistenceFixture>()).first?.optionalValue)
    }

    @MainActor
    func testPartialFetchMarksSqlNullOptionalValueAsLoaded() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("partial-null-fault"))
        let context = container.mainContext
        let model = ReverseOrderPersistenceFixture(zebra: "null", alpha: 1, middle: "m", optionalValue: nil)
        context.insert(model)
        try context.save()

        let reader = container.makeContext()
        let descriptor = FetchDescriptor<ReverseOrderPersistenceFixture>(propertiesToFetch: [\.zebra])
        let partial = try XCTUnwrap(reader.fetch(descriptor).first)
        XCTAssertNil(partial.optionalValue)
        XCTAssertNil(partial.optionalValue)
        XCTAssertFalse(partial.hasChanges)
    }

    @MainActor
    func testPredicateQueriesReconcilePendingModelsBeforePagination() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("pending-predicate-query"))
        let context = container.mainContext
        let storedLow = PersistenceTestModel(title: "stored-low")
        let storedHigh = PersistenceTestModel(title: "stored-high")
        storedHigh.count = 8
        context.insert(storedLow)
        context.insert(storedHigh)
        try context.save()

        let pendingMatch = PersistenceTestModel(title: "pending-match")
        pendingMatch.count = 6
        let pendingMiss = PersistenceTestModel(title: "pending-miss")
        pendingMiss.count = 2
        context.insert(pendingMatch)
        context.insert(pendingMiss)
        let predicate = #Predicate<PersistenceTestModel> { $0.count >= 5 }
        let descriptor = FetchDescriptor<PersistenceTestModel>(predicate: predicate)

        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["stored-high", "pending-match"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        XCTAssertEqual(
            try context.fetchIdentifiers(descriptor), [storedHigh.persistentModelID, pendingMatch.persistentModelID])

        var enumerated: [String] = []
        try context.enumerate(descriptor, batchSize: 1) { enumerated.append($0.title) }
        XCTAssertEqual(enumerated, ["stored-high", "pending-match"])

        storedLow.count = 9
        storedHigh.count = 1
        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["stored-low", "pending-match"])
        XCTAssertEqual(
            try context.fetchIdentifiers(descriptor), [storedLow.persistentModelID, pendingMatch.persistentModelID])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        storedLow.count = 1
        storedHigh.count = 8
        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["stored-high", "pending-match"])
        XCTAssertEqual(
            try context.fetchIdentifiers(descriptor), [storedHigh.persistentModelID, pendingMatch.persistentModelID])
        let page = FetchDescriptor<PersistenceTestModel>(
            predicate: predicate, sortBy: [SortDescriptor(\.count)], fetchLimit: 1, fetchOffset: 1)
        storedLow.count = 9
        storedHigh.count = 1
        XCTAssertEqual(try context.fetch(page).map(\.title), ["stored-low"])

        storedHigh.count = 8
        let limited = FetchDescriptor<PersistenceTestModel>(
            predicate: predicate, sortBy: [SortDescriptor(\.count)], fetchLimit: 1)
        XCTAssertEqual(try context.fetch(limited).map(\.title), ["pending-match"])
        storedHigh.count = 4
        XCTAssertEqual(try context.fetch(limited).map(\.title), ["pending-match"])
        storedHigh.count = 5
        XCTAssertEqual(try context.fetch(limited).map(\.title), ["stored-high"])

        context.delete(storedHigh)
        XCTAssertFalse(try context.fetch(limited).contains(where: { $0 === storedHigh }))
        XCTAssertFalse(try context.fetchIdentifiers(limited).contains(storedHigh.persistentModelID))
        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["stored-low", "pending-match"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        var invalidOffset = descriptor
        invalidOffset.fetchOffset = -1
        XCTAssertThrowsError(try context.fetch(invalidOffset))
    }

    @MainActor
    func testInsertedThenDeletedModelIsAbsentFromPendingFetch() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("insert-delete-fetch"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "transient")
        context.insert(model)
        context.delete(model)

        XCTAssertTrue(
            try context.fetch(FetchDescriptor<PersistenceTestModel>(includePendingChanges: false)).isEmpty)
        XCTAssertTrue(try context.fetchIdentifiers(FetchDescriptor<PersistenceTestModel>()).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistenceTestModel>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testPendingUniqueInsertRemainsDistinctUntilSave() throws {
        let container = try ModelContainer(
            for: FailedWritePersistenceFixture.self, configurations: .sqliteMemory("pending-unique-fetch"))
        let context = container.mainContext
        let stored = FailedWritePersistenceFixture(key: "shared")
        context.insert(stored)
        try context.save()
        let storedID = stored.persistentModelID

        let pending = FailedWritePersistenceFixture(key: "shared")
        context.insert(pending)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FailedWritePersistenceFixture>()).count, 2)

        try context.save()
        let fetched = try context.fetch(FetchDescriptor<FailedWritePersistenceFixture>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.persistentModelID, storedID)
        XCTAssertEqual(fetched.first?.key, "shared")
    }

    @MainActor
    func testPendingLogicalPredicateUsesSQLEquivalentTruthRules() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("pending-logical-predicate"))
        let context = container.mainContext
        for (title, count) in [("stored-low", 1), ("stored-match", 5)] {
            let model = PersistenceTestModel(title: title)
            model.count = count
            context.insert(model)
        }
        try context.save()
        let pending = PersistenceTestModel(title: "pending-match")
        pending.count = 7
        context.insert(pending)

        let predicate = #Predicate<PersistenceTestModel> { $0.count > 2 && !($0.count > 8) }
        let descriptor = FetchDescriptor<PersistenceTestModel>(predicate: predicate)
        let expected = ["stored-match", "pending-match"]
        XCTAssertEqual(try context.fetch(descriptor).map(\.title), expected)
        XCTAssertEqual(
            try context.fetchIdentifiers(descriptor).map(\.primaryKey),
            [
                try XCTUnwrap(try context.fetch(descriptor).first?.persistentModelID.primaryKey),
                pending.persistentModelID.primaryKey,
            ])
        XCTAssertEqual(try context.fetchCount(descriptor), expected.count)
    }

    @MainActor
    func testOptionalPredicateAgainstNullValues() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("optional-predicate"))
        let context = container.mainContext
        context.insert(ReverseOrderPersistenceFixture(zebra: "a", alpha: 1, middle: "a", optionalValue: nil))
        context.insert(ReverseOrderPersistenceFixture(zebra: "b", alpha: 2, middle: "b", optionalValue: "value"))
        try context.save()

        let isNil = #Predicate<ReverseOrderPersistenceFixture> { $0.optionalValue == nil }
        let isNotNil = #Predicate<ReverseOrderPersistenceFixture> { $0.optionalValue != nil }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: isNil)).map(\.alpha), [1])
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: isNotNil)).map(\.alpha), [2])
    }

    @MainActor
    func testPendingNegatedOptionalNilPredicateMatchesSql() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("pending-negated-null"))
        let context = container.mainContext
        let stored = ReverseOrderPersistenceFixture(zebra: "stored", alpha: 1, middle: "m", optionalValue: "set")
        context.insert(stored)
        try context.save()

        let pending = ReverseOrderPersistenceFixture(zebra: "pending", alpha: 2, middle: "m", optionalValue: "set")
        context.insert(pending)
        let predicate = #Predicate<ReverseOrderPersistenceFixture> { !($0.optionalValue == nil) }
        let descriptor = FetchDescriptor<ReverseOrderPersistenceFixture>(predicate: predicate)

        XCTAssertEqual(try context.fetch(descriptor).map(\.alpha), [1, 2])
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), [stored.persistentModelID, pending.persistentModelID])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
    }

    @MainActor
    func testLocalizedStringAndOptionalSortingIncludesPendingModels() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("localized-sort"))
        let context = container.mainContext
        let first = ReverseOrderPersistenceFixture(zebra: "item 10", alpha: 1, middle: "m", optionalValue: nil)
        let second = ReverseOrderPersistenceFixture(zebra: "item 2", alpha: 2, middle: "m", optionalValue: "x")
        context.insert(first)
        context.insert(second)
        try context.save()
        let pending = ReverseOrderPersistenceFixture(zebra: "Álpha 1", alpha: 3, middle: "m", optionalValue: nil)
        context.insert(pending)

        let ascending = FetchDescriptor<ReverseOrderPersistenceFixture>(
            sortBy: [SortDescriptor(\.optionalValue), SortDescriptor(\.zebra)])
        let descending = FetchDescriptor<ReverseOrderPersistenceFixture>(
            sortBy: [SortDescriptor(\.optionalValue, order: .reverse)])
        let persistedStringOrder = FetchDescriptor<ReverseOrderPersistenceFixture>(
            sortBy: [SortDescriptor(\.zebra)], includePendingChanges: false)

        let ascendingRows = try context.fetch(ascending)
        let expectedAscending = [first, second, pending].sorted { lhs, rhs in
            let nilOrder: ComparisonResult
            switch (lhs.optionalValue, rhs.optionalValue) {
            case (nil, nil): nilOrder = .orderedSame
            case (nil, .some): nilOrder = .orderedAscending
            case (.some, nil): nilOrder = .orderedDescending
            case (.some, .some): nilOrder = .orderedSame
            }
            if nilOrder != .orderedSame { return nilOrder == .orderedAscending }
            let textOrder = lhs.zebra.localizedStandardCompare(rhs.zebra)
            if textOrder != .orderedSame { return textOrder == .orderedAscending }
            return (lhs.persistentModelID.primaryKey ?? Int64.max) < (rhs.persistentModelID.primaryKey ?? Int64.max)
        }
        XCTAssertEqual(ascendingRows.map(\.persistentModelID), expectedAscending.map(\.persistentModelID))
        XCTAssertEqual(try context.fetch(descending).map(\.alpha), [2, 1, 3])
        XCTAssertEqual(try context.fetchIdentifiers(ascending), ascendingRows.map(\.persistentModelID))
        XCTAssertEqual(try context.fetch(persistedStringOrder).map(\.alpha), [2, 1])
    }

    @MainActor
    func testPartialFetchFaultsOmittedPropertiesOnAccess() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("partial-fault"))
        let context = container.mainContext
        let original = PersistenceTestModel(title: "partial")
        original.count = 37
        context.insert(original)
        try context.save()

        let reader = container.makeContext()
        let descriptor = FetchDescriptor<PersistenceTestModel>(
            includePendingChanges: false, propertiesToFetch: [\.title])
        let fetched = try XCTUnwrap(reader.fetch(descriptor).first)
        XCTAssertEqual(fetched.title, "partial")
        XCTAssertEqual(fetched.count, 37)
        XCTAssertFalse(fetched.hasChanges)
    }

    @MainActor
    func testPartialFetchPreservesValuesAlreadyLoadedInIdentityMap() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("partial-fault-identity"))
        let writer = container.mainContext
        let model = PersistenceTestModel(title: "identity")
        model.count = 11
        writer.insert(model)
        try writer.save()

        let reader = container.makeContext()
        let full = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        let partial = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<PersistenceTestModel>(includePendingChanges: false, propertiesToFetch: [\.title])
            ).first)
        XCTAssertTrue(full === partial)
        full.count = 29
        XCTAssertEqual(partial.count, 29)
        XCTAssertTrue(partial.hasChanges)
    }

    @MainActor
    func testUniqueInsertUpsertsAndRebindsIdentityMap() throws {
        let container = try ModelContainer(
            for: FailedWritePersistenceFixture.self, configurations: .sqliteMemory("unique-upsert"))
        let context = container.mainContext
        let original = FailedWritePersistenceFixture(key: "same-key")
        context.insert(original)
        try context.save()
        let originalID = original.persistentModelID
        XCTAssertTrue(try context.model(for: originalID) as FailedWritePersistenceFixture? === original)

        let replacement = FailedWritePersistenceFixture(key: "same-key")
        context.insert(replacement)
        try context.save()

        XCTAssertEqual(replacement.persistentModelID, originalID)
        XCTAssertNil(original.modelContext)
        XCTAssertTrue(try context.model(for: originalID) as FailedWritePersistenceFixture? === replacement)
        let reader = container.makeContext()
        let fetched = try reader.fetch(FetchDescriptor<FailedWritePersistenceFixture>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].key, "same-key")
    }

    @MainActor
    func testUniqueUpsertPersistsRelationshipToDestinationInsertedInSameSave() throws {
        let container = try ModelContainer(
            for: UpsertRelationshipOwnerFixture.self, UpsertRelationshipDestinationFixture.self,
            configurations: .sqliteMemory("unique-upsert-relationship"))
        let context = container.mainContext
        let original = UpsertRelationshipOwnerFixture(key: "same-owner")
        context.insert(original)
        try context.save()

        let replacement = UpsertRelationshipOwnerFixture(key: "same-owner")
        let destination = UpsertRelationshipDestinationFixture(name: "new destination")
        context.insert(replacement)
        replacement.destination = destination
        try context.save()

        let ownerPK = try XCTUnwrap(replacement.persistentModelID.primaryKey)
        let destinationPK = try XCTUnwrap(destination.persistentModelID.primaryKey)
        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_OPT, ZDESTINATION FROM ZUPSERTRELATIONSHIPOWNERFIXTURE WHERE Z_PK = ?",
                arguments: [.int(ownerPK)])
            XCTAssertEqual(rows.first, [.int(2), .int(destinationPK)])
        }
    }

    @MainActor
    func testConflictingUniqueMatchesFailAtomicallyAndRetainPendingInsert() throws {
        let container = try ModelContainer(
            for: ConflictingUniqueKeysFixture.self, configurations: .sqliteMemory("conflicting-unique-upsert"))
        let context = container.mainContext
        let first = ConflictingUniqueKeysFixture(email: "first@example.com", username: "first")
        let second = ConflictingUniqueKeysFixture(email: "second@example.com", username: "second")
        context.insert(first)
        context.insert(second)
        try context.save()

        let incoming = ConflictingUniqueKeysFixture(email: first.email, username: second.username)
        context.insert(incoming)
        XCTAssertThrowsError(try context.save()) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected conflicting unique matches, got \(error)")
            }
        }
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(incoming.hasChanges)
        XCTAssertTrue(incoming.persistentModelID.isTemporary)
        let reader = container.makeContext()
        let rows = try reader.fetch(FetchDescriptor<ConflictingUniqueKeysFixture>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.email)), ["first@example.com", "second@example.com"])
        XCTAssertEqual(Set(rows.map(\.username)), ["first", "second"])
    }

    @MainActor
    func testDirtyUpdatePreservesExternalChangeToUntouchedColumn() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("dirty-column-update"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "original")
        context.insert(model)
        try context.save()
        let pk = try XCTUnwrap(model.persistentModelID.primaryKey)

        try container.store?.write { connection in
            try connection.execute(
                "UPDATE ZPERSISTENCETESTMODEL SET ZCOUNT = ?, Z_OPT = Z_OPT + 1 WHERE Z_PK = ?",
                arguments: [.int(41), .int(pk)])
        }
        let reader = container.makeContext()
        let externallyRefreshed = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        XCTAssertEqual(externallyRefreshed.count, 41)
        externallyRefreshed.title = "local edit"
        try reader.save()

        let stored = try container.store?.read { connection in
            try connection.rows(
                "SELECT ZTITLE, ZCOUNT, Z_OPT FROM ZPERSISTENCETESTMODEL WHERE Z_PK = ?",
                arguments: [.int(pk)])
        }
        XCTAssertEqual(stored?.first, [.text("local edit"), .int(41), .int(3)])
    }

    @MainActor
    func testOptimisticLockConflictRollsBackAllRowsAndRetainsPendingChanges() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("optimistic-conflict"))
        let writer = container.mainContext
        let original = PersistenceTestModel(title: "initial")
        writer.insert(original)
        try writer.save()

        let firstContext = container.makeContext()
        let secondContext = container.makeContext()
        let first = try XCTUnwrap(firstContext.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        let second = try XCTUnwrap(secondContext.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        first.title = "first writer"
        try firstContext.save()
        second.title = "stale writer"
        let earlierInsert = PersistenceTestModel(title: "must roll back")
        secondContext.insert(earlierInsert)

        XCTAssertThrowsError(try secondContext.save()) { error in
            XCTAssertEqual(error as? SwiftDataError, .optimisticLockConflict)
        }
        XCTAssertTrue(secondContext.hasChanges)
        XCTAssertTrue(second.hasChanges)
        XCTAssertTrue(earlierInsert.persistentModelID.isTemporary)

        let reader = container.makeContext()
        let rows = try reader.fetch(FetchDescriptor<PersistenceTestModel>())
        XCTAssertEqual(rows.map(\.title), ["first writer"])
    }

    @MainActor
    func testOptimisticLockConflictRejectsStaleRelationshipOnlyWrite() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("stale-relationship-write"))
        let setup = container.mainContext
        let owner = PersistentRelationshipOwner(title: "owner")
        let child = PersistentRelationshipChild(title: "child")
        setup.insert(owner)
        setup.insert(child)
        try setup.save()

        let firstContext = container.makeContext()
        let staleContext = container.makeContext()
        let firstOwner = try XCTUnwrap(firstContext.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        let firstChild = try XCTUnwrap(firstContext.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        let staleOwner = try XCTUnwrap(staleContext.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        let staleChild = try XCTUnwrap(staleContext.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)

        firstOwner.children = [firstChild]
        try firstContext.save()
        staleOwner.favorite = staleChild

        XCTAssertThrowsError(try staleContext.save()) { error in
            XCTAssertEqual(error as? SwiftDataError, .optimisticLockConflict)
        }
        XCTAssertTrue(staleContext.hasChanges)
        XCTAssertTrue(staleOwner.hasChanges)
        XCTAssertTrue(staleOwner.favorite === staleChild)

        let reader = container.makeContext()
        let persisted = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(persisted.children.map(\.title), ["child"])
        XCTAssertNil(persisted.favorite)
    }

    @MainActor
    func testFreshContextFetchDecodesCanonicalAttributeOrderAndOptionalValues() throws {
        let container = try ModelContainer(
            for: ReverseOrderPersistenceFixture.self, configurations: .sqliteMemory("ordered-fetch"))
        let writer = container.mainContext
        let model = ReverseOrderPersistenceFixture(
            zebra: "z-value", alpha: 42, middle: "middle-value", optionalValue: "optional-value")
        writer.insert(model)
        try writer.save()
        XCTAssertEqual(model.optionalValue, "optional-value")

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<ReverseOrderPersistenceFixture>()).first)
        XCTAssertEqual(
            ReverseOrderPersistenceFixture.persistenceAdapters().map(\.name).sorted(),
            ["alpha", "middle", "optionalValue", "zebra"])
        XCTAssertEqual(fetched.zebra, "z-value")
        XCTAssertEqual(fetched.alpha, 42)
        XCTAssertEqual(fetched.middle, "middle-value")
        XCTAssertEqual(fetched.optionalValue, "optional-value")

        let nilModel = ReverseOrderPersistenceFixture(
            zebra: "nil-z", alpha: 7, middle: "nil-middle", optionalValue: nil)
        writer.insert(nilModel)
        try writer.save()

        let nilReader = container.makeContext()
        let fetchedNil = try XCTUnwrap(
            nilReader.fetch(FetchDescriptor<ReverseOrderPersistenceFixture>()).first {
                $0.alpha == 7
            })
        XCTAssertNil(fetchedNil.optionalValue)
    }

    @MainActor
    func testFreshContextUpdateAndRollbackRestoreStoreValue() throws {
        let container = try ModelContainer(for: PersistenceTestModel.self, configurations: .sqliteMemory("update-test"))
        let first = container.mainContext
        let model = PersistenceTestModel(title: "before")
        first.insert(model)
        try first.save()

        let second = container.makeContext()
        let fetched = try XCTUnwrap(second.fetch(FetchDescriptor<PersistenceTestModel>()).first)
        fetched.title = "after"
        try second.save()
        fetched.title = "discarded"
        second.rollback()
        XCTAssertEqual(fetched.title, "after")
        XCTAssertFalse(second.hasChanges)
    }

    @MainActor
    func testRollbackKeepsSavedBaselineAcrossMultipleMutations() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("rollback-saved-baseline"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "A")
        context.insert(model)
        try context.save()

        model.title = "B"
        context.rollback()
        XCTAssertEqual(model.title, "A")

        model.title = "C"
        context.rollback()
        XCTAssertEqual(model.title, "A")
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testUpdateOfExternallyDeletedRowFailsAndRetainsPendingState() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("missing-update-row"))
        let model = PersistenceTestModel(title: "initial")
        container.mainContext.insert(model)
        try container.mainContext.save()
        let identifier = model.persistentModelID
        let wasChanged = model.hasChanges

        try container.store?.write { connection in
            guard let pk = identifier.primaryKey else { throw SwiftDataError.unsupportedStore("Missing key") }
            try connection.execute(
                "DELETE FROM ZPERSISTENCETESTMODEL WHERE Z_PK = ?", arguments: [.int(pk)])
        }
        model.title = "pending update"

        XCTAssertThrowsError(try container.mainContext.save())
        XCTAssertEqual(model.title, "pending update")
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertFalse(model.persistentModelID.isTemporary)
        XCTAssertFalse(wasChanged)
    }

    @MainActor
    func testSavedDeleteRemovesIdentityMapEntry() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("delete-identity"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "deleted")
        context.insert(model)
        try context.save()
        let identifier = model.persistentModelID

        context.delete(model)
        try context.save()

        XCTAssertNil(try context.model(for: identifier) as PersistenceTestModel?)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PersistenceTestModel>()).isEmpty)
    }

    @MainActor
    func testModelLookupRejectsForeignStoreAndMismatchedEntity() throws {
        let first = try ModelContainer(for: PersistenceTestModel.self, configurations: .sqliteMemory("lookup-one"))
        let second = try ModelContainer(for: PersistenceTestModel.self, configurations: .sqliteMemory("lookup-two"))
        let model = PersistenceTestModel(title: "saved")
        first.mainContext.insert(model)
        try first.mainContext.save()

        XCTAssertThrowsError(try second.mainContext.model(for: model.persistentModelID) as PersistenceTestModel?)
        XCTAssertThrowsError(
            try first.mainContext.model(for: model.persistentModelID) as ReverseOrderPersistenceFixture?)
    }

    @MainActor
    func testRollbackRestoresDetachedIdentityAndClearsManagedMetadata() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("detach-rollback"))
        let context = container.mainContext
        let model = PersistenceTestModel(title: "pending")
        let detachedID = model.persistentModelID
        context.insert(model)
        model.title = "changed"

        context.rollback()

        XCTAssertNil(model.modelContext)
        XCTAssertEqual(model.persistentModelID, detachedID)
        XCTAssertEqual(model.persistentModelID.storeIdentifier, "OSD.Detached")
        XCTAssertTrue(model.persistentModelID.isTemporary)
        XCTAssertEqual(model.title, "pending")
        XCTAssertFalse(model.hasChanges)
    }

    @MainActor
    func testFailedAtomicWriteRollsBackEarlierInsertAndRetainsPendingChanges() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, FailedWritePersistenceFixture.self,
            configurations: .sqliteMemory("atomic-failure"))
        let context = container.mainContext
        let duplicate = FailedWritePersistenceFixture(key: "duplicate")
        context.insert(duplicate)
        try context.save()

        let valid = PersistenceTestModel(title: "partial")
        context.insert(valid)
        let identifier = valid.persistentModelID
        try container.store?.write { connection in
            try connection.execute(
                "CREATE TRIGGER fail_atomic_insert BEFORE INSERT ON ZPERSISTENCETESTMODEL "
                    + "BEGIN SELECT RAISE(ABORT, 'atomic failure'); END;", arguments: [])
        }

        XCTAssertThrowsError(try context.save())
        XCTAssertEqual(valid.persistentModelID, identifier)
        XCTAssertTrue(valid.persistentModelID.isTemporary)
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(valid.hasChanges)

        let reader = container.makeContext()
        XCTAssertTrue(try reader.fetch(FetchDescriptor<PersistenceTestModel>()).isEmpty)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<FailedWritePersistenceFixture>()).count, 1)
        try container.store?.write { connection in
            try connection.execute("DROP TRIGGER fail_atomic_insert", arguments: [])
        }
    }

    @MainActor
    func testToOneAndToManyRelationshipsRoundTripWithInverseReconstruction() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("relationship-round-trip"))
        let ownerRelationship = try XCTUnwrap(
            container.schema.entity(forName: "PersistentRelationshipOwner")?.relationships.first {
                $0.name == "children"
            })
        let childRelationship = try XCTUnwrap(
            container.schema.entity(forName: "PersistentRelationshipChild")?.relationships.first { $0.name == "owner" })
        XCTAssertTrue(ownerRelationship.isToMany)
        XCTAssertFalse(childRelationship.isToMany)
        XCTAssertEqual(ownerRelationship.inverse, "owner")
        XCTAssertEqual(childRelationship.inverse, "children")
        let owner = PersistentRelationshipOwner(title: "owner")
        let first = PersistentRelationshipChild(title: "first")
        let second = PersistentRelationshipChild(title: "second")
        container.mainContext.insert(owner)
        owner.children = [second, first]
        owner.favorite = first
        try container.mainContext.save()
        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(fetchedOwner.children.map(\.title), ["first", "second"])
        XCTAssertTrue(fetchedOwner.children.allSatisfy { $0.owner?.title == fetchedOwner.title })
        XCTAssertEqual(fetchedOwner.favorite?.title, "first")
        XCTAssertEqual(
            fetchedOwner.children.first { $0.title == "first" }?.persistentModelID,
            fetchedOwner.favorite?.persistentModelID)
        XCTAssertFalse(
            reader.hasChanges,
            "Reader pending: inserted=\(reader.insertedModelsArray.count), changed=\(reader.changedModelsArray.count), "
                + "relationshipMutations=\(reader.state.relationshipMutations.count), changedModels="
                + "\(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })")
        XCTAssertFalse(fetchedOwner.hasChanges)
        XCTAssertTrue(
            fetchedOwner.children.allSatisfy { !$0.hasChanges },
            "Fetched children: \(fetchedOwner.children.map { ($0.title, $0.persistentModelID, $0.hasChanges, $0.owner?.title as Any) })"
        )
    }

    @MainActor
    func testBatchedRelationshipFetchHandlesMoreThanSQLiteVariableLimit() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("batched-relationship-fetch"))
        for index in 0..<1_005 {
            container.mainContext.insert(PersistentTagGroup(name: "group-\(index)"))
        }
        try container.mainContext.save()

        let reader = container.makeContext()
        let groups = try reader.fetch(FetchDescriptor<PersistentTagGroup>(includePendingChanges: false))
        XCTAssertEqual(groups.count, 1_005)
        XCTAssertTrue(groups.allSatisfy(\.tags.isEmpty))
    }

    @MainActor
    func testBatchedRelationshipFaultingLoadsPopulatedSiblingsInHundredRowChunks() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("populated-batched-relationship-fetch"))
        let writer = container.mainContext
        for index in 0..<205 {
            let group = PersistentTagGroup(name: "group-\(index)")
            let tag = PersistentTag(name: "tag-\(index)")
            writer.insert(group)
            group.tags = [tag]
        }
        try writer.save()

        let reader = container.makeContext()
        let descriptor = FetchDescriptor<PersistentTagGroup>(
            includePendingChanges: false, relationshipKeyPathsForPrefetching: [\.tags])
        let groups = try reader.fetch(descriptor)

        XCTAssertEqual(groups.count, 205)
        for (index, group) in groups.enumerated() {
            let tag = try XCTUnwrap(group.tags.first)
            XCTAssertEqual(tag.name, "tag-\(index)")
            XCTAssertEqual(tag.groups.map(\.persistentModelID), [group.persistentModelID])
            XCTAssertFalse(group.hasChanges)
            XCTAssertFalse(tag.hasChanges)
        }
        XCTAssertFalse(reader.hasChanges)
    }

    @MainActor
    func testManyToManyRoundTripUsesStablePrimaryKeyOrdering() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-round-trip"))
        let group = PersistentTagGroup(name: "group")
        let third = PersistentTag(name: "third")
        let first = PersistentTag(name: "first")
        let second = PersistentTag(name: "second")
        container.mainContext.insert(third)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        container.mainContext.insert(group)
        group.tags = [third, first, second]
        try container.mainContext.save()
        let storedTagIDs = [third, first, second].compactMap { $0.persistentModelID.primaryKey }
        let storedGroupID = try XCTUnwrap(group.persistentModelID.primaryKey)
        XCTAssertEqual(storedTagIDs.count, 3)
        XCTAssertEqual(Set(storedTagIDs).count, 3)
        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS ORDER BY Z_A, Z_B",
                arguments: [])
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows.map(\.first), storedTagIDs.sorted().map { Optional(RuntimeValue.int($0)) })
            XCTAssertTrue(rows.allSatisfy { $0.last == .int(storedGroupID) })
        }
        let reader = container.makeContext()
        let prefetch = FetchDescriptor<PersistentTagGroup>(relationshipKeyPathsForPrefetching: [\.tags])
        let fetched = try XCTUnwrap(reader.fetch(prefetch).first)
        XCTAssertEqual(fetched.tags.count, 3)
        XCTAssertEqual(Set(fetched.tags.map(\.name)), Set(["first", "second", "third"]))
        XCTAssertEqual(fetched.tags.compactMap(\.persistentModelID.primaryKey), storedTagIDs.sorted())
        let primaryKeys = try fetched.tags.map { tag in
            try XCTUnwrap(tag.persistentModelID.primaryKey)
        }
        XCTAssertEqual(primaryKeys, primaryKeys.sorted())
        for tag in fetched.tags {
            XCTAssertEqual(tag.groups.map(\.name), ["group"])
            XCTAssertEqual(tag.groups.first?.persistentModelID, fetched.persistentModelID)
        }
        XCTAssertFalse(
            reader.hasChanges,
            "Tag fetch pending: \(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })"
        )
        XCTAssertFalse(fetched.hasChanges)
        XCTAssertTrue(fetched.tags.allSatisfy { !$0.hasChanges })
    }

    @MainActor
    func testManyToManyIndependentFetchFromEitherEndpoint() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-either-endpoint"))
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        group.tags = [tag]
        XCTAssertEqual(group.tags.map(\.name), ["tag"])
        container.mainContext.insert(group)
        container.mainContext.insert(tag)
        XCTAssertEqual(group.tags.map(\.name), ["tag"])
        try container.mainContext.save()
        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS", arguments: [])
            XCTAssertEqual(rows.count, 1)
        }
        let tagReader = container.makeContext()
        let fetchedTag = try XCTUnwrap(tagReader.fetch(FetchDescriptor<PersistentTag>()).first)
        XCTAssertEqual(fetchedTag.groups.map(\.name), ["group"])
        XCTAssertFalse(fetchedTag.hasChanges)
        XCTAssertTrue(fetchedTag.groups.allSatisfy { !$0.hasChanges })
        XCTAssertFalse(tagReader.hasChanges)

        let groupReader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(groupReader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetchedGroup.tags.map(\.name), ["tag"])
        XCTAssertFalse(groupReader.hasChanges)
    }

    @MainActor
    func testManyToManyInitialAssignmentBeforeBothInsertionsPersistsOnce() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-initial-assignment"))
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        group.tags = [tag]
        container.mainContext.insert(group)
        container.mainContext.insert(tag)
        try container.mainContext.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS", arguments: [])
            XCTAssertEqual(rows.count, 1)
        }
        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetchedGroup.tags.map(\.name), ["tag"])
    }

    @MainActor
    func testDirtyRegisteredRelationshipOwnerKeepsEditedValueDuringFetch() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("dirty-owner-fetch"))
        let writer = container.mainContext
        let owner = PersistentRelationshipOwner(title: "owner")
        let savedChild = PersistentRelationshipChild(title: "saved")
        writer.insert(owner)
        writer.insert(savedChild)
        owner.children = [savedChild]
        try writer.save()

        let context = container.makeContext()
        let fetchedOwner = try XCTUnwrap(context.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        let editedChild = PersistentRelationshipChild(title: "edited")
        context.insert(editedChild)
        fetchedOwner.children = [editedChild]

        let fetchedAgain = try XCTUnwrap(context.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertTrue(fetchedAgain === fetchedOwner)
        XCTAssertEqual(fetchedAgain.children.map(\.title), ["edited"])
        XCTAssertTrue(fetchedAgain.hasChanges)
        XCTAssertTrue(context.hasChanges)
    }

    @MainActor
    func testInsertedRelationshipsUseSinglePersistencePlanWithAssignedIDs() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("inserted-relationship-values"))
        let context = container.mainContext
        let child = PersistentRelationshipChild(title: "initial child")
        context.insert(child)
        let owner = PersistentRelationshipOwner(title: "initial owner")
        owner.favorite = child
        context.insert(owner)

        try context.save()

        XCTAssertFalse(owner.persistentModelID.isTemporary)
        XCTAssertFalse(child.persistentModelID.isTemporary)
        try container.store?.read { connection in
            let ownerPK = try XCTUnwrap(owner.persistentModelID.primaryKey)
            let childPK = try XCTUnwrap(child.persistentModelID.primaryKey)
            let favoriteRows = try connection.rows(
                "SELECT ZFAVORITE FROM ZPERSISTENTRELATIONSHIPOWNER WHERE Z_PK = ?",
                arguments: [.int(ownerPK)])
            XCTAssertEqual(favoriteRows.first?.first, .int(childPK))
        }
    }

    @MainActor
    func testInsertedRelationshipSetterChangesPersistLatestValueInSameTransaction() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("inserted-relationship-mutation"))
        let context = container.mainContext
        let initial = PersistentRelationshipChild(title: "initial")
        let replacement = PersistentRelationshipChild(title: "replacement")
        let owner = PersistentRelationshipOwner(title: "owner")
        owner.favorite = initial
        owner.children = [initial]
        context.insert(owner)
        context.insert(initial)
        owner.favorite = replacement
        owner.children = [replacement]

        try context.save()

        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(fetchedOwner.favorite?.title, "replacement")
        XCTAssertEqual(fetchedOwner.children.map(\.title), ["replacement"])
        XCTAssertFalse(initial.persistentModelID.isTemporary)
        XCTAssertFalse(replacement.persistentModelID.isTemporary)
    }

    @MainActor
    func testRelationshipAndAttributeWriteRollbackIsAtomicAndRetainsPendingState() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("relationship-atomicity"))
        let context = container.mainContext
        let owner = PersistentRelationshipOwner(title: "before")
        let child = PersistentRelationshipChild(title: "child")
        context.insert(child)
        context.insert(owner)
        try context.save()

        owner.title = "pending"
        owner.children = [child]
        try container.store?.write { connection in
            try connection.execute(
                "CREATE TRIGGER reject_relationship_update "
                    + "BEFORE UPDATE OF ZOWNER ON ZPERSISTENTRELATIONSHIPCHILD "
                    + "BEGIN SELECT RAISE(ABORT, 'relationship failure'); END;", arguments: [])
        }

        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(owner.hasChanges)
        XCTAssertEqual(owner.title, "pending")
        XCTAssertTrue(owner.children.first === child)
        XCTAssertTrue(child.modelContext === context)

        try container.store?.write { connection in
            try connection.execute("DROP TRIGGER reject_relationship_update", arguments: [])
        }
        let reader = container.makeContext()
        let persisted = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(persisted.title, "before")
        XCTAssertTrue(persisted.children.isEmpty)

        try context.save()
        let savedReader = container.makeContext()
        let saved = try XCTUnwrap(savedReader.fetch(FetchDescriptor<PersistentRelationshipOwner>()).first)
        XCTAssertEqual(saved.title, "pending")
        XCTAssertEqual(saved.children.map(\.title), ["child"])
    }

    @MainActor
    func testManyToManyMutationThroughInversePersistsFromStorageOwner() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-inverse-mutation"))
        let context = container.mainContext
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        context.insert(group)
        context.insert(tag)

        tag.groups = [group]
        try context.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS", arguments: [])
            XCTAssertEqual(rows.count, 1)
        }
        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertEqual(fetchedGroup.tags.map(\.name), ["tag"])
    }

    @MainActor
    func testManyToManyInverseMutationPreservesUnchangedPairs() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-inverse-preserve"))
        let context = container.mainContext
        let firstGroup = PersistentTagGroup(name: "first")
        let secondGroup = PersistentTagGroup(name: "second")
        let firstTag = PersistentTag(name: "first")
        let secondTag = PersistentTag(name: "second")
        context.insert(firstGroup)
        context.insert(secondGroup)
        context.insert(firstTag)
        context.insert(secondTag)
        firstGroup.tags = [firstTag, secondTag]
        try context.save()

        firstTag.groups = [secondGroup]
        XCTAssertEqual(firstTag.groups.map(\.name), ["second"])
        XCTAssertEqual(secondTag.groups.map(\.name), ["first"])
        XCTAssertEqual(firstGroup.tags.map(\.name), ["second"])
        XCTAssertEqual(secondGroup.tags.map(\.name), ["first"])
        try context.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS ORDER BY Z_A, Z_B",
                arguments: [])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(
                rows.map {
                    $0.compactMap { value -> Int64? in
                        if case let .int(number) = value { return number }
                        return nil
                    }
                },
                [
                    [
                        try XCTUnwrap(firstTag.persistentModelID.primaryKey),
                        try XCTUnwrap(secondGroup.persistentModelID.primaryKey),
                    ],
                    [
                        try XCTUnwrap(secondTag.persistentModelID.primaryKey),
                        try XCTUnwrap(firstGroup.persistentModelID.primaryKey),
                    ],
                ])
        }
    }

    @MainActor
    func testManyToManyMutationsFromBothOrientationsPersistOneConsistentGraph() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-mixed-orientations"))
        let context = container.mainContext
        let firstGroup = PersistentTagGroup(name: "first")
        let secondGroup = PersistentTagGroup(name: "second")
        let firstTag = PersistentTag(name: "first")
        let secondTag = PersistentTag(name: "second")
        context.insert(firstGroup)
        context.insert(secondGroup)
        context.insert(firstTag)
        context.insert(secondTag)
        firstGroup.tags = [firstTag]
        secondGroup.tags = [secondTag]
        try context.save()

        firstGroup.tags = [secondTag]
        firstTag.groups = [secondGroup]
        try context.save()

        try container.store?.read { connection in
            let rows = try connection.rows(
                "SELECT Z_A, Z_B FROM Z_PERSISTENTTAG_GROUPS_PERSISTENTTAGGROUP_TAGS ORDER BY Z_A, Z_B",
                arguments: [])
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(
                rows.map {
                    $0.compactMap { value -> Int64? in
                        if case let .int(number) = value { return number }
                        return nil
                    }
                },
                [
                    [
                        try XCTUnwrap(firstTag.persistentModelID.primaryKey),
                        try XCTUnwrap(secondGroup.persistentModelID.primaryKey),
                    ],
                    [
                        try XCTUnwrap(secondTag.persistentModelID.primaryKey),
                        try XCTUnwrap(firstGroup.persistentModelID.primaryKey),
                    ],
                    [
                        try XCTUnwrap(secondTag.persistentModelID.primaryKey),
                        try XCTUnwrap(secondGroup.persistentModelID.primaryKey),
                    ],
                ])
        }

        let reader = container.makeContext()
        let groups = try reader.fetch(FetchDescriptor<PersistentTagGroup>())
        XCTAssertEqual(groups.first { $0.name == "first" }?.tags.map(\.name), ["second"])
        XCTAssertEqual(groups.first { $0.name == "second" }?.tags.map(\.name), ["first", "second"])
        XCTAssertFalse(
            reader.hasChanges,
            "Mixed M2M fetch pending: \(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })"
        )
        let tags = try reader.fetch(FetchDescriptor<PersistentTag>())
        XCTAssertEqual(tags.first { $0.name == "first" }?.groups.map(\.name), ["second"])
        XCTAssertEqual(tags.first { $0.name == "second" }?.groups.map(\.name), ["first", "second"])
        XCTAssertFalse(
            reader.hasChanges,
            "Mixed M2M fetch pending: \(reader.changedModelsArray.map { (String(describing: type(of: $0)), $0.persistentModelID) })"
        )
    }

    @MainActor
    func testManyToManyRemovalThroughInversePersistsEmptyStorageOwnerCollection() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-inverse-removal"))
        let context = container.mainContext
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        context.insert(group)
        context.insert(tag)
        group.tags = [tag]
        try context.save()

        tag.groups.removeAll()
        try context.save()

        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertTrue(fetchedGroup.tags.isEmpty)
    }

    @MainActor
    func testDeletingManyToManyEndpointCleansUpJoinRelationship() throws {
        let container = try ModelContainer(
            for: PersistentTagGroup.self, PersistentTag.self,
            configurations: .sqliteMemory("many-to-many-delete-endpoint"))
        let context = container.mainContext
        let group = PersistentTagGroup(name: "group")
        let tag = PersistentTag(name: "tag")
        context.insert(group)
        context.insert(tag)
        group.tags = [tag]
        try context.save()

        context.delete(tag)
        try context.save()

        let reader = container.makeContext()
        let fetchedGroup = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentTagGroup>()).first)
        XCTAssertTrue(fetchedGroup.tags.isEmpty)
        XCTAssertTrue(try reader.fetch(FetchDescriptor<PersistentTag>()).isEmpty)
    }

    @MainActor
    func testDeletingOneToManyDestinationNullifiesPersistedForeignKey() throws {
        let container = try ModelContainer(
            for: PersistentRelationshipOwner.self, PersistentRelationshipChild.self,
            configurations: .sqliteMemory("one-to-many-delete-nullify"))
        let context = container.mainContext
        let owner = PersistentRelationshipOwner(title: "owner")
        let child = PersistentRelationshipChild(title: "child")
        context.insert(owner)
        context.insert(child)
        child.owner = owner
        try context.save()
        XCTAssertEqual(owner.children.map(\.title), ["child"])
        XCTAssertTrue(child.owner === owner)

        context.delete(owner)
        try context.save()

        try container.store?.read { connection in
            let childPK = try XCTUnwrap(child.persistentModelID.primaryKey)
            let rows = try connection.rows(
                "SELECT ZOWNER FROM ZPERSISTENTRELATIONSHIPCHILD WHERE Z_PK = ?", arguments: [.int(childPK)])
            XCTAssertEqual(rows.first?.first, .null)
        }
        let reader = container.makeContext()
        let fetchedChild = try XCTUnwrap(reader.fetch(FetchDescriptor<PersistentRelationshipChild>()).first)
        XCTAssertNil(fetchedChild.owner)
        XCTAssertFalse(reader.hasChanges)
    }
}

final class IdentityMapConcurrencyTests: XCTestCase {
    func testConcurrentCanonicalRegistrationReturnsOneLiveModel() {
        let map = IdentityMap()
        let key = EntityPrimaryKey(entityName: "PersistenceTestModel", primaryKey: 42)
        let handles = IdentityMapHandles()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let candidate = PersistenceTestModel(title: "candidate-\(index)")
            let handle = map.canonicalHandle(for: key, candidate: candidate)
            handles.append(handle)
        }

        XCTAssertEqual(Set(handles.values.map { ObjectIdentifier($0.model) }).count, 1)
    }
}

final class StoreHubTests: XCTestCase {
    func testPublishedChangeSetsHaveIncreasingGenerations() throws {
        let store = StoreHubTestStore()
        let hub = StoreHub()
        let inbox = ChangeInbox()
        let subscription = hub.subscribe(inbox)
        let key = StoreEntityKey(entityName: "Item", primaryKey: 7)

        hub.publish(
            storeIdentifier: ObjectIdentifier(store), sourceSubscription: subscription,
            inserted: [key], updated: [], deleted: [])
        hub.publish(
            storeIdentifier: ObjectIdentifier(store), sourceSubscription: subscription,
            inserted: [], updated: [key], deleted: [])

        let changes = inbox.drain()
        XCTAssertEqual(changes.map(\.generation), [1, 2])
        XCTAssertEqual(changes[0].inserted, [key])
        XCTAssertEqual(changes[1].updated, [key])
    }

    func testStoresWithoutDataVersionDoNotEnableExternalPolling() throws {
        XCTAssertNil(try StoreHubTestStore().dataVersion())
    }
}

final class AutosaveTriggerTests: XCTestCase {
    func testCoalescesChangesAtOneHundredMillisecondsAndReschedulesAfterFire() {
        let scheduler = TestAutosaveScheduler()
        let trigger = AutosaveTrigger(scheduler: scheduler)
        let actions = AutosaveActionCounter()

        trigger.scheduleIfNeeded { actions.increment() }
        trigger.scheduleIfNeeded { actions.increment() }
        XCTAssertEqual(scheduler.scheduledDelays, [.milliseconds(100)])
        scheduler.fireNext()
        XCTAssertEqual(actions.value, 1)

        trigger.scheduleIfNeeded { actions.increment() }
        XCTAssertEqual(scheduler.scheduledDelays, [.milliseconds(100), .milliseconds(100)])
        scheduler.fireNext()
        XCTAssertEqual(actions.value, 2)
    }

    func testCancellationPreventsPendingAutosaveAction() {
        let scheduler = TestAutosaveScheduler()
        let trigger = AutosaveTrigger(scheduler: scheduler)
        let actions = AutosaveActionCounter()

        trigger.scheduleIfNeeded { actions.increment() }
        trigger.cancel()
        scheduler.fireNext()
        XCTAssertEqual(actions.value, 0)
    }

    func testDisablingAutosaveSerializesWithConcurrentScheduling() {
        let scheduler = BlockingAutosaveScheduler()
        let trigger = AutosaveTrigger(scheduler: scheduler)
        let actions = AutosaveActionCounter()
        let handle = AutosaveHandle(trigger: trigger, enabled: true, schedule: { actions.increment() })
        let scheduled = DispatchSemaphore(value: 0)
        let resumeSchedule = DispatchSemaphore(value: 0)
        let disableCompleted = DispatchSemaphore(value: 0)
        scheduler.onSchedule = {
            scheduled.signal()
            _ = resumeSchedule.wait(timeout: .now() + 2)
        }

        let scheduling = DispatchQueue(label: "autosave.schedule")
        let disabling = DispatchQueue(label: "autosave.disable")
        scheduling.async { handle.changed() }
        XCTAssertEqual(scheduled.wait(timeout: .now() + 2), .success)
        disabling.async {
            handle.setEnabled(false)
            disableCompleted.signal()
        }
        resumeSchedule.signal()
        XCTAssertEqual(scheduler.completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(disableCompleted.wait(timeout: .now() + 2), .success)
        scheduler.firePending()

        XCTAssertEqual(actions.value, 0)
    }

    @MainActor
    func testModelContextAutosavesAfterInjectedDelay() async throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("injected-autosave"))
        let scheduler = TestAutosaveScheduler()
        let context = ModelContext(container: container, autosaveEnabled: true, autosaveScheduler: scheduler)
        let model = PersistenceTestModel(title: "before")
        context.insert(model)

        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(scheduler.scheduledDelays, [.milliseconds(100)])
        scheduler.fireNext()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PersistenceTestModel>()).map(\.title), ["before"])
    }

    @MainActor
    func testDisablingAutosaveAfterTimerFiresPreventsQueuedSave() async throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("cancel-queued-autosave"))
        let scheduler = TestAutosaveScheduler()
        let context = ModelContext(container: container, autosaveEnabled: true, autosaveScheduler: scheduler)
        context.insert(PersistenceTestModel(title: "pending"))
        scheduler.fireNext()
        context.autosaveEnabled = false
        XCTAssertFalse(context.autosaveEnabled)
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(context.hasChanges)
        let storedRows = try container.store?.read {
            try $0.rows("SELECT COUNT(*) FROM ZPERSISTENCETESTMODEL", arguments: [])
        }
        XCTAssertEqual(storedRows, [[.int(0)]])
    }

    @MainActor
    func testSaveNotificationsCarryCommittedIdentifiersInOrder() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("save-notifications"))
        let context = container.mainContext
        let inserted = PersistenceTestModel(title: "inserted")
        context.insert(inserted)
        let temporaryID = inserted.persistentModelID
        let recorder = SaveNotificationRecorder()
        let will = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) {
            recorder.append(name: ModelContext.willSave, notification: $0)
        }
        let did = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) {
            recorder.append(name: ModelContext.didSave, notification: $0)
        }
        defer {
            NotificationCenter.default.removeObserver(will)
            NotificationCenter.default.removeObserver(did)
        }

        try context.save()

        let events = recorder.events
        XCTAssertEqual(events.map(\.name), [ModelContext.willSave, ModelContext.didSave])
        XCTAssertTrue(events.allSatisfy { $0.objectIdentifier == ObjectIdentifier(context) })
        let willInserted = events[0].inserted
        let didInserted = events[1].inserted
        XCTAssertEqual(willInserted, [temporaryID])
        XCTAssertEqual(didInserted, [inserted.persistentModelID])
        XCTAssertNotEqual(didInserted.first, temporaryID)
        XCTAssertTrue(events.allSatisfy { $0.updated.isEmpty && $0.deleted.isEmpty })
        XCTAssertEqual(ModelContext.NotificationKey.insertedIdentifiers.rawValue, "insertedIdentifiers")
        XCTAssertEqual(ModelContext.NotificationKey.updatedIdentifiers.rawValue, "updatedIdentifiers")
        XCTAssertEqual(ModelContext.NotificationKey.deletedIdentifiers.rawValue, "deletedIdentifiers")
    }

    @MainActor
    func testFailedSavePostsWillSaveButNotDidSave() throws {
        let container = try ModelContainer(
            for: PersistenceTestModel.self, configurations: .sqliteMemory("failed-save-notifications"))
        try container.store?.write { connection in
            try connection.execute(
                "CREATE TRIGGER FAIL_NOTIFICATION_TEST BEFORE INSERT ON ZPERSISTENCETESTMODEL "
                    + "BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
                arguments: [])
        }
        let context = container.mainContext
        context.insert(PersistenceTestModel(title: "rejected"))
        let recorder = SaveNotificationRecorder()
        let will = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) {
            notification in recorder.append(name: ModelContext.willSave, notification: notification)
        }
        let did = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) {
            notification in recorder.append(name: ModelContext.didSave, notification: notification)
        }
        defer {
            NotificationCenter.default.removeObserver(will)
            NotificationCenter.default.removeObserver(did)
        }

        XCTAssertThrowsError(try context.save())

        XCTAssertEqual(recorder.events.map(\.name), [ModelContext.willSave])
        XCTAssertTrue(context.hasChanges)
    }
}

private final class SaveNotificationRecorder: @unchecked Sendable {
    struct Event: Sendable {
        let name: Notification.Name
        let objectIdentifier: ObjectIdentifier?
        let inserted: [PersistentIdentifier]
        let updated: [PersistentIdentifier]
        let deleted: [PersistentIdentifier]
    }

    private let lock = NSLock()
    private var storage: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(name: Notification.Name, notification: Notification) {
        let event = Event(
            name: name,
            objectIdentifier: (notification.object as AnyObject?).map(ObjectIdentifier.init),
            inserted: notification.userInfo?[ModelContext.NotificationKey.insertedIdentifiers.rawValue]
                as? [PersistentIdentifier] ?? [],
            updated: notification.userInfo?[ModelContext.NotificationKey.updatedIdentifiers.rawValue]
                as? [PersistentIdentifier] ?? [],
            deleted: notification.userInfo?[ModelContext.NotificationKey.deletedIdentifiers.rawValue]
                as? [PersistentIdentifier] ?? [])
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private final class TestAutosaveScheduler: AutosaveScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [(Duration, TestAutosaveWorkItem)] = []
    private var history: [Duration] = []

    var scheduledDelays: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    func schedule(after delay: Duration, _ action: @escaping @Sendable () -> Void) -> AutosaveCancellation {
        let item = TestAutosaveWorkItem(action)
        lock.lock()
        scheduled.append((delay, item))
        history.append(delay)
        lock.unlock()
        return item
    }

    func fireNext() {
        lock.lock()
        guard !scheduled.isEmpty else {
            lock.unlock()
            XCTFail("No scheduled autosave action")
            return
        }
        let item = scheduled.removeFirst().1
        lock.unlock()
        item.fire()
    }
}

private final class BlockingAutosaveScheduler: AutosaveScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: TestAutosaveWorkItem?
    private var scheduleObserver: (@Sendable () -> Void)?
    let completed = DispatchSemaphore(value: 0)

    var onSchedule: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return scheduleObserver
        }
        set {
            lock.lock()
            scheduleObserver = newValue
            lock.unlock()
        }
    }

    func schedule(after delay: Duration, _ action: @escaping @Sendable () -> Void) -> AutosaveCancellation {
        let item = TestAutosaveWorkItem(action)
        lock.lock()
        pending = item
        let observer = scheduleObserver
        lock.unlock()
        observer?()
        completed.signal()
        return item
    }

    func firePending() {
        lock.lock()
        let item = pending
        pending = nil
        lock.unlock()
        item?.fire()
    }
}

private final class TestAutosaveWorkItem: AutosaveCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func cancel() {
        lock.lock()
        action = nil
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

private final class AutosaveActionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class StoreHubTestStore: RuntimeStore, @unchecked Sendable {
    func read<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only store")
    }

    func write<T>(_ body: (RuntimeConnection) throws -> T) throws -> T {
        throw SwiftDataError.unsupportedStore("test-only store")
    }

    func close() throws {}
}

private final class IdentityMapHandles: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IdentityMap.ModelHandle] = []

    var values: [IdentityMap.ModelHandle] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ handle: IdentityMap.ModelHandle) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(handle)
    }
}
