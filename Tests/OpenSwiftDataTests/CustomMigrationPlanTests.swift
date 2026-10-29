import Foundation
import XCTest
@testable import OpenSwiftData
@testable import OpenSwiftDataSQLite

@Model
final class MigrationPlanRecord {
    var name: String
    init(name: String) { self.name = name }
}

private enum MigrationV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(version: [1, 0, 0], identifier: "migration-v1")
    static var models: [any PersistentModel.Type] { [MigrationPlanRecord.self] }
    static let schema = Schema(
        [
            Schema.Entity(
                name: "MigrationPlanRecord",
                attributes: [Schema.Attribute(name: "name", type: "String")])
        ], version: versionIdentifier)
}

private enum MigrationV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(version: [2, 0, 0], identifier: "migration-v2")
    static var models: [any PersistentModel.Type] { [MigrationPlanRecord.self] }
    static let schema = Schema(
        [
            Schema.Entity(
                name: "MigrationPlanRecord",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                ])
        ], version: versionIdentifier)
}

private enum TestMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { context in
                    MigrationStageRecorder.shared.append(
                        "will:\(context.container?.schema.version?.identifier ?? "nil")")
                    XCTAssertEqual(
                        context.container?.schema.entity(forName: "MigrationPlanRecord")?.attributes.map(\.name),
                        ["name"])
                    context.insert(MigrationPlanRecord(name: "from-v1"))
                    try context.save()
                },
                didMigrate: { context in
                    MigrationStageRecorder.shared.append(
                        "did:\(context.container?.schema.version?.identifier ?? "nil")")
                    XCTAssertEqual(
                        context.container?.schema.entity(forName: "MigrationPlanRecord")?.attributes.map(\.name),
                        ["name", "note"])
                    let records = try context.fetch(FetchDescriptor<MigrationPlanRecord>())
                    XCTAssertEqual(records.map(\.name), ["from-v1"])
                })
        ]
    }
}

private enum FailingMigrationPlan: SchemaMigrationPlan {
    static let failureSwitch = MigrationFailureSwitch()
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { _ in
                    if failureSwitch.shouldFail {
                        throw SwiftDataError.migrationUnsupported("expected migration failure")
                    }
                })
        ]
    }
}

private enum FailingDestinationPlan: SchemaMigrationPlan {
    static let failureSwitch = MigrationFailureSwitch()
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { context in
                    MigrationStageRecorder.shared.append("destination-retry-will")
                    context.insert(MigrationPlanRecord(name: "retry"))
                    try context.save()
                },
                didMigrate: { context in
                    let record = try XCTUnwrap(context.fetch(FetchDescriptor<MigrationPlanRecord>()).first)
                    record.name = "destination-mutated"
                    try context.save()
                    if failureSwitch.shouldFail {
                        throw SwiftDataError.migrationUnsupported("expected destination failure")
                    }
                    XCTAssertEqual(
                        try context.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name),
                        ["destination-mutated"])
                    MigrationStageRecorder.shared.append("destination-retry-did")
                })
        ]
    }
}

private final class MigrationFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var shouldFail: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class MigrationFactoryFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failingCall: Int

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func shouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls == failingCall
    }
}

private final class MigrationStageRecorder: @unchecked Sendable {
    static let shared = MigrationStageRecorder()
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class CustomMigrationPlanTests: XCTestCase {
    @MainActor
    func testCustomStageRunsSourceAndDestinationContextsOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationPlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("store.sqlite")
        MigrationStageRecorder.shared.reset()

        let container = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: TestMigrationPlan.self,
            configurations: .sqliteFile("migration-plan", url: storeURL))

