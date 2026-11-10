import Foundation
import OpenSwiftData
import ParityContracts

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
                    observations.append(try observeNames(in: context, descriptor: descriptor, step: step, field: field))
                } else {
                    var descriptor = FetchDescriptor<MembershipScenarioRow>(
                        predicate: #Predicate { $0.name.isEmpty }, sortBy: sorting(for: specification.sortField))
                    descriptor.includePendingChanges = includesPending
                    observations.append(try observeNames(in: context, descriptor: descriptor, step: step, field: field))
                }
            case let .fetchNamesMatchingNameCharacterCount(field, count, usesGreaterThan):
                if usesGreaterThan {
                    let descriptor = FetchDescriptor<MembershipScenarioRow>(
                        predicate: #Predicate { $0.name.count > count }, sortBy: sorting(for: specification.sortField))
                    observations.append(try observeNames(in: context, descriptor: descriptor, step: step, field: field))
                } else {
                    let descriptor = FetchDescriptor<MembershipScenarioRow>(
                        predicate: #Predicate { $0.name.count == count }, sortBy: sorting(for: specification.sortField))
                    observations.append(try observeNames(in: context, descriptor: descriptor, step: step, field: field))
                }
            case let .fetchNamesMatchingOptionalNickIsEmpty(field, defaultValue):
                let predicate = #Predicate<MembershipScenarioRow> { $0.nick.flatMap { $0.isEmpty } ?? defaultValue }
                let descriptor = FetchDescriptor(predicate: predicate, sortBy: sorting(for: specification.sortField))
                observations.append(try observeNames(in: context, descriptor: descriptor, step: step, field: field))
            case let .fetchNamesMatchingOptionalNickCount(field, minimumCount, defaultValue):
                let predicate = #Predicate<MembershipScenarioRow> { $0.nick.flatMap { $0.count > minimumCount } ?? defaultValue }
                let descriptor = FetchDescriptor(predicate: predicate, sortBy: sorting(for: specification.sortField))
                observations.append(try observeNames(in: context, descriptor: descriptor, step: step, field: field))
            case let .fetchNamesMatchingOptionalNickIsEmptyDirectly(field):
                let descriptor = FetchDescriptor<MembershipScenarioRow>(
                    predicate: #Predicate { $0.nick?.isEmpty == true }, sortBy: sorting(for: specification.sortField))
                observations.append(try observeNames(in: context, descriptor: descriptor, step: step, field: field))
            case .save:
                try context.save()
            }
        }
        return ScenarioResult(id: specification.id, observations: observations)
    }

    public static func runAndValidate(_ specification: PredicateMembershipSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard ScenarioExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    public static func runAll() throws -> [ScenarioResult] {
        let comparablePredicateResults = try ParityScenarioCatalog.all
            .filter { NonComparableScenarios.disposition(for: $0.id) == nil }
            .map(runAndValidate)
        let nonComparablePredicateResults = ParityScenarioCatalog.all
            .filter { NonComparableScenarios.disposition(for: $0.id) != nil }
            .map { specification in
                ScenarioResult(
                    id: specification.id, observations: [],
                    disposition: NonComparableScenarios.disposition(for: specification.id)!)
            }
        let schemaResults = try OSDSchemaIntrospectionAdapter.runAll()
        let modelTypeResults = try OSDSchemaModelTypesAdapter.runAll()
        let storeIdentifierResults = try OSDStoreIdentifierAdapter.runAll()
        let identityResults = try OSDModelIdentityAdapter.runAll()
        let configurationResults = OSDModelConfigurationAdapter.runAll()
        let configurationContainerResults = try OSDModelConfigurationContainerAdapter.runAll()
        let pendingFetchResults = try OSDPendingFetchAdapter.runAll()
        let pendingFetchRelationshipResults = try OSDPendingFetchRelationshipAdapter.runAll()
        let macroArgumentsResults = try OSDMacroArgumentsAdapter.runAll()
        let sortingResults = try OSDSortingParityAdapter.runAll()
        let modelContextInitResults = try OSDModelContextInitAdapter.runAll()
        let modelActorResults = try OSDModelActorParityAdapter.runAll()
        let batchFetchResults = try OSDBatchFetchAdapter.runAll()
        let batchDeleteResults = try OSDBatchDeleteAdapter.runAll()
        let codableResults = try OSDCodableParityAdapter.runAll()
        let contextNotificationResults = try OSDContextNotificationAdapter.runAll()
        let rollbackResults = try OSDRollbackAdapter.runAll()
        let modelContextResults = try OSDModelContextParityAdapter.runAll()
        let historyResults = try OSDHistoryParityAdapter.runAll()
        let uniqueConstraintResults = try OSDUniqueConstraintAdapter.runAll()
        let migrationPlanResults = try OSDMigrationPlanAdapter.runAll()
        let modelContainerParityResults = try OSDModelContainerParityAdapter.runAll()
        let relationshipDeleteRuleResults = try OSDRelationshipDeleteRuleAdapter.runAll()
        return (comparablePredicateResults + nonComparablePredicateResults + schemaResults + modelTypeResults + storeIdentifierResults + identityResults
            + configurationResults + configurationContainerResults + pendingFetchResults
            + pendingFetchRelationshipResults + macroArgumentsResults + sortingResults + modelContextInitResults
            + modelActorResults + batchFetchResults
            + batchDeleteResults + codableResults + contextNotificationResults + rollbackResults + modelContextResults
            + historyResults + uniqueConstraintResults + migrationPlanResults + modelContainerParityResults
            + relationshipDeleteRuleResults)
            .sorted { $0.id.description < $1.id.description }
    }

    private static func observeNames(
        in context: ModelContext,
        descriptor: FetchDescriptor<MembershipScenarioRow>,
        step: Int,
        field: String
    ) throws -> ParityObservation {
        ParityObservation(step: step, field: field, value: .array(try context.fetch(descriptor).map(\.name).map(ObservedValue.string)))
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
