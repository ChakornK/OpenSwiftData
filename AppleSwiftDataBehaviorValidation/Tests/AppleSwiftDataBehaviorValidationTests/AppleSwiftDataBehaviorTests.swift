import Foundation
import SwiftData
import Testing

@Model
final class ValidationRecord {
    var title: String
    var related: ValidationRelated?

    init(title: String, related: ValidationRelated? = nil) {
        self.title = title
        self.related = related
    }
}

@Model
final class ValidationRelated {
    var count: Int
    var records: [ValidationRecord] = []

    init(count: Int) { self.count = count }
}

@Model
final class UniqueValidationRecord {
    @Attribute(.unique) var key: String
    var score: Int

    init(key: String, score: Int) {
        self.key = key
        self.score = score
    }
}

@Model
final class BatchValidationRecord {
    var name: String
    init(name: String) { self.name = name }
}

private struct ValidationConfiguration: DataStoreConfiguration, Hashable {
    typealias Store = ValidationStore
    var name: String
    var schema: Schema?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

private struct ValidationSnapshot: DataStoreSnapshot {
    let persistentIdentifier: PersistentIdentifier
    let title: String?
    let count: Int?
    let related: PersistentIdentifier?
    let records: [PersistentIdentifier]

    init(from backingData: any BackingData, relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) {
        guard let identifier = backingData.persistentModelID else {
            preconditionFailure("BackingData has no persistent identifier")
        }
        persistentIdentifier = identifier
        if identifier.entityName == "ValidationRecord",
            let recordBacking = backingData as? any BackingData<ValidationRecord>
        {
            title = recordBacking.getValue(forKey: \ValidationRecord.title)
            count = nil
            let relatedModel = recordBacking.getValue(forKey: \ValidationRecord.related)
            related = relatedModel?.persistentModelID
            records = []
            if let relatedModel { relatedBackingDatas[relatedModel.persistentModelID] = relatedModel.persistentBackingData }
        } else if identifier.entityName == "ValidationRelated",
            let relatedBacking = backingData as? any BackingData<ValidationRelated>
        {
            title = nil
            count = relatedBacking.getValue(forKey: \ValidationRelated.count)
            related = nil
            let recordModels = relatedBacking.getValue(forKey: \ValidationRelated.records)
            records = recordModels.map(\.persistentModelID)
            for record in recordModels {
                relatedBackingDatas[record.persistentModelID] = record.persistentBackingData
            }
        } else {
            title = nil
            count = nil
            related = nil
            records = []
        }
    }

    func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> Self {
        Self(
            persistentIdentifier: remappedIdentifiers?[self.persistentIdentifier] ?? persistentIdentifier,
            title: title,
            count: count,
            related: related.flatMap { remappedIdentifiers?[$0] ?? $0 },
            records: records.map { remappedIdentifiers?[$0] ?? $0 })
    }

    private init(
        persistentIdentifier: PersistentIdentifier,
        title: String?,
        count: Int?,
        related: PersistentIdentifier?,
        records: [PersistentIdentifier]
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.title = title
        self.count = count
        self.related = related
        self.records = records
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DataStoreSnapshotCodingKey.self)
        persistentIdentifier = try values.decode(PersistentIdentifier.self, forKey: .persistentIdentifier)
        title = try values.decodeIfPresent(String.self, forKey: .modeledProperty("title"))
        count = try values.decodeIfPresent(Int.self, forKey: .modeledProperty("count"))
        related = try values.decodeIfPresent(PersistentIdentifier.self, forKey: .modeledProperty("related"))
        records = try values.decodeIfPresent([PersistentIdentifier].self, forKey: .modeledProperty("records")) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: DataStoreSnapshotCodingKey.self)
        try values.encode(persistentIdentifier, forKey: .persistentIdentifier)
        if let title {
            try values.encode(title, forKey: .modeledProperty("title"))
            try values.encodeIfPresent(related, forKey: .modeledProperty("related"))
        }
        if let count {
            try values.encode(count, forKey: .modeledProperty("count"))
            try values.encode(records, forKey: .modeledProperty("records"))
        }
    }
}

private final class ValidationStore: DataStore {
    typealias Configuration = ValidationConfiguration
    typealias Snapshot = ValidationSnapshot
    let configuration: Configuration
    let identifier: String
    var schema: Schema { configuration.schema ?? Schema() }
    private let lock = NSLock()
    private var snapshots: [PersistentIdentifier: Snapshot] = [:]

    required init(_ configuration: Configuration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
        identifier = configuration.name
    }

    func fetch<Model: PersistentModel>(
        _ request: DataStoreFetchRequest<Model>
    ) throws -> DataStoreFetchResult<Model, Snapshot> {
        lock.lock(); defer { lock.unlock() }
        return DataStoreFetchResult(
            descriptor: request.descriptor,
            fetchedSnapshots: snapshots.values.filter {
                $0.persistentIdentifier.entityName == String(describing: Model.self)
            },
            relatedSnapshots: snapshots)
    }

    func save(_ request: DataStoreSaveChangesRequest<Snapshot>) throws -> DataStoreSaveChangesResult<Snapshot> {
        lock.lock(); defer { lock.unlock() }
        var remappings: [PersistentIdentifier: PersistentIdentifier] = [:]
        for snapshot in request.inserted {
            remappings[snapshot.persistentIdentifier] = try PersistentIdentifier.identifier(
                for: identifier,
                entityName: snapshot.persistentIdentifier.entityName,
                primaryKey: UUID())
        }
        var candidate = snapshots
        for snapshot in request.deleted { candidate.removeValue(forKey: snapshot.persistentIdentifier) }
        for snapshot in request.inserted + request.updated {
            let permanent = remappings[snapshot.persistentIdentifier] ?? snapshot.persistentIdentifier
            let copied = snapshot.copy(persistentIdentifier: permanent, remappedIdentifiers: remappings)
            candidate[copied.persistentIdentifier] = copied
        }
        snapshots = candidate
        return DataStoreSaveChangesResult<Snapshot>(for: identifier, remappedIdentifiers: remappings)
    }

