import Foundation
import ParityContracts
import SwiftData

enum AppleParityTripsV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Trip.self] }

    @Model final class Trip {
        var name: String
        init(name: String) { self.name = name }
    }
}

enum AppleParityTripsV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Trip.self] }

    @Model final class Trip {
        var name: String
        var nights: Int = 1
        init(name: String) { self.name = name }
    }
}

enum AppleParityTripsPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [AppleParityTripsV1.self, AppleParityTripsV2.self] }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: AppleParityTripsV1.self,
                toVersion: AppleParityTripsV2.self,
                willMigrate: nil,
                didMigrate: { context in
                    for trip in try context.fetch(FetchDescriptor<AppleParityTripsV2.Trip>()) { trip.nights = 3 }
                    try context.save()
                })
        ]
    }
}

@MainActor
enum AppleMigrationPlanAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try MigrationPlanScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: MigrationPlanSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard MigrationPlanExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: MigrationPlanSpecification) throws -> ScenarioResult {
        let values: [String: ObservedValue]
        switch specification.query {
        case .versionedSchemas:
            let schema = Schema(versionedSchema: AppleParityTripsV2.self)
            values = [
                "versionMatchesV2": .bool(schema.version == Schema.Version(2, 0, 0)),
                "entityNames": .stringSet(schema.entities.map(\.name)),
                "v1VersionMatchesV1": .bool(
                    AppleParityTripsV1.versionIdentifier == Schema.Version(1, 0, 0)),
            ]
        case .stages:
            let stage = MigrationStage.lightweight(
                fromVersion: AppleParityTripsV1.self, toVersion: AppleParityTripsV2.self)
            let stageValues: [String: ObservedValue]
            if case .lightweight(let from, let to) = stage {
                stageValues = [
                    "lightweightStage": .bool(true),
                    "lightweightFromMatchesV1": .bool(
                        from.versionIdentifier == Schema.Version(1, 0, 0)),
                    "lightweightToMatchesV2": .bool(
                        to.versionIdentifier == Schema.Version(2, 0, 0)),
                ]
            } else {
                stageValues = [
                    "lightweightStage": .bool(false), "lightweightFromMatchesV1": .bool(false),
                    "lightweightToMatchesV2": .bool(false),
                ]
            }
            let customStage: Bool
            let willMigrateAbsent: Bool
            let didMigratePresent: Bool
            if case .custom(_, _, let willMigrate, let didMigrate) = AppleParityTripsPlan.stages[0] {
                customStage = true
                willMigrateAbsent = willMigrate == nil
                didMigratePresent = didMigrate != nil
            } else {
                customStage = false
                willMigrateAbsent = false
                didMigratePresent = false
            }
            values = stageValues.merging([
                "customStage": .bool(customStage),
                "willMigrateAbsent": .bool(willMigrateAbsent),
                "didMigratePresent": .bool(didMigratePresent),
            ]) { _, new in new }
        case .noPlan:
            let container = try ModelContainer(
                for: AppleParityTripsV1.Trip.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            values = ["migrationPlanAbsent": .bool(container.migrationPlan == nil)]
        case .plannedUpgrade:
            values = try upgradedValues(versioned: true)
        case .unversionedUpgrade:
            values = try upgradedValues(versioned: false)
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { field in
                ParityObservation(step: 0, field: field, value: values[field]!)
            })
    }

    private static func upgradedValues(versioned: Bool) throws -> [String: ObservedValue] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "parity-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "store.sqlite")

        try createOldStore(at: url, versioned: versioned)

        let upgraded = try ModelContainer(
            for: AppleParityTripsV2.Trip.self,
            migrationPlan: AppleParityTripsPlan.self,
            configurations: ModelConfiguration(url: url))
        let trips = try upgraded.mainContext.fetch(FetchDescriptor<AppleParityTripsV2.Trip>())
        var values: [String: ObservedValue] = [
            "tripNames": .array(trips.map { .string($0.name) }),
            "tripNights": .array(trips.map { .integer(Int64($0.nights)) }),
        ]
        if versioned { values["migrationPlanMatches"] = .bool(upgraded.migrationPlan == AppleParityTripsPlan.self) }
        return values
    }

    private static func createOldStore(at url: URL, versioned: Bool) throws {
        if versioned {
            let old = try ModelContainer(
                for: Schema(versionedSchema: AppleParityTripsV1.self),
                configurations: ModelConfiguration(url: url))
            old.mainContext.insert(AppleParityTripsV1.Trip(name: "coast"))
            try old.mainContext.save()
        } else {
            let old = try ModelContainer(
                for: AppleParityTripsV1.Trip.self, configurations: ModelConfiguration(url: url))
            old.mainContext.insert(AppleParityTripsV1.Trip(name: "coast"))
            try old.mainContext.save()
        }
    }
}
