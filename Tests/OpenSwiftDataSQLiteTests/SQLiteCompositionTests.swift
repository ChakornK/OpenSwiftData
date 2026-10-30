import Foundation
@testable import OpenSwiftData
import OpenSwiftDataSQLite
import OSDCore
@testable import OSDStorage
import XCTest

@Model
private final class IndexedPredicateFixture {
    var rank: Int
    @Attribute(.unique) var identity: String
    var label: String

    #Index(\IndexedPredicateFixture.rank)
    #Index(\IndexedPredicateFixture.rank)
    #Unique(\IndexedPredicateFixture.label)
    #Unique(\IndexedPredicateFixture.identity)

    init(rank: Int, identity: String, label: String = "default") {
        self.rank = rank
        self.identity = identity
        self.label = label
    }
}

@Model
private final class ExternalPollingFixture {
    var value: String
    init(value: String) { self.value = value }
}

@Model
private final class ExternalDataCompositionFixture {
    @Attribute(.externalStorage) var payload: Data

    init(payload: Data) { self.payload = payload }
}

final class SQLiteCompositionTests: XCTestCase {
    @MainActor
    func testSQLiteCompositionExternalizesMarkedDataAndRestoresItOnFetch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-external-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let payload = Data(repeating: 3, count: 131_073)
        let container = try ModelContainer(
            for: ExternalDataCompositionFixture.self, configurations: .sqliteFile("external-data", url: url))
        let inferredAttribute = try XCTUnwrap(
            container.schema.entity(forName: "ExternalDataCompositionFixture")?.attributes.first)
        XCTAssertTrue(inferredAttribute.options.contains(.externalStorage))
        let store = try XCTUnwrap(container.store)
        let sessionMarker = try store.writeWithExternalData { _, session in
            try session.externalizedValue(Array(repeating: 4, count: 131_073))
        }
        guard case let .blob(sessionBytes) = sessionMarker else { return XCTFail("Expected a Data BLOB") }
        XCTAssertNotNil(ExternalStorage.fileName(in: sessionBytes))
        let model = ExternalDataCompositionFixture(payload: payload)
        container.mainContext.insert(model)
        try container.mainContext.save()

