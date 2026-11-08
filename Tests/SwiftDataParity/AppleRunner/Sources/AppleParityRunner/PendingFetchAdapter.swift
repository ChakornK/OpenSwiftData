import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class ApplePendingFetchScenarioRow {
    var name: String
    var age: Int

    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

@MainActor
@available(macOS 15, *)
enum ApplePendingFetchAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try PendingFetchScenarioCatalog.all.map(runAndValidate)
    }

    static func runAndValidate(_ specification: PendingFetchSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard PendingFetchExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    static func run(_ specification: PendingFetchSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: ApplePendingFetchScenarioRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let seedContext = ModelContext(container)
        for row in specification.seedRows {
            seedContext.insert(ApplePendingFetchScenarioRow(name: row.name, age: Int(row.age)))
        }
        try seedContext.save()

        let context = ModelContext(container)
        var observations: [ParityObservation] = []
        for (stepIndex, step) in specification.steps.enumerated() {
            if let change = step.pendingChange {
                try apply(change, for: specification, in: context)
            }
            if let query = step.query {
                observations.append(try observe(query, in: context, step: stepIndex))
            }
        }
        return ScenarioResult(id: specification.id, observations: observations)
    }

    private static func apply(
        _ change: PendingFetchSpecification.PendingChange,
        for specification: PendingFetchSpecification,
        in context: ModelContext
    ) throws {
        switch change {
        case let .insert(row):
            context.insert(ApplePendingFetchScenarioRow(name: row.name, age: Int(row.age)))
        case let .updateAge(name, age):
            let row = try require(name, for: specification, in: context)
            row.age = Int(age)
        case let .delete(name):
            context.delete(try require(name, for: specification, in: context))
        }
    }

    private static func require(
        _ name: String,
        for specification: PendingFetchSpecification,
        in context: ModelContext
    ) throws -> ApplePendingFetchScenarioRow {
        let descriptor = FetchDescriptor<ApplePendingFetchScenarioRow>(
            predicate: #Predicate { $0.name == name })
        guard let row = try context.fetch(descriptor).first else {
            throw ScenarioExpectationError(id: specification.id, observations: [])
        }
        return row
    }

    private static func observe(
        _ query: PendingFetchSpecification.Query,
        in context: ModelContext,
        step: Int
    ) throws -> ParityObservation {
        let predicate: Predicate<ApplePendingFetchScenarioRow>? = switch query.predicate {
        case .none:
            nil
        case let .lessThan(age):
            let age = Int(age)
            #Predicate { $0.age < age }
        case let .greaterThan(age):
            let age = Int(age)
            #Predicate { $0.age > age }
        }
        let sort: [SortDescriptor<ApplePendingFetchScenarioRow>] = switch query.sort {
        case .none:
            []
        case .ageAscending:
            [SortDescriptor(\.age)]
        }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: sort)
        descriptor.fetchLimit = query.limit
        descriptor.fetchOffset = query.offset
        descriptor.includePendingChanges = query.includesPendingChanges

        let value: ObservedValue = switch query.result {
        case .names:
            .array(try context.fetch(descriptor).map { .string($0.name) })
        case .count:
            .integer(Int64(try context.fetchCount(descriptor)))
        case .identifierCount:
            .integer(Int64(try context.fetchIdentifiers(descriptor).count))
        }
        return ParityObservation(step: step, field: query.observationField, value: value)
    }
}
