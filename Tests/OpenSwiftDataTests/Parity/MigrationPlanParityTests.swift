import Foundation
import OpenSwiftData
import Testing

enum ParityTripsV1: VersionedSchema {
    static var versionIdentifier: SchemaDescriptor.Version { SchemaDescriptor.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Trip.self] }

    @Model final class Trip {
        var name: String
        init(name: String) { self.name = name }
    }
}

enum ParityTripsV2: VersionedSchema {
    static var versionIdentifier: SchemaDescriptor.Version { SchemaDescriptor.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Trip.self] }

    @Model final class Trip {
        var name: String
        var nights: Int = 1
        init(name: String) { self.name = name }
    }
}

enum ParityTripsPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ParityTripsV1.self, ParityTripsV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: ParityTripsV1.self, toVersion: ParityTripsV2.self, willMigrate: nil,
                didMigrate: { context in
                    for trip in try context.fetch(FetchDescriptor<ParityTripsV2.Trip>()) { trip.nights = 3 }
                    try context.save()
                })
        ]
    }
}

/// Versioned schemas and migration plans written as for Apple's SwiftData.
@MainActor @Suite struct MigrationPlanParityTests {
    @Test func `versioned schemas need only models and a version`() {
        let schema = SchemaDescriptor(versionedSchema: ParityTripsV2.self)
        #expect(schema.version == SchemaDescriptor.Version(2, 0, 0))
        #expect(schema.entities.map(\.name) == ["Trip"])
        #expect(ParityTripsV1.schema.version == SchemaDescriptor.Version(1, 0, 0))
    }

    @Test func `migration stages are enum cases`() {
        let stage = MigrationStage.lightweight(fromVersion: ParityTripsV1.self, toVersion: ParityTripsV2.self)
        guard case .lightweight(let from, let to) = stage else {
            Issue.record("expected a lightweight stage")
            return
        }
        #expect(from.versionIdentifier == SchemaDescriptor.Version(1, 0, 0))
        #expect(to.versionIdentifier == SchemaDescriptor.Version(2, 0, 0))
        guard case .custom(_, _, let willMigrate, let didMigrate) = ParityTripsPlan.stages[0] else {
            Issue.record("expected a custom stage")
            return
        }
        #expect(willMigrate == nil)
        #expect(didMigrate != nil)
    }

    @Test func `containers without a plan report none`() throws {
        let container = try ModelContainer(
            for: ParityTripsV1.Trip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        #expect(container.migrationPlan == nil)
    }

    @Test func `a migration plan upgrades a store and runs its stage callbacks`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osd-plan-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let v1 = try ModelContainer(
                for: SchemaDescriptor(versionedSchema: ParityTripsV1.self), configurations: ModelConfiguration(url: url))
            v1.mainContext.insert(ParityTripsV1.Trip(name: "coast"))
            try v1.mainContext.save()
        }
        let v2 = try ModelContainer(
            for: ParityTripsV2.Trip.self, migrationPlan: ParityTripsPlan.self,
            configurations: ModelConfiguration(url: url))
        #expect(v2.migrationPlan == ParityTripsPlan.self)
        let trips = try v2.mainContext.fetch(FetchDescriptor<ParityTripsV2.Trip>())
        #expect(trips.map(\.name) == ["coast"])
        #expect(trips.map(\.nights) == [3])
    }
}

@MainActor @Suite struct UnversionedStoreMigrationParityTests {
    @Test func `a plan migrates a store created without one`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osd-plan-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let v1 = try ModelContainer(for: ParityTripsV1.Trip.self, configurations: ModelConfiguration(url: url))
            v1.mainContext.insert(ParityTripsV1.Trip(name: "coast"))
            try v1.mainContext.save()
        }
        let v2 = try ModelContainer(
            for: ParityTripsV2.Trip.self, migrationPlan: ParityTripsPlan.self,
            configurations: ModelConfiguration(url: url))
        let trips = try v2.mainContext.fetch(FetchDescriptor<ParityTripsV2.Trip>())
        #expect(trips.map(\.name) == ["coast"])
        #expect(trips.map(\.nights) == [3])
    }
}
