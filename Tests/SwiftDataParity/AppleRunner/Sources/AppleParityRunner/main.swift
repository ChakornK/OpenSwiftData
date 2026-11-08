import Foundation
import ParityContracts
import SwiftData

@Model
final class MembershipScenarioRow {
    var name: String
    var age: Int

    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

@main
struct AppleParityRunner {
    @MainActor
    static func main() throws {
        let outputURL = outputURL(from: CommandLine.arguments)
        let results = try ParityScenarioCatalog.all.map(run)
        let output = RunnerOutput(
            manifest: RunnerManifest(
                implementation: "apple-swiftdata",
                gitSHA: ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "local",
                scenarios: results.map(\.id)),
            results: results)
        try CanonicalJSON.encode(output).write(to: outputURL, options: .atomic)
        print("Wrote Apple SwiftData observations to \(outputURL.path)")
    }

    @MainActor
    private static func run(_ specification: PredicateMembershipSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: MembershipScenarioRow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        var observations: [ParityObservation] = []
        for (step, operation) in specification.operations.enumerated() {
            switch operation {
            case .insertRows:
                for row in specification.rows {
                    context.insert(MembershipScenarioRow(name: row.name, age: Int(row.age)))
                }
            case let .fetchNamesMatchingCapturedNames(field, includesPending):
                guard specification.sortField == .age else { throw ScenarioAdapterError.unsupportedSortField }
                let capturedNames = specification.capturedNames
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

    private static func outputURL(from arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) else {
            return URL(fileURLWithPath: "apple-observations.json")
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }
}

private enum ScenarioAdapterError: Error {
    case unsupportedSortField
}