        let sqliteDriver = try LightweightMigration.openStore(
            location: .file(url), schema: container.schema,
            externalColumns: ["ZEXTERNALDATACOMPOSITIONFIXTURE.ZPAYLOAD"])
        let raw = try sqliteDriver.read { connection in
            try connection.rows("SELECT ZPAYLOAD FROM ZEXTERNALDATACOMPOSITIONFIXTURE").first?.first
        }
        guard case let .blob(referenceBytes)? = raw else {
            return XCTFail("Expected a BLOB reference in SQLite")
        }
        XCTAssertNotEqual(referenceBytes.count, payload.count)
        XCTAssertNotNil(ExternalStorage.fileName(in: referenceBytes))
        try sqliteDriver.close()
        let sidecarDirectory = directory.appendingPathComponent("store.sqlite.external", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path)
                .filter { $0.hasPrefix("data-") && $0.hasSuffix(".blob") }.count,
            1)

        let readerContainer = try ModelContainer(
            for: ExternalDataCompositionFixture.self, configurations: .sqliteFile("external-data-reader", url: url))
        let fetched = try XCTUnwrap(
            readerContainer.makeContext().fetch(FetchDescriptor<ExternalDataCompositionFixture>()).first)
        XCTAssertEqual(fetched.payload, payload)

        let changed = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<ExternalDataCompositionFixture>()).first)
        let replacement = Data(repeating: 5, count: 131_074)
        changed.payload = replacement
        try container.mainContext.save()
        let replacementFiles = try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path)
            .filter { $0.hasPrefix("data-") && $0.hasSuffix(".blob") }
        XCTAssertEqual(replacementFiles.count, 1)
        XCTAssertEqual(
            try readerContainer.makeContext().fetch(FetchDescriptor<ExternalDataCompositionFixture>()).first?.payload,
            replacement)

        let previousSidecarFiles = replacementFiles
        changed.payload = Data(repeating: 7, count: 131_075)
        try XCTUnwrap(container.store).write { connection in
            try connection.execute(
                "CREATE TRIGGER fail_external_update BEFORE UPDATE ON ZEXTERNALDATACOMPOSITIONFIXTURE "
                    + "BEGIN SELECT RAISE(ABORT, 'external Data rollback'); END;",
                arguments: [])
        }
        XCTAssertThrowsError(try container.mainContext.save())
        XCTAssertEqual(
            try readerContainer.makeContext().fetch(FetchDescriptor<ExternalDataCompositionFixture>()).first?.payload,
            replacement)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path)
                .filter { $0.hasPrefix("data-") && $0.hasSuffix(".blob") },
            previousSidecarFiles)
        try XCTUnwrap(container.store).write { connection in
            try connection.execute("DROP TRIGGER fail_external_update", arguments: [])
        }
        try container.mainContext.save()
        XCTAssertEqual(
            try readerContainer.makeContext().fetch(FetchDescriptor<ExternalDataCompositionFixture>()).first?.payload,
            Data(repeating: 7, count: 131_075))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: sidecarDirectory.path)
                .filter { $0.hasPrefix("data-") && $0.hasSuffix(".blob") }.count,
            1)
    }

    @MainActor
    func testExternalDataAtThresholdRemainsInlineInSQLite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-external-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let payload = Data(repeating: 2, count: ExternalStorage.threshold)
        let container = try ModelContainer(
            for: ExternalDataCompositionFixture.self, configurations: .sqliteFile("external-boundary", url: url))
        container.mainContext.insert(ExternalDataCompositionFixture(payload: payload))
        try container.mainContext.save()
        let driver = try LightweightMigration.openStore(
            location: .file(url), schema: container.schema,
            externalColumns: ["ZEXTERNALDATACOMPOSITIONFIXTURE.ZPAYLOAD"])
        let raw = try driver.read { try $0.rows("SELECT ZPAYLOAD FROM ZEXTERNALDATACOMPOSITIONFIXTURE").first?.first }
        guard case let .blob(bytes)? = raw else { return XCTFail("Expected inline BLOB") }
        XCTAssertEqual(bytes.count, payload.count)
        XCTAssertNil(ExternalStorage.fileName(in: bytes))
        try driver.close()
    }

    @MainActor
    func testIndexedPredicateFetchPlanUsesSQLiteIndex() throws {
        let container = try ModelContainer(
            for: IndexedPredicateFixture.self, configurations: .sqliteMemory("predicate-query-plan"))
        guard let store = container.store as? any RuntimeQueryStore else {
            return XCTFail("Expected a query-capable SQLite store")
        }
        for rank in 0..<1_000 {
            container.mainContext.insert(
                IndexedPredicateFixture(rank: rank, identity: "identity-\(rank)", label: "label-\(rank)"))
        }
        try container.mainContext.save()
        let entity: Schema.Entity = try XCTUnwrap(
            container.schema.entity(forName: String(describing: IndexedPredicateFixture.self)))

        let predicate = #Predicate<IndexedPredicateFixture> { $0.rank == 42 }
        let descriptor = FetchDescriptor<IndexedPredicateFixture>(
            predicate: predicate, sortBy: [SortDescriptor(\.rank)], includePendingChanges: false)
        let fetched: [IndexedPredicateFixture] = try container.mainContext.fetch(descriptor)
        XCTAssertEqual(fetched.map { $0.rank }, [42])
        XCTAssertEqual(
            Set(container.schema.entity(forName: entity.name)?.indexes ?? []),
            Set([
                Schema.Index(properties: ["label"], isUnique: true),
                Schema.Index(properties: ["identity"], isUnique: true),
                Schema.Index(properties: ["rank"]),
            ]))
        let indexes = try store.read { try $0.rows("PRAGMA index_list(ZINDEXEDPREDICATEFIXTURE)", arguments: []) }
        XCTAssertTrue(
            indexes.contains { $0.count > 1 && $0[1] == .text("ZINDEXEDPREDICATEFIXTURE_ZLABEL_UNIQUE_INDEX") },
            "\(indexes)")

        let tree = try PredicateRuntimeTreeBuilder.build(
            predicate.expression, modelType: IndexedPredicateFixture.self, entity: entity, schema: container.schema)
        let request = RuntimePredicateRequest(
            entityName: entity.name,
            root: tree.root,
            ordering: ["rank"],
            typedCaptures: tree.captures,
            captureEncoding: .typed,
            attributeNames: Set(entity.attributes.map(\.name)))
        let compiled = try store.compile(request)
        let legacyStorageNode = try PredicateMirrorWalker.walk(predicate.expression) { keyPath in
            guard let property = IndexedPredicateFixture.schemaMetadata().first(where: { $0.keypath == keyPath }) else {
                throw SwiftDataError.unsupportedPredicate("Unknown test property")
            }
            return property.name
        }
        func legacyRuntimeNode(_ node: PredicateMirrorWalker.Node) -> RuntimePredicateNode {
            switch node {
            case let .propertyReference(name): .property(RuntimePropertyReference(name: name))
            case let .capture(typeName, description) where typeName == "OpenSwiftData.PropertyReference":
                .property(RuntimePropertyReference(name: description))
            case let .capture(typeName, description): .capture(typeName: typeName, description: description)
            case let .typedValue(value): .capture(typeName: "Swift.Int", description: String(describing: value))
            case let .expression(name, children):
                .expression(name: name, children: children.map { ($0.0, legacyRuntimeNode($0.1)) })
            }
        }
        let legacyCompiled = try store.compile(
            RuntimePredicateRequest(
                entityName: entity.name, root: legacyRuntimeNode(legacyStorageNode), ordering: ["rank"],
                attributeNames: Set(entity.attributes.map(\.name))))
        XCTAssertEqual(legacyCompiled.sql, compiled.sql)
        XCTAssertEqual(legacyCompiled.arguments, compiled.arguments)
        XCTAssertThrowsError(
            try store.compile(
                RuntimePredicateRequest(
                    entityName: entity.name, root: tree.root, ordering: ["rank"], captureEncoding: .typed,
                    attributeNames: Set(entity.attributes.map(\.name)))))
        let query = FetchSQLBuilder.build(
            FetchSQLInput(
                table: "Z\(entity.name.uppercased())",
                columns: ["ZRANK"],
                predicateSQL: compiled.sql,
                predicateArguments: compiled.arguments,
                orderSQL: "t0.ZRANK COLLATE swiftLocalizedStandardCompare ASC",
                limit: nil,
                offset: nil))
        let plan = try store.read { connection in
            try connection.rows("EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
        }
        let details = plan.compactMap { row in
            row.last.flatMap { value -> String? in
                guard case let .text(detail) = value else { return nil }
                return detail
            }
        }

        XCTAssertTrue(
            details.contains(where: {
                $0.contains("SEARCH") && $0.contains("USING INDEX ZINDEXEDPREDICATEFIXTURE_ZRANK_INDEX")
            }),
            details.joined(separator: "\n"))
        XCTAssertFalse(
            details.contains(where: { $0 == "SCAN Z\(entity.name.uppercased())" }), details.joined(separator: "\n"))
        XCTAssertThrowsError(
            try store.write { connection in
                try connection.execute(
                    "INSERT INTO ZINDEXEDPREDICATEFIXTURE (Z_ENT, Z_OPT, ZRANK, ZLABEL) VALUES (?, ?, ?, ?)",
                    arguments: [.int(1), .int(1), .int(1_001), .text("label-42")])
            })
    }

    func testLocalizedStandardContainsSQLiteFunctionMatchesFoundation() throws {
        let container = try ModelContainer(
            for: Schema([Schema.Entity(name: "Probe")]), configurations: [.sqliteMemory("localized-function")])
        guard let store = container.store else { return XCTFail("Expected SQLite store") }
        let rows = try store.read { connection in
            try connection.rows(
                "SELECT osd_localized_standard_contains(?, ?), "
                    + "osd_localized_standard_contains(?, ?), osd_localized_standard_contains(NULL, ?)",
                arguments: [.text("Café"), .text("cafe"), .text("anything"), .text(""), .text("x")])
        }
        XCTAssertEqual(rows, [[.int(1), .int(0), .null]])
    }

    func testStringContainsSQLiteFunctionMatchesFoundation() throws {
        let container = try ModelContainer(
            for: Schema([Schema.Entity(name: "Probe")]), configurations: [.sqliteMemory("string-function")])
        guard let store = container.store else { return XCTFail("Expected SQLite store") }
        let rows = try store.read { connection in
            try connection.rows(
                "SELECT osd_string_contains(?, ?), osd_string_contains(?, ?), osd_string_contains(NULL, ?)",
                arguments: [.text("café"), .text("e\u{301}"), .text("cafe\u{301}"), .text("e"), .text("x")])
        }
        XCTAssertEqual(
            rows,
            [
                [
                    .int("café".contains("e\u{301}") ? 1 : 0),
                    .int("cafe\u{301}".contains("e") ? 1 : 0),
                    .null,
                ]
            ])
    }

    func testStringStartsWithSQLiteFunctionMatchesFoundation() throws {
        let container = try ModelContainer(
            for: Schema([Schema.Entity(name: "Probe")]), configurations: [.sqliteMemory("prefix-function")])
        guard let store = container.store else { return XCTFail("Expected SQLite store") }
        let rows = try store.read { connection in
            try connection.rows(
                "SELECT osd_string_starts_with(?, ?), osd_string_starts_with(?, ?), "
                    + "osd_string_starts_with(NULL, ?)",
                arguments: [.text("e\u{301}clair"), .text("é"), .text("anything"), .text(""), .text("x")])
        }
        XCTAssertEqual(rows, [[.int(1), .int(1), .null]])
    }

    func testExternalClientUsesExistingConfigurationAPI() throws {
        let memory = try openExternalClientMemoryContainer()
        XCTAssertEqual(memory.schema.entities.map(\.name), ["ExternalClientModel"])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-external-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let file = try openExternalClientFileContainer(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(file.schema.entities.map(\.name), ["ExternalClientModel"])
    }

    func testMemoryConfigurationCreatesAndBootstrapsSchema() throws {
        let schema = Schema([
            Schema.Entity(
                name: "Person",
                attributes: [Schema.Attribute(name: "name", type: "String")]
            )
        ])
        let container = try ModelContainer(for: schema, configurations: [.sqliteMemory("memory-test")])
        guard let store = container.store else { return XCTFail("Expected an opened store") }
        let rows = try store.read { connection in
            try connection.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY", arguments: [])
        }
        XCTAssertEqual(rows, [[.int(1), .text("Person"), .int(0), .int(0)]])
    }

    func testFileConfigurationCreatesStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let schema = Schema([Schema.Entity(name: "Person")])
        let container = try ModelContainer(for: schema, configurations: [.sqliteFile("file-test", url: url)])
        XCTAssertNotNil(container.store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testExplicitDataVersionPollingRefreshesExternalFileChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-data-version-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let writerContainer = try ModelContainer(
            for: ExternalPollingFixture.self, configurations: .sqliteFile("external-writer", url: url))
        let writer = writerContainer.mainContext
        let model = ExternalPollingFixture(value: "initial")
        writer.insert(model)
        try writer.save()

        let readerContainer = try ModelContainer(
            for: ExternalPollingFixture.self, configurations: .sqliteFile("external-reader", url: url))
        let reader = readerContainer.makeContext()
        let held = try XCTUnwrap(reader.fetch(FetchDescriptor<ExternalPollingFixture>()).first)
        try reader.pollForExternalChanges()

        model.value = "external"
        try writer.save()
        try reader.pollForExternalChanges()

        XCTAssertEqual(held.value, "external")
    }

    func testConfigurationWithoutSelectedProviderThrowsUnsupportedStore() {
        let schema = Schema([Schema.Entity(name: "Person")])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-unsupported-\(UUID().uuidString).sqlite")
        let configurations = [
            ModelConfiguration("url", schema: schema, url: url),
            ModelConfiguration("memory", schema: schema, isStoredInMemoryOnly: true),
        ]

        for configuration in configurations {
            XCTAssertThrowsError(try ModelContainer(for: schema, configurations: [configuration])) { error in
                guard case SwiftDataError.unsupportedStore(let message) = error else {
                    return XCTFail("Expected unsupportedStore, got \\(error)")
                }
                XCTAssertTrue(message.contains("backend/provider"))
                XCTAssertTrue(message.contains("unavailable"))
            }
        }
    }

    func testUnsupportedSchemaDoesNotLeavePartialFileStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let schema = Schema([
            Schema.Entity(name: "Person", attributes: [Schema.Attribute(name: "value", type: "Opaque")])
        ])
        XCTAssertThrowsError(try ModelContainer(for: schema, configurations: [.sqliteFile("invalid", url: url)]))
    }
}
