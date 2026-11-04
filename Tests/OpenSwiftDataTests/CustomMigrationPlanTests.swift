import Foundation
import XCTest
import GRDB
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

private enum MigrationV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(version: [3, 0, 0], identifier: "migration-v3")
    static var models: [any PersistentModel.Type] { [MigrationPlanRecord.self] }
    static let schema = Schema(
        [
            Schema.Entity(
                name: "MigrationPlanRecord",
                attributes: [
                    Schema.Attribute(name: "name", type: "String"),
                    Schema.Attribute(name: "note", type: "String", isOptional: true),
                    Schema.Attribute(name: "detail", type: "String", isOptional: true),
                ])
        ], version: versionIdentifier)
}

private enum LightweightMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: MigrationV1.self, toVersion: MigrationV2.self)]
    }
}

private enum VersionThreePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self, MigrationV3.self] }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: MigrationV1.self, toVersion: MigrationV2.self),
            .lightweight(fromVersion: MigrationV2.self, toVersion: MigrationV3.self),
        ]
    }
}

private enum MidChainRecordingPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self, MigrationV3.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { _ in MigrationStageRecorder.shared.append("mid-chain-stage1-will") },
                didMigrate: { context in
                    MigrationStageRecorder.shared.append("mid-chain-stage1-did")
                    for record in try context.fetch(FetchDescriptor<MigrationPlanRecord>()) {
                        record.name = "v2-\(record.name)"
                    }
                    try context.save()
                }),
            .custom(
                fromVersion: MigrationV2.self,
                toVersion: MigrationV3.self,
                willMigrate: { _ in MigrationStageRecorder.shared.append("mid-chain-stage2-will") },
                didMigrate: { context in
                    MigrationStageRecorder.shared.append("mid-chain-stage2-did")
                    for record in try context.fetch(FetchDescriptor<MigrationPlanRecord>()) {
                        record.name = "v3-\(record.name)"
                    }
                    try context.save()
                }),
        ]
    }
}

private enum MultiStageFailurePlan: SchemaMigrationPlan {
    static let failureSwitch = MigrationFailureSwitch()
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self, MigrationV3.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { _ in MigrationStageRecorder.shared.append("stage1-will") },
                didMigrate: { context in
                    MigrationStageRecorder.shared.append("stage1-did")
                    for record in try context.fetch(FetchDescriptor<MigrationPlanRecord>()) {
                        record.name = "stage1-\(record.name)"
                    }
                    try context.save()
                }),
            .custom(
                fromVersion: MigrationV2.self,
                toVersion: MigrationV3.self,
                willMigrate: { _ in MigrationStageRecorder.shared.append("stage2-will") },
                didMigrate: { context in
                    MigrationStageRecorder.shared.append("stage2-did")
                    let record = try XCTUnwrap(context.fetch(FetchDescriptor<MigrationPlanRecord>()).first)
                    record.name = "stage2-\(record.name)"
                    try context.save()
                    if failureSwitch.shouldFail {
                        throw SwiftDataError.migrationUnsupported("expected stage 2 destination failure")
                    }
                }),
        ]
    }
}

private enum VersionRecoveryPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { _ in MigrationStageRecorder.shared.append("version-recovery-will") },
                didMigrate: { _ in MigrationStageRecorder.shared.append("version-recovery-did") })
        ]
    }
}

private enum UnversionedRecoveryPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { _ in MigrationStageRecorder.shared.append("unversioned-recovery-will") },
                didMigrate: { _ in MigrationStageRecorder.shared.append("unversioned-recovery-did") })
        ]
    }
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
                willMigrate: { context in
                    if failureSwitch.shouldFail {
                        context.insert(MigrationPlanRecord(name: "rolled-back"))
                        try context.save()
                        throw SwiftDataError.migrationUnsupported("expected migration failure")
                    }
                })
        ]
    }
}

private enum FailingDeleteMigrationPlan: SchemaMigrationPlan {
    static let failureSwitch = MigrationFailureSwitch()
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { context in
                    if failureSwitch.shouldFail {
                        let target = try XCTUnwrap(
                            context.fetch(FetchDescriptor<MigrationPlanRecord>()).first(where: { $0.name == "saved-a" })
                        )
                        context.delete(target)
                        try context.save()
                        throw SwiftDataError.migrationUnsupported("expected delete migration failure")
                    }
                })
        ]
    }
}

private enum FailingSourceUpdateMigrationPlan: SchemaMigrationPlan {
    static let failureSwitch = MigrationFailureSwitch()
    static var schemas: [any VersionedSchema.Type] { [MigrationV1.self, MigrationV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationV1.self,
                toVersion: MigrationV2.self,
                willMigrate: { context in
                    guard failureSwitch.shouldFail else { return }
                    let target = try XCTUnwrap(
                        context.fetch(FetchDescriptor<MigrationPlanRecord>()).first(where: { $0.name == "saved-a" }))
                    target.name = "updated-before-failure"
                    context.insert(MigrationPlanRecord(name: "inserted-before-failure"))
                    try context.save()
                    throw SwiftDataError.migrationUnsupported("expected source update failure")
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
                    let record = try XCTUnwrap(
                        context.fetch(FetchDescriptor<MigrationPlanRecord>()).first(where: { $0.name == "saved" }))
                    record.name = "destination-mutated"
                    try context.save()
                    if failureSwitch.shouldFail {
                        throw SwiftDataError.migrationUnsupported("expected destination failure")
                    }
                    XCTAssertEqual(
                        try context.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
                        ["destination-mutated", "retry", "second"])
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
    func testLightweightStagePreservesRowsAndPersistsDestinationVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataLightweightMigrationPlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("lightweight-migration-plan", url: storeURL)])
        let original = MigrationPlanRecord(name: "preserved")
        source.mainContext.insert(original)
        try source.mainContext.save()
        let originalID = try XCTUnwrap(original.persistentModelID)
        let originalRow = try XCTUnwrap(
            source.store?.read { connection in
                try connection.rows("SELECT Z_PK FROM ZMIGRATIONPLANRECORD", arguments: []).first?.first
            } ?? nil)
        try source.store?.close()

        let migrated = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: LightweightMigrationPlan.self,
            configurations: .sqliteFile("lightweight-migration-plan", url: storeURL))