    func snapshot(for identifier: PersistentIdentifier) throws -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[identifier]
    }
}

@Suite("Apple SwiftData behavior")
struct AppleSwiftDataBehaviorTests {
    @Test func modeledPropertyKeyRepresentation() {
        #expect(DataStoreSnapshotCodingKey.modeledProperty("title").stringValue == "title")
        #expect(DataStoreSnapshotCodingKey(stringValue: "title").map {
            if case .modeledProperty("title") = $0 { true } else { false }
        } == true)
    }

    @MainActor
    @Test func customSnapshotMaterializesRelationships() throws {
        let schema = Schema([ValidationRecord.self, ValidationRelated.self])
        let configuration = ValidationConfiguration(name: "apple-snapshot-validation", schema: schema)
        let container = try ModelContainer(
            for: schema, configurations: [configuration])
        let related = ValidationRelated(count: 7)
        let record = ValidationRecord(title: "apple-runtime", related: related)
        let context = ModelContext(container)
        context.insert(record)
        try context.save()

        let fetched = try #require(ModelContext(container).fetch(FetchDescriptor<ValidationRecord>()).first)
        #expect(fetched.title == "apple-runtime")
        #expect(fetched.related?.count == 7)
        #expect(fetched.related?.records.map(\.title) == ["apple-runtime"])
    }

    @MainActor
    @Test func schemaIntrospectionMatchesModelDeclarations() throws {
        let schema = Schema([ValidationRecord.self, ValidationRelated.self])
        let recordEntity = try #require(schema.entities.first { $0.name == "ValidationRecord" })
        let relatedEntity = try #require(schema.entities.first { $0.name == "ValidationRelated" })

        #expect(Set(recordEntity.attributes.map(\.name)) == ["title"])
        #expect(Set(recordEntity.relationships.map(\.name)) == ["related"])
        #expect(recordEntity.attributes.first { $0.name == "title" }?.valueType == String.self)
        #expect(relatedEntity.attributes.first { $0.name == "count" }?.valueType == Int.self)
    }

    @MainActor
    @Test func contextFetchPredicateSortUpdateAndDelete() throws {
        let container = try ModelContainer(for: ValidationRecord.self)
        let context = ModelContext(container)
        context.insert(ValidationRecord(title: "Cedar"))
        context.insert(ValidationRecord(title: "Alder"))
        context.insert(ValidationRecord(title: "Birch"))
        try context.save()

        var descriptor = FetchDescriptor<ValidationRecord>(
            predicate: #Predicate { $0.title != "Birch" },
            sortBy: [SortDescriptor(\.title)])
        let matching = try context.fetch(descriptor)
        #expect(matching.map(\.title) == ["Alder", "Cedar"])

        let cedar = try #require(matching.first { $0.title == "Cedar" })
        cedar.title = "Dogwood"
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ValidationRecord>()) == 3)

        descriptor.fetchLimit = 1
        #expect(try context.fetch(descriptor).map(\.title) == ["Alder"])

        context.delete(cedar)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<ValidationRecord>()).map(\.title).sorted() == ["Alder", "Birch"])
    }

    @MainActor
    @Test func uniqueAttributeMaintainsSingleLogicalRecord() throws {
        let container = try ModelContainer(for: UniqueValidationRecord.self)
        let context = ModelContext(container)
        context.insert(UniqueValidationRecord(key: "same", score: 1))
        try context.save()
        context.insert(UniqueValidationRecord(key: "same", score: 2))
        try context.save()

        let records = try context.fetch(FetchDescriptor<UniqueValidationRecord>())
        #expect(records.count == 1)
        #expect(records.first?.score == 2)
    }

    @MainActor
    @Test func rollbackRestoresSavedValuesAndRelationships() throws {
        let container = try ModelContainer(for: ValidationRecord.self, ValidationRelated.self)
        let context = ModelContext(container)
        let related = ValidationRelated(count: 10)
        let record = ValidationRecord(title: "committed", related: related)
        context.insert(record)
        try context.save()

        record.title = "uncommitted"
        record.related = nil
        context.rollback()

        #expect(record.title == "committed")
        #expect(record.related?.count == 10)
        #expect(try ModelContext(container).fetch(FetchDescriptor<ValidationRecord>()).first?.title == "committed")
    }

    @MainActor
    @Test func batchFetchAndDeleteRespectPredicateAndLimits() throws {
        let container = try ModelContainer(for: BatchValidationRecord.self)
        let context = ModelContext(container)
        for name in ["Alder", "Birch", "Cedar", "Dogwood"] {
            context.insert(BatchValidationRecord(name: name))
        }
        try context.save()

        var descriptor = FetchDescriptor<BatchValidationRecord>(
            predicate: #Predicate { $0.name >= "Birch" },
            sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = 2
        let batch = try context.fetch(descriptor, batchSize: 2)
        #expect(batch.map(\.name) == ["Birch", "Cedar"])

        try context.delete(model: BatchValidationRecord.self, where: #Predicate { $0.name == "Birch" })
        #expect(try context.fetchCount(FetchDescriptor<BatchValidationRecord>()) == 3)
        #expect(try context.fetch(FetchDescriptor<BatchValidationRecord>(sortBy: [SortDescriptor(\.name)])).map(\.name)
            == ["Alder", "Cedar", "Dogwood"])
    }
}
