import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class MembershipScenarioRow {
    var name: String
    var age: Int

    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

@MainActor
public enum OSDScenarioAdapter {
    public static func run(_ specification: PredicateMembershipSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: MembershipScenarioRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var observations: [ParityObservation] = []
        for (step, operation) in specification.operations.enumerated() {
            switch operation {
            case .insertRows:
                for row in specification.rows {
                    context.insert(MembershipScenarioRow(name: row.name, age: Int(row.age)))
                }
            case let .fetchNamesMatchingCapturedNames(field, includesPending):
                let capturedNames = specification.capturedNames
                guard specification.sortField == .age else { throw ScenarioAdapterError.unsupportedSortField }
                var descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { capturedNames.contains($0.name) },
                    sortBy: [SortDescriptor(\.age)])
                descriptor.includePendingChanges = includesPending
                let names = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(names.map(ObservedValue.string))))
            case let .fetchNamesMatchingArrayLiteralBD(field, includesPending):
                guard specification.sortField == .age else { throw ScenarioAdapterError.unsupportedSortField }
                var descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { ["b", "d"].contains($0.name) },
                    sortBy: [SortDescriptor(\.age)])
                descriptor.includePendingChanges = includesPending
                let names = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(names.map(ObservedValue.string))))
            case let .fetchNamesNotMatchingCapturedNames(field, names, includesPending):
                var descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { !names.contains($0.name) }, sortBy: [SortDescriptor(\.age)])
                descriptor.includePendingChanges = includesPending
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .fetchNamesMatchingAges(field, ages, includesPending):
                var descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { ages.contains($0.age) }, sortBy: [SortDescriptor(\.age)])
                descriptor.includePendingChanges = includesPending
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .fetchNamesMatchingNamesOrAge(field, names, minimumAge, includesPending):
                var descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { names.contains($0.name) || $0.age > minimumAge },
                    sortBy: [SortDescriptor(\.age)])
                descriptor.includePendingChanges = includesPending
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .countNamesMatchingCapturedNames(field):
                let names = specification.capturedNames
                let count = try context.fetchCount(
                    FetchDescriptor<MembershipScenarioRow>(predicate: #Predicate { names.contains($0.name) }))
                observations.append(ParityObservation(step: step, field: field, value: .integer(Int64(count))))
            case .save:
                try context.save()
            }
        }
        return ScenarioResult(id: specification.id, observations: observations)
    }

    public static func runAndValidate(_ specification: PredicateMembershipSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        let observed = Dictionary(uniqueKeysWithValues: result.observations.map { ($0.field, $0.value) })
        guard observed == specification.expectedObservations else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    public static func runAll() throws -> [ScenarioResult] {
        try ParityScenarioCatalog.all.map(runAndValidate).sorted { $0.id.description < $1.id.description }
    }
}

private enum ScenarioAdapterError: Error {
    case unsupportedSortField
}

public struct ScenarioExpectationError: Error, CustomStringConvertible {
    public let id: ScenarioID
    public let observations: [ParityObservation]

    public var description: String { "Scenario \(id) produced unexpected observations: \(observations)" }
}
