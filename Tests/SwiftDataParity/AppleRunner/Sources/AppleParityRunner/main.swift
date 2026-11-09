import Foundation
import ParityContracts
import SwiftData

@Model
final class MembershipScenarioRow {
    var name: String
    var age: Int
    var nick: String?

    init(name: String, age: Int, nick: String? = nil) {
        self.name = name
        self.age = age
        self.nick = nick
    }
}

struct AppleParityRunner {
    @MainActor
    static func run() throws {
        if CommandLine.arguments.contains("--batch-delete-probe") {
            let observations = try AppleBatchDeleteProbe.run()
            let data = try CanonicalJSON.encode(observations)
            try data.write(to: outputURL(from: CommandLine.arguments), options: .atomic)
            print("Wrote Apple batch-delete probe observations")
            return
        }
        if CommandLine.arguments.contains("--batch-fetch-probe") {
            let observations = try AppleBatchFetchProbe.run()
            let data = try CanonicalJSON.encode(observations)
            try data.write(to: outputURL(from: CommandLine.arguments), options: .atomic)
            print("Wrote Apple batch-fetch probe observations")
            return
        }
        if CommandLine.arguments.contains("--batch-delete-probe") {
            let observations = try AppleBatchDeleteProbe.run()
            let data = try CanonicalJSON.encode(observations)
            try data.write(to: outputURL(from: CommandLine.arguments), options: .atomic)
            print("Wrote Apple batch-delete probe observations")
            return
        }

        let outputURL = outputURL(from: CommandLine.arguments)
        let predicateResults = try ParityScenarioCatalog.all.map(run)
        let schemaResults = try AppleSchemaIntrospectionAdapter.runAll()
        guard #available(macOS 26, *) else {
            throw NSError(
                domain: "AppleParityRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Schema model-type parity requires macOS 26 or newer."])
        }
        let modelTypeResults = try AppleSchemaModelTypesAdapter.runAll()
        let storeIdentifierResults = try AppleStoreIdentifierAdapter.runAll()
        let identityResults = try AppleModelIdentityAdapter.runAll()
        let configurationResults = AppleModelConfigurationAdapter.runAll()
        let configurationContainerResults = try AppleModelConfigurationContainerAdapter.runAll()
        let pendingFetchResults = try ApplePendingFetchAdapter.runAll()
        let batchFetchResults = try AppleBatchFetchAdapter.runAll()
        let batchDeleteResults = try AppleBatchDeleteAdapter.runAll()
        let results = (predicateResults + schemaResults + modelTypeResults + storeIdentifierResults + identityResults
            + configurationResults + configurationContainerResults + pendingFetchResults + batchFetchResults
            + batchDeleteResults)
            .sorted { $0.id.description < $1.id.description }
        let output = RunnerOutput(
            manifest: RunnerManifest(
                schemaVersion: 2,
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
                    context.insert(MembershipScenarioRow(name: row.name, age: Int(row.age), nick: row.nick))
                }
            case let .fetchNamesMatchingCapturedNames(field, includesPending):
                let capturedNames = specification.capturedNames
                var descriptor = makeDescriptor(
                    #Predicate { capturedNames.contains($0.name) }, sortField: specification.sortField)
                descriptor.includePendingChanges = includesPending
                let names = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(names.map(ObservedValue.string))))
            case let .fetchNamesMatchingArrayLiteralBD(field, includesPending):
                var descriptor = makeDescriptor(
                    #Predicate { ["b", "d"].contains($0.name) }, sortField: specification.sortField)
                descriptor.includePendingChanges = includesPending
                let names = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(names.map(ObservedValue.string))))
            case let .fetchNamesNotMatchingCapturedNames(field, names, includesPending):
                var descriptor = makeDescriptor(
                    #Predicate { !names.contains($0.name) }, sortField: specification.sortField)
                descriptor.includePendingChanges = includesPending
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .fetchNamesMatchingAges(field, ages, includesPending):
                var descriptor = makeDescriptor(
                    #Predicate { ages.contains($0.age) }, sortField: specification.sortField)
                descriptor.includePendingChanges = includesPending
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .fetchNamesMatchingNamesOrAge(field, names, minimumAge, includesPending):
                var descriptor = makeDescriptor(
                    #Predicate { names.contains($0.name) || $0.age > minimumAge }, sortField: specification.sortField)
                descriptor.includePendingChanges = includesPending
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .countNamesMatchingCapturedNames(field):
                let names = specification.capturedNames
                let count = try context.fetchCount(
                    FetchDescriptor<MembershipScenarioRow>(predicate: #Predicate { names.contains($0.name) }))
                observations.append(ParityObservation(step: step, field: field, value: .integer(Int64(count))))
            case let .countNamesMatchingNonEmptyNames(field):
                let count = try context.fetchCount(
                    FetchDescriptor<MembershipScenarioRow>(predicate: #Predicate { !$0.name.isEmpty }))
                observations.append(ParityObservation(step: step, field: field, value: .integer(Int64(count))))
            case let .fetchNameSetMatchingNameCharacterCount(field, count):
                let descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { $0.name.count == count }, sortBy: sorting(for: specification.sortField))
                let names = try context.fetch(descriptor).map(\.name)
                observations.append(ParityObservation(step: step, field: field, value: .stringSet(names)))
            case let .fetchNameSetMatchingOptionalNickCount(field, minimumCount, defaultValue):
                let predicate = #Predicate<MembershipScenarioRow> { $0.nick.flatMap { $0.count > minimumCount } ?? defaultValue }
                let descriptor = FetchDescriptor(predicate: predicate, sortBy: sorting(for: specification.sortField))
                let names = try context.fetch(descriptor).map(\.name)
                observations.append(ParityObservation(step: step, field: field, value: .stringSet(names)))
            case let .fetchNamesMatchingNameIsEmpty(field, negated, includesPending):
                if negated {
                    var descriptor = FetchDescriptor<MembershipScenarioRow>(
                        predicate: #Predicate { !$0.name.isEmpty }, sortBy: sorting(for: specification.sortField))
                    descriptor.includePendingChanges = includesPending
                    let values = try context.fetch(descriptor).map(\.name)
                    observations.append(
                        ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
                } else {
                    var descriptor = FetchDescriptor<MembershipScenarioRow>(
                        predicate: #Predicate { $0.name.isEmpty }, sortBy: sorting(for: specification.sortField))
                    descriptor.includePendingChanges = includesPending
                    let values = try context.fetch(descriptor).map(\.name)
                    observations.append(
                        ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
                }
            case let .fetchNamesMatchingNameCharacterCount(field, count, usesGreaterThan):
                if usesGreaterThan {
                    let descriptor = FetchDescriptor<MembershipScenarioRow>(
                        predicate: #Predicate { $0.name.count > count }, sortBy: sorting(for: specification.sortField))
                    let values = try context.fetch(descriptor).map(\.name)
                    observations.append(
                        ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
                } else {
                    let descriptor = FetchDescriptor<MembershipScenarioRow>(
                        predicate: #Predicate { $0.name.count == count }, sortBy: sorting(for: specification.sortField))
                    let values = try context.fetch(descriptor).map(\.name)
                    observations.append(
                        ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
                }
            case let .fetchNamesMatchingOptionalNickIsEmpty(field, defaultValue):
                let predicate = #Predicate<MembershipScenarioRow> { $0.nick.flatMap { $0.isEmpty } ?? defaultValue }
                let descriptor = FetchDescriptor(predicate: predicate, sortBy: sorting(for: specification.sortField))
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .fetchNamesMatchingOptionalNickCount(field, minimumCount, defaultValue):
                let predicate = #Predicate<MembershipScenarioRow> { $0.nick.flatMap { $0.count > minimumCount } ?? defaultValue }
                let descriptor = FetchDescriptor(predicate: predicate, sortBy: sorting(for: specification.sortField))
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
            case let .fetchNamesMatchingOptionalNickIsEmptyDirectly(field):
                let descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { $0.nick?.isEmpty == true }, sortBy: sorting(for: specification.sortField))
                let values = try context.fetch(descriptor).map(\.name)
                observations.append(
                    ParityObservation(step: step, field: field, value: .array(values.map(ObservedValue.string))))
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
    private static func makeDescriptor(
        _ predicate: Predicate<MembershipScenarioRow>, sortField: PredicateMembershipSpecification.SortField
    ) -> FetchDescriptor<MembershipScenarioRow> {
        FetchDescriptor(predicate: predicate, sortBy: sorting(for: sortField))
    }

    private static func sorting(
        for sortField: PredicateMembershipSpecification.SortField
    ) -> [SortDescriptor<MembershipScenarioRow>] {
        switch sortField {
        case .age: [SortDescriptor(\.age)]
        case .name: [SortDescriptor(\.name)]
        }
    }
}

try AppleParityRunner.run()