        XCTAssertEqual(migrated.schema.version, MigrationV2.versionIdentifier)
        XCTAssertEqual(
            migrated.schema.entity(forName: "MigrationPlanRecord")?.attributes.map(\.name), ["name", "note"])
        let records = try migrated.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>())
        XCTAssertEqual(records.map(\.name), ["preserved"])
        XCTAssertEqual(records.first?.persistentModelID, originalID)
        let row = try migrated.store?.read { connection in
            try connection.rows("SELECT Z_PK, ZNAME, ZNOTE FROM ZMIGRATIONPLANRECORD", arguments: []).first
        }
        guard case .int = originalRow else {
            return XCTFail("Expected the source row to have an integer primary key.")
        }
        XCTAssertEqual(row ?? nil, [originalRow, .text("preserved"), .null])
        let version = try migrated.store?.read { connection in
            try connection.rows(
                "SELECT value FROM _osd_meta WHERE key = ?", arguments: [.text("schema.version.v1")]
            ).first?.first
        }
        XCTAssertEqual(version ?? nil, .blob(try MigrationV2.versionIdentifier.encoded()))
        try migrated.store?.close()

        let reopened = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: LightweightMigrationPlan.self,
            configurations: .sqliteFile("lightweight-migration-plan-reopen", url: storeURL))
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name), ["preserved"])
        XCTAssertEqual(
            try reopened.store?.read {
                try $0.rows("SELECT Z_PK, ZNAME, ZNOTE FROM ZMIGRATIONPLANRECORD", arguments: [])
            },
            [[originalRow, .text("preserved"), .null]])
        try reopened.store?.close()
    }

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
    func testMigrationPlanRejectsFutureStoredVersionWithoutMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationFutureVersion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let initial = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: VersionThreePlan.self,
            configurations: .sqliteFile("migration-future-version", url: url))
        initial.mainContext.insert(MigrationPlanRecord(name: "future-a"))
        initial.mainContext.insert(MigrationPlanRecord(name: "future-b"))
        try initial.mainContext.save()
        var seededConfiguration = Configuration()
        seededConfiguration.readonly = true
        let seeded = try DatabaseQueue(path: url.path, configuration: seededConfiguration)
        let metadataSQL = "SELECT key || ':' || COALESCE(hex(value), 'NULL') FROM _osd_meta ORDER BY key"
        let rowsSQL =
            "SELECT CAST(Z_PK AS TEXT) || ':' || ZNAME || ':' || COALESCE(ZNOTE, 'NULL') FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK"
        let primaryKeysSQL =
            "SELECT CAST(Z_ENT AS TEXT) || ':' || Z_NAME || ':' || CAST(Z_SUPER AS TEXT) || ':' || CAST(Z_MAX AS TEXT) FROM Z_PRIMARYKEY ORDER BY Z_ENT"
        let tablesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' ORDER BY name"
        let indexesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'index' ORDER BY name"
        let originalMetadata = try seeded.read { try String.fetchAll($0, sql: metadataSQL) }
        let originalRows = try seeded.read { try String.fetchAll($0, sql: rowsSQL) }
        let originalPrimaryKeys = try seeded.read { try String.fetchAll($0, sql: primaryKeysSQL) }
        let originalTables = try seeded.read { try String.fetchAll($0, sql: tablesSQL) }
        let originalIndexes = try seeded.read { try String.fetchAll($0, sql: indexesSQL) }
        try seeded.close()
        try initial.store?.close()

        MigrationStageRecorder.shared.reset()
        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self,
                migrationPlan: TestMigrationPlan.self,
                configurations: .sqliteFile("migration-future-version", url: url))
        ) { error in
            guard case let SwiftDataError.migrationUnsupported(message) = error else {
                return XCTFail("Expected an unknown stored schema version to fail closed, got \(error)")
            }
            XCTAssertTrue(message.contains("migration-v3' is not present in the migration plan."), message)
        }
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])

        var readOnly = Configuration()
        readOnly.readonly = true
        let inspection = try DatabaseQueue(path: url.path, configuration: readOnly)
        XCTAssertEqual(try inspection.read { try String.fetchAll($0, sql: metadataSQL) }, originalMetadata)
        XCTAssertEqual(try inspection.read { try String.fetchAll($0, sql: rowsSQL) }, originalRows)
        XCTAssertEqual(try inspection.read { try String.fetchAll($0, sql: primaryKeysSQL) }, originalPrimaryKeys)
        XCTAssertEqual(try inspection.read { try String.fetchAll($0, sql: tablesSQL) }, originalTables)
        XCTAssertEqual(try inspection.read { try String.fetchAll($0, sql: indexesSQL) }, originalIndexes)
        XCTAssertEqual(try inspection.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }, "ok")
        try inspection.close()

        let reopened = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: VersionThreePlan.self,
            configurations: .sqliteFile("migration-future-version-reopen", url: url))
        XCTAssertEqual(reopened.schema.version, MigrationV3.versionIdentifier)
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["future-a", "future-b"])
        let reopenedIdentifierRows: [[RuntimeValue]] = try XCTUnwrap(
            reopened.store?.read { connection in
                try connection.rows("SELECT Z_PK FROM ZMIGRATIONPLANRECORD", arguments: [])
            })
        let reopenedPrimaryKeys: Set<Int64> = Set(
            reopenedIdentifierRows.compactMap { row in
                guard case let .int(primaryKey)? = row.first else { return nil }
                return primaryKey
            })
        let originalPrimaryKeyValues: Set<Int64> = Set(
            originalRows.compactMap { row in
                let components = row.split(separator: ":", maxSplits: 1)
                guard let primaryKey = components.first else { return nil }
                return Int64(String(primaryKey))
            })
        XCTAssertEqual(reopenedPrimaryKeys, originalPrimaryKeyValues)
    }

    @MainActor
    func testMigrationPlanStartsAtStoredMidChainVersionAndNoOpsWhenCurrent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationMidChain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let versionTwo = try ModelContainer(
            for: MigrationPlanRecord.self,
            migrationPlan: LightweightMigrationPlan.self,
            configurations: .sqliteFile("migration-mid-chain", url: url))
        versionTwo.mainContext.insert(MigrationPlanRecord(name: "already-v2"))
        try versionTwo.mainContext.save()
        try versionTwo.store?.close()

        MigrationStageRecorder.shared.reset()
        let versionThree = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: MidChainRecordingPlan.self,
            configurations: .sqliteFile("migration-mid-chain", url: url))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["mid-chain-stage2-will", "mid-chain-stage2-did"])
        XCTAssertEqual(versionThree.schema.version, MigrationV3.versionIdentifier)
        XCTAssertEqual(
            try versionThree.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name), ["v3-already-v2"]
        )
        let stageTwoRows = try versionThree.store?.read { connection in
            try connection.rows("SELECT ZNAME, ZNOTE, ZDETAIL FROM ZMIGRATIONPLANRECORD", arguments: [])
        }
        XCTAssertEqual(stageTwoRows ?? nil, [[.text("v3-already-v2"), .null, .null]])
        let stageTwoMetadata = try versionThree.store?.read { connection in
            try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
        }
        let stageTwoPrimaryKeys = try versionThree.store?.read { connection in
            try connection.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT", arguments: [])
        }
        let stageTwoTables = try versionThree.store?.read { connection in
            try connection.rows("SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name", arguments: [])
        }
        let stageTwoIndexes = try versionThree.store?.read { connection in
            try connection.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name", arguments: [])
        }
        try versionThree.store?.close()

        MigrationStageRecorder.shared.reset()
        let reopened = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: MidChainRecordingPlan.self,
            configurations: .sqliteFile("migration-mid-chain-current", url: url))
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])
        XCTAssertEqual(reopened.schema.version, MigrationV3.versionIdentifier)
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name),
            ["v3-already-v2"])
        XCTAssertEqual(
            try reopened.store?.read { connection in
                try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
            },
            stageTwoMetadata)
        XCTAssertEqual(
            try reopened.store?.read { connection in
                try connection.rows(
                    "SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT", arguments: [])
            },
            stageTwoPrimaryKeys)
        XCTAssertEqual(
            try reopened.store?.read { connection in
                try connection.rows(
                    "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name", arguments: [])
            },
            stageTwoTables)
        XCTAssertEqual(
            try reopened.store?.read { connection in
                try connection.rows(
                    "SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name", arguments: [])
            },
            stageTwoIndexes)
        XCTAssertEqual(
            try reopened.store?.read { connection in
                try connection.rows("SELECT ZNAME, ZNOTE, ZDETAIL FROM ZMIGRATIONPLANRECORD", arguments: [])
            },
            stageTwoRows)
    }

    @MainActor
    func testStoredVersionHashMismatchFailsWithoutRoutingToWrongStage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationVersionHashMismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let initial = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: VersionThreePlan.self,
            configurations: .sqliteFile("migration-version-hash-mismatch", url: url))
        initial.mainContext.insert(MigrationPlanRecord(name: "future-a"))
        initial.mainContext.insert(MigrationPlanRecord(name: "future-b"))
        try initial.mainContext.save()

        func query(_ sql: String, readOnly: Bool = true) throws -> [String] {
            var configuration = Configuration()
            configuration.readonly = readOnly
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? database.close() }
            return try database.read { try String.fetchAll($0, sql: sql) }
        }
        let metadataSQL = "SELECT key || ':' || COALESCE(hex(value), 'NULL') FROM _osd_meta ORDER BY key"
        let rowsSQL =
            "SELECT CAST(Z_PK AS TEXT) || ':' || ZNAME || ':' || COALESCE(ZNOTE, 'NULL') || ':' || COALESCE(ZDETAIL, 'NULL') FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK"
        let primaryKeysSQL =
            "SELECT CAST(Z_ENT AS TEXT) || ':' || Z_NAME || ':' || CAST(Z_SUPER AS TEXT) || ':' || CAST(Z_MAX AS TEXT) FROM Z_PRIMARYKEY ORDER BY Z_ENT"
        let tablesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' ORDER BY name"
        let indexesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'index' ORDER BY name"
        let originalMetadata = try query(metadataSQL)
        let originalRows = try query(rowsSQL)
        let originalPrimaryKeys = try query(primaryKeysSQL)
        let originalTables = try query(tablesSQL)
        let originalIndexes = try query(indexesSQL)
        try initial.store?.close()

        let encodedV2 = Data(try MigrationV2.versionIdentifier.encoded())
        var writable = Configuration()
        writable.readonly = false
        let mutateVersion = try DatabaseQueue(path: url.path, configuration: writable)
        try mutateVersion.write { database in
            try database.execute(
                sql: "UPDATE _osd_meta SET value = ? WHERE key = ?",
                arguments: [encodedV2, "schema.version.v1"])
            XCTAssertEqual(database.changesCount, 1)
        }
        try mutateVersion.close()
        let inconsistentMetadata = try query(metadataSQL)
        XCTAssertNotEqual(inconsistentMetadata, originalMetadata)

        MigrationStageRecorder.shared.reset()
        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: TestMigrationPlan.self,
                configurations: .sqliteFile("migration-version-hash-mismatch", url: url))
        ) { error in
            guard case let SwiftDataError.migrationUnsupported(message) = error else {
                return XCTFail("Expected version/hash mismatch to fail closed, got \(error)")
            }
            XCTAssertTrue(message.contains("Stored schema does not match recorded version 'migration-v2'"), message)
        }
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])
        XCTAssertEqual(try query(metadataSQL), inconsistentMetadata)
        XCTAssertEqual(try query(rowsSQL), originalRows)
        XCTAssertEqual(try query(primaryKeysSQL), originalPrimaryKeys)
        XCTAssertEqual(try query(tablesSQL), originalTables)
        XCTAssertEqual(try query(indexesSQL), originalIndexes)

        let encodedV3 = Data(try MigrationV3.versionIdentifier.encoded())
        let restoreVersion = try DatabaseQueue(path: url.path, configuration: writable)
        try restoreVersion.write { database in
            try database.execute(
                sql: "UPDATE _osd_meta SET value = ? WHERE key = ?",
                arguments: [encodedV3, "schema.version.v1"])
            XCTAssertEqual(database.changesCount, 1)
        }
        try restoreVersion.close()
        XCTAssertEqual(try query(metadataSQL), originalMetadata)

        let reopened = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: VersionThreePlan.self,
            configurations: .sqliteFile("migration-version-hash-mismatch-reopen", url: url))
        XCTAssertEqual(reopened.schema.version, MigrationV3.versionIdentifier)
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["future-a", "future-b"])
        XCTAssertEqual(try query(rowsSQL), originalRows)
        XCTAssertEqual(try query(primaryKeysSQL), originalPrimaryKeys)
        XCTAssertEqual(try query(tablesSQL), originalTables)
        XCTAssertEqual(try query(indexesSQL), originalIndexes)
    }

    @MainActor
    func testPendingVersionHashMismatchFailsWithoutResumingCallbacks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationPendingHashMismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let initial = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: VersionThreePlan.self,
            configurations: .sqliteFile("migration-pending-hash-mismatch", url: url))
        initial.mainContext.insert(MigrationPlanRecord(name: "pending-a"))
        initial.mainContext.insert(MigrationPlanRecord(name: "pending-b"))
        try initial.mainContext.save()
        try initial.store?.close()

        func query(_ sql: String, readOnly: Bool = true) throws -> [String] {
            var configuration = Configuration()
            configuration.readonly = readOnly
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? database.close() }
            return try database.read { try String.fetchAll($0, sql: sql) }
        }
        let metadataSQL = "SELECT key || ':' || COALESCE(hex(value), 'NULL') FROM _osd_meta ORDER BY key"
        let rowsSQL =
            "SELECT CAST(Z_PK AS TEXT) || ':' || ZNAME || ':' || COALESCE(ZNOTE, 'NULL') || ':' || COALESCE(ZDETAIL, 'NULL') FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK"
        let primaryKeysSQL =
            "SELECT CAST(Z_ENT AS TEXT) || ':' || Z_NAME || ':' || CAST(Z_SUPER AS TEXT) || ':' || CAST(Z_MAX AS TEXT) FROM Z_PRIMARYKEY ORDER BY Z_ENT"
        let tablesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' ORDER BY name"
        let indexesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'index' ORDER BY name"
        let originalMetadata = try query(metadataSQL)
        let originalRows = try query(rowsSQL)
        let originalPrimaryKeys = try query(primaryKeysSQL)
        let originalTables = try query(tablesSQL)
        let originalIndexes = try query(indexesSQL)

        var writable = Configuration()
        writable.readonly = false
        let corruptMarker = try DatabaseQueue(path: url.path, configuration: writable)
        try corruptMarker.write { database in
            try database.execute(
                sql:
                    "INSERT INTO _osd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: ["schema.migration.pending.v1", Data(MigrationV2.versionIdentifier.identifier.utf8)])
            XCTAssertEqual(database.changesCount, 1)
        }
        try corruptMarker.close()
        let inconsistentMetadata = try query(metadataSQL)
        MigrationStageRecorder.shared.reset()

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: VersionThreePlan.self,
                configurations: .sqliteFile("migration-pending-hash-mismatch", url: url))
        ) { error in
            guard case let SwiftDataError.migrationUnsupported(message) = error else {
                return XCTFail("Expected pending/schema mismatch to fail closed, got \(error)")
            }
            XCTAssertTrue(
                message.contains("Stored schema does not match pending destination version 'migration-v2'"), message)
        }
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])
        XCTAssertEqual(try query(metadataSQL), inconsistentMetadata)
        XCTAssertEqual(try query(rowsSQL), originalRows)
        XCTAssertEqual(try query(primaryKeysSQL), originalPrimaryKeys)
        XCTAssertEqual(try query(tablesSQL), originalTables)
        XCTAssertEqual(try query(indexesSQL), originalIndexes)

        let restoreMarker = try DatabaseQueue(path: url.path, configuration: writable)
        try restoreMarker.write { database in
            try database.execute(
                sql: "DELETE FROM _osd_meta WHERE key = ?", arguments: ["schema.migration.pending.v1"])
            XCTAssertEqual(database.changesCount, 1)
        }
        try restoreMarker.close()
        XCTAssertEqual(try query(metadataSQL), originalMetadata)

        let reopened = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: VersionThreePlan.self,
            configurations: .sqliteFile("migration-pending-hash-mismatch-reopen", url: url))
        XCTAssertEqual(reopened.schema.version, MigrationV3.versionIdentifier)
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["pending-a", "pending-b"])
        XCTAssertEqual(try query(rowsSQL), originalRows)
    }

    @MainActor
    func testLaterStageDidFailureResumesWithoutRepeatingCompletedStage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationLaterStageRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-later-stage-retry", url: url)])
        source.mainContext.insert(MigrationPlanRecord(name: "first"))
        source.mainContext.insert(MigrationPlanRecord(name: "second"))
        try source.mainContext.save()
        try source.store?.close()

        MigrationStageRecorder.shared.reset()
        MultiStageFailurePlan.failureSwitch.shouldFail = true
        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: MultiStageFailurePlan.self,
                configurations: .sqliteFile("migration-later-stage-retry", url: url))
        ) { error in
            XCTAssertEqual(error as? SwiftDataError, .migrationUnsupported("expected stage 2 destination failure"))
        }
        XCTAssertEqual(
            MigrationStageRecorder.shared.values,
            ["stage1-will", "stage1-did", "stage2-will", "stage2-did"])

        let pendingPlanIdentifier = MultiStageFailurePlan.stages[1].destinationVersion.identifier
        func hex(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        var readOnly = Configuration()
        readOnly.readonly = true
        let pendingDatabase = try DatabaseQueue(path: url.path, configuration: readOnly)
        let pendingMetadata = try pendingDatabase.read { database in
            try String.fetchAll(
                database, sql: "SELECT key || ':' || COALESCE(hex(value), 'NULL') FROM _osd_meta ORDER BY key")
        }
        let encodedDestinationVersion = try MigrationV3.versionIdentifier.encoded()
        XCTAssertTrue(
            pendingMetadata.contains(where: {
                $0 == "schema.version.v1:" + hex(Array(encodedDestinationVersion))
            }),
            "Expected schema.version.v1:\(hex(Array(encodedDestinationVersion))); got \(pendingMetadata)")
        XCTAssertTrue(
            pendingMetadata.contains(where: {
                $0 == "schema.migration.pending.v1:" + hex(Array(pendingPlanIdentifier.utf8))
            }),
            "Expected schema.migration.pending.v1:\(hex(Array(pendingPlanIdentifier.utf8))); got \(pendingMetadata)")
        XCTAssertTrue(pendingMetadata.contains(where: { $0.hasPrefix("schema.hash.v1:") }))
        let pendingRows = try pendingDatabase.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT CAST(Z_PK AS TEXT) || ':' || ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK"
            )
        }
        XCTAssertEqual(pendingRows, ["1:stage1-first", "2:stage1-second"])
        XCTAssertEqual(
            try pendingDatabase.read { database in
                try String.fetchAll(
                    database,
                    sql: "SELECT name FROM pragma_table_info('ZMIGRATIONPLANRECORD') WHERE name = 'ZDETAIL'")
            },
            ["ZDETAIL"])
        XCTAssertEqual(try pendingDatabase.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }, "ok")
        try pendingDatabase.close()

        MultiStageFailurePlan.failureSwitch.shouldFail = false
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: MultiStageFailurePlan.self,
            configurations: .sqliteFile("migration-later-stage-retry", url: url))
        XCTAssertEqual(
            MigrationStageRecorder.shared.values,
            ["stage1-will", "stage1-did", "stage2-will", "stage2-did", "stage2-did"])
        XCTAssertEqual(retried.schema.version, MigrationV3.versionIdentifier)
        XCTAssertEqual(
            try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["stage1-second", "stage2-stage1-first"])
        let completedMetadata = try retried.store?.read { connection in
            try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
        }
        XCTAssertFalse(
            completedMetadata?.contains { row in
                row.first == .text("schema.migration.pending.v1")
            } ?? true)
        try retried.store?.close()
        MigrationStageRecorder.shared.reset()
        let reopened = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: MultiStageFailurePlan.self,
            configurations: .sqliteFile("migration-later-stage-retry-reopen", url: url))
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["stage1-second", "stage2-stage1-first"])
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
        source.mainContext.insert(MigrationPlanRecord(name: "preserved"))
        try source.mainContext.save()
        var readConfiguration = Configuration()
        readConfiguration.readonly = true
        let initialDatabase = try DatabaseQueue(path: url.path, configuration: readConfiguration)
        let originalMetadata = try initialDatabase.read { database in
            try String.fetchAll(
                database, sql: "SELECT key || ':' || COALESCE(hex(value), 'NULL') FROM _osd_meta ORDER BY key")
        }
        let originalRows = try initialDatabase.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT CAST(Z_PK AS TEXT) || ':' || ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK")
        }
        let originalVersion = try initialDatabase.read { database in
            try Data.fetchOne(
                database, sql: "SELECT value FROM _osd_meta WHERE key = ?", arguments: ["schema.version.v1"])
        }
        let encodedOriginalVersion = try XCTUnwrap(originalVersion)
        try initialDatabase.close()
        try source.store?.write { connection in
            try connection.execute(
                "DELETE FROM _osd_meta WHERE key = ?", arguments: [RuntimeValue.text("schema.version.v1")])
        }
        try source.store?.close()
        MigrationStageRecorder.shared.reset()
        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: TestMigrationPlan.self,
                configurations: .sqliteFile("migration-unversioned", url: url))
        ) { error in
            guard case SwiftDataError.migrationUnsupported = error else {
                return XCTFail("Expected migrationUnsupported, got \(error)")
            }
        }
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])
        var verificationConfiguration = Configuration()
        verificationConfiguration.readonly = true
        let verificationDatabase = try DatabaseQueue(path: url.path, configuration: verificationConfiguration)
        let failedMetadata = try verificationDatabase.read { database in
            try String.fetchAll(
                database, sql: "SELECT key || ':' || COALESCE(hex(value), 'NULL') FROM _osd_meta ORDER BY key")
        }
        XCTAssertEqual(failedMetadata, originalMetadata.filter { !$0.hasPrefix("schema.version.v1:") })
        XCTAssertFalse(failedMetadata.contains(where: { $0.hasPrefix("schema.version.v1:") }))
        XCTAssertEqual(
            try verificationDatabase.read { database in
                try String.fetchAll(
                    database,
                    sql: "SELECT CAST(Z_PK AS TEXT) || ':' || ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK")
            },
            originalRows)
        XCTAssertEqual(
            try verificationDatabase.read { database in try String.fetchOne(database, sql: "PRAGMA integrity_check") },
            "ok")
        try verificationDatabase.close()

        var repairConfiguration = Configuration()
        repairConfiguration.readonly = false
        let repairDatabase = try DatabaseQueue(path: url.path, configuration: repairConfiguration)
        try repairDatabase.write { database in
            try database.execute(
                sql: "INSERT INTO _osd_meta (key, value) VALUES (?, ?)",
                arguments: ["schema.version.v1", encodedOriginalVersion])
            XCTAssertEqual(database.changesCount, 1)
        }
        try repairDatabase.close()
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: UnversionedRecoveryPlan.self,
            configurations: .sqliteFile("migration-unversioned", url: url))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["unversioned-recovery-will", "unversioned-recovery-did"])
        XCTAssertEqual(
            try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["preserved"])
        XCTAssertEqual(
            try retried.store?.read { connection in
                try connection.rows("SELECT ZNAME, ZNOTE FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            } ?? nil,
            [[.text("preserved"), .null]])
    }

    @MainActor
    func testMalformedStoredSchemaVersionFailsWithoutMutationAndRecoversAfterRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationMalformedVersion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-malformed-version", url: url)])
        source.mainContext.insert(MigrationPlanRecord(name: "preserved-a"))
        source.mainContext.insert(MigrationPlanRecord(name: "preserved-b"))
        try source.mainContext.save()
        func query(_ sql: String, readOnly: Bool = true) throws -> [String] {
            var configuration = Configuration()
            configuration.readonly = readOnly
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? database.close() }
            return try database.read { try String.fetchAll($0, sql: sql) }
        }
        let metadataSQL = "SELECT key || ':' || COALESCE(hex(value), 'NULL') FROM _osd_meta ORDER BY key"
        let rowsSQL = "SELECT CAST(Z_PK AS TEXT) || ':' || ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK"
        let primaryKeysSQL =
            "SELECT CAST(Z_ENT AS TEXT) || ':' || Z_NAME || ':' || CAST(Z_SUPER AS TEXT) || ':' || CAST(Z_MAX AS TEXT) FROM Z_PRIMARYKEY ORDER BY Z_ENT"
        let tablesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' ORDER BY name"
        let indexesSQL = "SELECT name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE type = 'index' ORDER BY name"
        let originalMetadata = try query(metadataSQL)
        let originalRows = try query(rowsSQL)
        let originalPrimaryKeys = try query(primaryKeysSQL)
        let originalTables = try query(tablesSQL)
        let originalIndexes = try query(indexesSQL)
        let encodedOriginalVersion = try MigrationV1.versionIdentifier.encoded()
        try source.store?.close()

        MigrationStageRecorder.shared.reset()
        let malformedVersion = Data("{\"version\":[1,\"bad\"]".utf8)
        do {
            var configuration = Configuration()
            configuration.readonly = false
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            try database.write { db in
                try db.execute(
                    sql: "UPDATE _osd_meta SET value = ? WHERE key = ?",
                    arguments: [malformedVersion, "schema.version.v1"])
                XCTAssertEqual(db.changesCount, 1)
            }
            try database.close()
        }
        let corruptedMetadata = try query(metadataSQL)
        XCTAssertNotEqual(corruptedMetadata, originalMetadata)

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: TestMigrationPlan.self,
                configurations: .sqliteFile("migration-malformed-version", url: url))
        ) { error in
            XCTAssertEqual(error as? SwiftDataError, .migrationUnsupported("Invalid stored schema version."))
        }
        XCTAssertEqual(MigrationStageRecorder.shared.values, [])
        XCTAssertEqual(try query(metadataSQL), corruptedMetadata)
        XCTAssertEqual(try query(rowsSQL), originalRows)
        XCTAssertEqual(try query(primaryKeysSQL), originalPrimaryKeys)
        XCTAssertEqual(try query(tablesSQL), originalTables)
        XCTAssertEqual(try query(indexesSQL), originalIndexes)

        do {
            var configuration = Configuration()
            configuration.readonly = false
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            try database.write { db in
                try db.execute(
                    sql: "UPDATE _osd_meta SET value = ? WHERE key = ?",
                    arguments: [Data(encodedOriginalVersion), "schema.version.v1"])
                XCTAssertEqual(db.changesCount, 1)
            }
            try database.close()
        }
        XCTAssertEqual(try query(metadataSQL), originalMetadata)
        XCTAssertEqual(try query(rowsSQL), originalRows)

        let migrated = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: VersionRecoveryPlan.self,
            configurations: .sqliteFile("migration-malformed-version", url: url))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["version-recovery-will", "version-recovery-did"])
        XCTAssertEqual(
            try migrated.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["preserved-a", "preserved-b"])
        XCTAssertEqual(
            try migrated.store?.read { connection in
                try connection.rows("SELECT ZNAME, ZNOTE FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            } ?? nil,
            [[.text("preserved-a"), .null], [.text("preserved-b"), .null]])
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
        FailingMigrationPlan.failureSwitch.shouldFail = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-retry", url: url)])
        source.mainContext.insert(MigrationPlanRecord(name: "saved-a"))
        source.mainContext.insert(MigrationPlanRecord(name: "saved-b"))
        try source.mainContext.save()
        let sourceRows = try XCTUnwrap(
            source.store?.read { connection in
                try connection.rows("SELECT Z_PK, ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            } ?? nil)
        let sourceMetadata = try XCTUnwrap(
            source.store?.read { connection in
                try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
            } ?? nil)
        try source.store?.close()

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: FailingMigrationPlan.self,
                configurations: .sqliteFile("migration-retry", url: url))
        ) { error in
            XCTAssertEqual(error as? SwiftDataError, .migrationUnsupported("expected migration failure"))
        }
        let inspection = try OpenSwiftDataSQLite.sqliteFactory(.file(url), MigrationV1.schema)
        XCTAssertEqual(
            try inspection.read { connection in
                try connection.rows("SELECT Z_PK, ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            },
            sourceRows)
        let failedMetadata = try inspection.read { connection in
            try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
        }
        XCTAssertEqual(failedMetadata, sourceMetadata)
        XCTAssertTrue(
            failedMetadata.allSatisfy { row in
                guard row.count > 0, case let .text(key) = row[0] else { return true }
                return key != "schema.migration.pending.v1"
            })
        let sourceVersion = try MigrationV1.versionIdentifier.encoded()
        XCTAssertTrue(
            failedMetadata.contains { row in
                row.count > 1 && row[0] == .text("schema.version.v1") && row[1] == .blob(sourceVersion)
            })
        try inspection.close()

        FailingMigrationPlan.failureSwitch.shouldFail = false
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: FailingMigrationPlan.self,
            configurations: .sqliteFile("migration-retry", url: url))
        XCTAssertEqual(retried.schema.version, MigrationV2.versionIdentifier)
        XCTAssertEqual(
            try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["saved-a", "saved-b"])
    }

    @MainActor
    func testFailedWillMigrateRestoresDeletedRowsBeforeRetry() throws {
        FailingDeleteMigrationPlan.failureSwitch.shouldFail = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationDeleteRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-delete-retry", url: url)])
        let target = MigrationPlanRecord(name: "saved-a")
        source.mainContext.insert(target)
        source.mainContext.insert(MigrationPlanRecord(name: "saved-b"))
        try source.mainContext.save()
        let targetID = try XCTUnwrap(target.persistentModelID)
        let sourceRows = try XCTUnwrap(
            source.store?.read { connection in
                try connection.rows("SELECT Z_PK, ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            } ?? nil)
        let sourceMetadata = try XCTUnwrap(
            source.store?.read { connection in
                try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
            } ?? nil)
        try source.store?.close()

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: FailingDeleteMigrationPlan.self,
                configurations: .sqliteFile("migration-delete-retry", url: url))
        ) { error in
            XCTAssertEqual(error as? SwiftDataError, .migrationUnsupported("expected delete migration failure"))
        }
        let inspection = try OpenSwiftDataSQLite.sqliteFactory(.file(url), MigrationV1.schema)
        XCTAssertEqual(
            try inspection.read { connection in
                try connection.rows("SELECT Z_PK, ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            },
            sourceRows)
        XCTAssertEqual(
            try inspection.read { connection in
                try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
            },
            sourceMetadata)
        try inspection.close()

        FailingDeleteMigrationPlan.failureSwitch.shouldFail = false
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: FailingDeleteMigrationPlan.self,
            configurations: .sqliteFile("migration-delete-retry", url: url))
        XCTAssertEqual(retried.schema.version, MigrationV2.versionIdentifier)
        let rows = try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>())
        XCTAssertEqual(rows.map(\.name).sorted(), ["saved-a", "saved-b"])
        XCTAssertTrue(rows.contains(where: { $0.persistentModelID == targetID }))
    }

    @MainActor
    func testFailedWillMigrateRestoresUpdatedAndInsertedRowsBeforeRetry() throws {
        FailingSourceUpdateMigrationPlan.failureSwitch.shouldFail = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationSourceUpdateRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-source-update-retry", url: url)])
        let first = MigrationPlanRecord(name: "saved-a")
        let second = MigrationPlanRecord(name: "saved-b")
        source.mainContext.insert(first)
        source.mainContext.insert(second)
        try source.mainContext.save()
        let originalIdentifiers = Set([try XCTUnwrap(first.persistentModelID), try XCTUnwrap(second.persistentModelID)])
        let sourceRows = try XCTUnwrap(
            source.store?.read { connection in
                try connection.rows("SELECT Z_PK, ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            } ?? nil)
        let sourceMetadata = try XCTUnwrap(
            source.store?.read { connection in
                try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
            } ?? nil)
        try source.store?.close()

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: FailingSourceUpdateMigrationPlan.self,
                configurations: .sqliteFile("migration-source-update-retry", url: url))
        ) { error in
            XCTAssertEqual(error as? SwiftDataError, .migrationUnsupported("expected source update failure"))
        }
        let inspection = try OpenSwiftDataSQLite.sqliteFactory(.file(url), MigrationV1.schema)
        XCTAssertEqual(
            try inspection.read { connection in
                try connection.rows("SELECT Z_PK, ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
            },
            sourceRows)
        XCTAssertEqual(
            try inspection.read { connection in
                try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
            },
            sourceMetadata)
        try inspection.close()

        FailingSourceUpdateMigrationPlan.failureSwitch.shouldFail = false
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: FailingSourceUpdateMigrationPlan.self,
            configurations: .sqliteFile("migration-source-update-retry", url: url))
        XCTAssertEqual(retried.schema.version, MigrationV2.versionIdentifier)
        let retriedRows = try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>())
        XCTAssertEqual(retriedRows.map(\.name).sorted(), ["saved-a", "saved-b"])
        XCTAssertEqual(Set(retriedRows.map(\.persistentModelID)), originalIdentifiers)
    }

    @MainActor
    func testFailedDidMigrateResumesDestinationCallbackWithoutRepeatingWill() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSwiftDataMigrationDidRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let source = try ModelContainer(
            for: [MigrationPlanRecord.self], schema: MigrationV1.schema,
            configurations: [.sqliteFile("migration-did-retry-source", url: url)])
        source.mainContext.insert(MigrationPlanRecord(name: "saved"))
        source.mainContext.insert(MigrationPlanRecord(name: "second"))
        try source.mainContext.save()
        try source.store?.close()
        MigrationStageRecorder.shared.reset()
        FailingDestinationPlan.failureSwitch.shouldFail = true

        XCTAssertThrowsError(
            try ModelContainer(
                for: MigrationPlanRecord.self, migrationPlan: FailingDestinationPlan.self,
                configurations: .sqliteFile("migration-did-retry", url: url))
        ) { error in
            XCTAssertEqual(error as? SwiftDataError, .migrationUnsupported("expected destination failure"))
        }
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["destination-retry-will"])
        let pendingStore = try OpenSwiftDataSQLite.sqliteFactory(.file(url), MigrationV2.schema)
        let pendingRows = try pendingStore.read { connection in
            try connection.rows("SELECT Z_PK, ZNAME FROM ZMIGRATIONPLANRECORD ORDER BY Z_PK", arguments: [])
        }
        XCTAssertEqual(
            pendingRows.compactMap { row -> String? in
                guard row.count > 1, case let .text(name) = row[1] else { return nil }
                return name
            }.sorted(),
            ["retry", "saved", "second"])
        let pendingMetadata = try pendingStore.read { connection in
            try connection.rows("SELECT key, value FROM _osd_meta ORDER BY key", arguments: [])
        }
        let destinationVersion = try MigrationV2.versionIdentifier.encoded()
        XCTAssertTrue(
            pendingMetadata.contains { row in
                row.count > 1 && row[0] == .text("schema.version.v1")
                    && row[1] == .blob(destinationVersion)
            })
        XCTAssertTrue(
            pendingMetadata.contains { row in
                row.count > 1 && row[0] == .text("schema.migration.pending.v1")
                    && row[1] == .blob(Array(MigrationV2.versionIdentifier.identifier.utf8))
            })
        try pendingStore.close()

        FailingDestinationPlan.failureSwitch.shouldFail = false
        let retried = try ModelContainer(
            for: MigrationPlanRecord.self, migrationPlan: FailingDestinationPlan.self,
            configurations: .sqliteFile("migration-did-retry", url: url))
        XCTAssertEqual(MigrationStageRecorder.shared.values, ["destination-retry-will", "destination-retry-did"])
        XCTAssertEqual(retried.schema.version, MigrationV2.versionIdentifier)
        XCTAssertEqual(
            try retried.mainContext.fetch(FetchDescriptor<MigrationPlanRecord>()).map(\.name).sorted(),
            ["destination-mutated", "retry", "second"])
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