        XCTAssertEqual(container.schema.version, MigrationV2.versionIdentifier)
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["will:migration-v1", "did:migration-v2"])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name), ["from-v1"])
        let migratedRow = try container.store?.read { connection in
            try connection.rows("SELECT ZNAME, ZNOTE FROM ZMIGRATIONPLANRECORD", arguments: []).first
        }
        XCTAssertEqual(migratedRow ?? nil, [.text("from-v1"), .null])

        _ = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: TestMigrationPlan.self,
            configurations: .sqliteFile("migration-plan-reopen", url: storeURL))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["will:migration-v1", "did:migration-v2"])
    }

    func testMigrationPlanRejectsDisconnectedStages() {
        enum InvalidPlan: SchemaMigrationPlan {
            static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
            static var stages: [MigrationStage] {
                [
                    .lightweight(fromVersion: MigrationV2.self, toVersion: MigrationV1.self)
                ]
            }
        }
        XCTAssertThrowsError(try MigrationPlanDescriptor(InvalidPlan.self)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
    }

    func testMigrationPlanRejectsSchemaVersionMismatch() {
        enum InvalidVersionedSchema: VersionedSchema {
            static let versionIdentifier = Schema.Version(version: [8], identifier: "declared-v8")
            static var models: [any PersistentModel.Type] { [MigrationPlanRecord.self] }
            static let schema = MigrationV1.schema
        }
        enum InvalidPlan: SchemaMigrationPlan {
            static var schemas: [any VersionedSchema.Type] { [InvalidVersionedSchema.self] }
            static var stages: [MigrationStage] { [] }
        }
        XCTAssertThrowsError(try MigrationPlanDescriptor(InvalidPlan.self)) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
    }

    @MainActor
    func testMigrationPlanRejectsUnversionedExistingStores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationUnversioned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-unversioned", url: url)])
        try source.store?.write { connection in
            try connection.execute(
                "DELETE FROM _osd_meta WHERE key = ?", arguments: [RuntimeValue.text("schema.version.v1")])
        }
        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: TestMigrationPlan.self,
                configurations: .sqliteFile("migration-unversioned", url: url))
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
    }

    @MainActor
    func testInMemoryMigrationPlanCreatesLatestSchemaWithoutStageCallbacks() throws {
        MigrationStageRecorder.shared.reset()
        let container = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: TestMigrationPlan.self,
            configurations: .sqliteMemory("migration-plan-memory"))
        XCTAssertEqual(container.schema.version, MigrationV2.versionIdentifier)
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])
        XCTAssertNotNil(container.store)
    }

    @MainActor
    func testFailedWillMigrateLeavesSourceVersionAvailableForRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-retry", url: url)])
        source.mainContext.insert(MigrationPlanRecord(name: "saved"))
        try source.mainContext.save()

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: FailingMigrationPlan.self,
                configurations: .sqliteFile("migration-retry", url: url)))
        FailingMigrationPlan.failureSwitch.shouldFail = false
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: FailingMigrationPlan.self,
            configurations: .sqliteFile("migration-retry", url: url))
        XCTAssertEqual(retried.schema.version, MigrationV2.versionIdentifier)
        XCTAssertEqual(
            try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name), ["saved"])
    }

    @MainActor
    func testFailedDidMigrateResumesDestinationCallbackWithoutRepeatingWill() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationDidRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        MigrationStageRecorder.shared.reset()
        FailingDestinationPlan.failureSwitch.shouldFail = true

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: FailingDestinationPlan.self,
                configurations: .sqliteFile("migration-did-retry", url: url)))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["destination-retry-will"])

        FailingDestinationPlan.failureSwitch.shouldFail = false
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: FailingDestinationPlan.self,
            configurations: .sqliteFile("migration-did-retry", url: url))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["destination-retry-will", "destination-retry-did"])
        XCTAssertEqual(retried.schema.version, MigrationV2.versionIdentifier)
        XCTAssertEqual(
            try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name),
            ["destination-mutated"])
    }

    @MainActor
    func testFinalStoreOpenFailureKeepsPendingStageForRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationFinalOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-final-open", url: url)])
        try source.store?.close()
        MigrationStageRecorder.shared.reset()

        let failure = MigrationFactoryFailure(failingCall: 3)
        let sqliteFactory = OpenSwiftDataSQLite.sqliteFactory
        let factory: RuntimeStoreFactory = { location, schema in
            if failure.shouldFail() { throw SwiftDataError.unsupportedStore("injected final-open failure") }
            return try sqliteFactory(location, schema)
        }
        let configuration = ModelConfiguration(
            "migration-final-open", url: url, storeFactory: factory,
            schemaVersionReader: OpenSwiftDataSQLite.sqliteVersionReader)

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: TestMigrationPlan.self,
                configurations: configuration))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["will:migration-v1", "did:migration-v2"])

        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: TestMigrationPlan.self,
            configurations: configuration)
        XCTAssertEqual(
            MigrationStageRecorder.shared.values,
            ["will:migration-v1", "did:migration-v2", "did:migration-v2"])
        XCTAssertEqual(retried.schema.version, MigrationV2.versionIdentifier)
    }
}
