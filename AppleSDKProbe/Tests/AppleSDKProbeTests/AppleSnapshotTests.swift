import Foundation
import SwiftData
import Testing

@Model
final class ProbeRecord {
    var title: String
    var related: ProbeRelated?

    init(title: String, related: ProbeRelated? = nil) {
        self.title = title
        self.related = related
    }
}

@Model
final class ProbeRelated {
    var count: Int
    var records: [ProbeRecord] = []

    init(count: Int) { self.count = count }
}

private struct ProbeConfiguration: DataStoreConfiguration, Hashable {
    typealias Store = ProbeStore
    var name: String
    var schema: Schema?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

private struct ProbeSnapshot: DataStoreSnapshot {
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
        if identifier.entityName == "ProbeRecord",
            let recordBacking = backingData as? any BackingData<ProbeRecord>
        {
            title = recordBacking.getValue(forKey: \ProbeRecord.title)
            count = nil
            let relatedModel = recordBacking.getValue(forKey: \ProbeRecord.related)
            related = relatedModel?.persistentModelID
            records = []
            if let relatedModel { relatedBackingDatas[relatedModel.persistentModelID] = relatedModel.persistentBackingData }
        } else if identifier.entityName == "ProbeRelated",
            let relatedBacking = backingData as? any BackingData<ProbeRelated>
        {
            title = nil
            count = relatedBacking.getValue(forKey: \ProbeRelated.count)
            related = nil
            let recordModels = relatedBacking.getValue(forKey: \ProbeRelated.records)
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
        try values.encodeIfPresent(title, forKey: .modeledProperty("title"))
        try values.encodeIfPresent(count, forKey: .modeledProperty("count"))
        try values.encodeIfPresent(related, forKey: .modeledProperty("related"))
        try values.encode(records, forKey: .modeledProperty("records"))
    }
}

private final class ProbeStore: DataStore {
    typealias Configuration = ProbeConfiguration
    typealias Snapshot = ProbeSnapshot
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

@Suite("Apple SwiftData snapshot probe")
struct AppleSnapshotTests {
    @Test func modeledPropertyKeyRepresentation() {
        #expect(DataStoreSnapshotCodingKey.modeledProperty("title").stringValue == "title")
        #expect(DataStoreSnapshotCodingKey(stringValue: "title").map {
            if case .modeledProperty("title") = $0 { true } else { false }
        } == true)
    }

    @MainActor
    @Test func customSnapshotMaterializesRelationships() throws {
        let schema = Schema([ProbeRecord.self, ProbeRelated.self])
        let configuration = ProbeConfiguration(name: "apple-snapshot-probe", schema: schema)
        let container = try ModelContainer(
            for: schema, configurations: [configuration])
        let related = ProbeRelated(count: 7)
        let record = ProbeRecord(title: "apple-runtime", related: related)
        let context = ModelContext(container)
        context.insert(record)
        try context.save()

        let fetched = try #require(ModelContext(container).fetch(FetchDescriptor<ProbeRecord>()).first)
        #expect(fetched.title == "apple-runtime")
        #expect(fetched.related?.count == 7)
    }
}
