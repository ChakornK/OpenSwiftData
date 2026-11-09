import OpenSwiftData
import ParityContracts

@Model
final class PendingFetchScenarioRow {
    var name: String
    var age: Int

    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

@MainActor
public enum OSDPendingFetchAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try PendingFetchScenarioCatalog.all.map(runAndValidate)
    }

    public static func runAndValidate(_ specification: PendingFetchSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard PendingFetchExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    public static func run(_ specification: PendingFetchSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: PendingFetchScenarioRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let seedContext = ModelContext(container)
        for row in specification.seedRows {
            seedContext.insert(PendingFetchScenarioRow(name: row.name, age: Int(row.age)))
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
            context.insert(PendingFetchScenarioRow(name: row.name, age: Int(row.age)))
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
    ) throws -> PendingFetchScenarioRow {
        let descriptor = FetchDescriptor<PendingFetchScenarioRow>(
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
        let predicate: Predicate<PendingFetchScenarioRow>?
        switch query.predicate {
        case nil:
            predicate = nil
        case let .some(.lessThan(value)):
            let age = Int(value)
            predicate = #Predicate { $0.age < age }
        case let .some(.greaterThan(value)):
            let age = Int(value)
            predicate = #Predicate { $0.age > age }
        }
        let sort: [SortDescriptor<PendingFetchScenarioRow>] = switch query.sort {
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
