import Foundation
import OpenSwiftData
import OpenSwiftDataSQLite
import Testing

@Model final class SchemaParityTrip {
    var name: String
    var stops: [SchemaParityStop] = []
    init(name: String) { self.name = name }
}

@Model final class SchemaParityStop {
    var label: String
    var trip: SchemaParityTrip?
    init(label: String) { self.label = label }
}

enum SchemaParityV2: VersionedSchema {
    static var versionIdentifier: SchemaDescriptor.Version { SchemaDescriptor.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [SchemaParityTrip.self, SchemaParityStop.self] }
    static var schema: SchemaDescriptor { SchemaDescriptor(models, version: versionIdentifier) }
}

/// Schemas built from model types, as in Xcode's SwiftData templates.
@MainActor @Suite struct SchemaModelTypesParityTests {
    @Test func `a schema built from types lists entities in name order`() {
        let schema = SchemaDescriptor([SchemaParityTrip.self, SchemaParityStop.self])
        #expect(schema.entities.map(\.name) == ["SchemaParityStop", "SchemaParityTrip"])
        #expect(schema.version == SchemaDescriptor.Version(1, 0, 0))
        #expect(SchemaDescriptor(SchemaParityTrip.self, SchemaParityStop.self).entities.count == 2)
    }

    @Test func `a schema includes models reachable only as relationship destinations`() {
        let schema = SchemaDescriptor([SchemaParityTrip.self, SchemaParityStop.self])
        #expect(schema.entity(for: SchemaParityStop.self)?.name == "SchemaParityStop")
        #expect(SchemaDescriptor.entityName(for: SchemaParityTrip.self) == "SchemaParityTrip")
    }

    @Test func `an empty schema has no entities and version 1.0.0`() {
        #expect(SchemaDescriptor().entities.isEmpty)
        #expect(SchemaDescriptor().version == SchemaDescriptor.Version(1, 0, 0))
    }

    @Test func `a versioned schema carries its version`() {
        let schema = SchemaDescriptor(versionedSchema: SchemaParityV2.self)
        #expect(schema.version == SchemaDescriptor.Version(2, 0, 0))
        #expect(schema.entities.count == 2)
    }

    @Test func `a container opened from a type-built schema saves and fetches models`() throws {
        let schema = SchemaDescriptor([SchemaParityTrip.self, SchemaParityStop.self])
        let container = try ModelContainer(for: schema, configurations: [.sqliteMemory("schema-types")])
        let context = container.mainContext
        let trip = SchemaParityTrip(name: "Coast")
        let stop = SchemaParityStop(label: "A")
        context.insert(trip)
        context.insert(stop)
        trip.stops.append(stop)
        try context.save()

        let fresh = ModelContext(container)
        let fetched = try fresh.fetch(FetchDescriptor<SchemaParityTrip>())
        #expect(fetched.map(\.name) == ["Coast"])
        #expect(fetched.first?.stops.map(\.label) == ["A"])
    }
}
