import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class ContextParityModel {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
@available(macOS 15, *)
enum AppleModelContextParityAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try ModelContextParityScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: ModelContextParitySpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard ModelContextParityExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: ModelContextParitySpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: ContextParityModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var values: [String: ObservedValue]

        switch specification.query {
        case .temporaryModelLookup:
            let model = ContextParityModel(name: "a")
            context.insert(model)
            let beforeSave = context.model(for: model.persistentModelID) === model
            try context.save()
            values = [
                "sameInstanceBeforeSave": .bool(beforeSave),
                "sameInstanceAfterSave": .bool(context.model(for: model.persistentModelID) === model),
            ]
        case .crossContextModelLookup:
            let model = ContextParityModel(name: "a")
            context.insert(model)
            try context.save()
            let other = ModelContext(container)
            let loaded = other.model(for: model.persistentModelID)
            let typed = loaded as? ContextParityModel
            let registered = other.registeredModel(for: model.persistentModelID) as ContextParityModel?
            values = [
                "name": .string(typed?.name ?? ""), "attachedToOtherContext": .bool(typed?.modelContext === other),
                "unchanged": .bool(typed.map { !$0.hasChanges } ?? false),
                "notDeleted": .bool(typed.map { !$0.isDeleted } ?? false),
                "lookupStable": .bool(other.model(for: model.persistentModelID) === loaded),
                "registeredLookupStable": .bool(registered === typed),
            ]
        case .processPendingChanges:
            context.insert(ContextParityModel(name: "b"))
            context.processPendingChanges()
            values = [
                "hasChanges": .bool(context.hasChanges),
                "insertedCount": .integer(Int64(context.insertedModelsArray.count)),
            ]
        case .transactionSavesChanges:
            context.insert(ContextParityModel(name: "before"))
            try context.transaction { context.insert(ContextParityModel(name: "inside")) }
            var saved = FetchDescriptor<ContextParityModel>()
            saved.includePendingChanges = false
            values = [
                "hasChangesAfterTransaction": .bool(context.hasChanges),
                "savedCount": .integer(Int64(try context.fetchCount(saved))),
            ]
        case .deletedInsertionState:
            let model = ContextParityModel(name: "p")
            context.insert(model)
            context.delete(model)
            let deletedBeforeSave = model.isDeleted
            let attachedBeforeSave = model.modelContext === context
            let hasChangesBeforeSave = context.hasChanges
            let insertedCountBeforeSave = context.insertedModelsArray.count
            let deletedCountBeforeSave = context.deletedModelsArray.count
            let fetchCountBeforeSave = try context.fetchCount(FetchDescriptor<ContextParityModel>())
            try context.save()
            values = [
                "deletedBeforeSave": .bool(deletedBeforeSave), "attachedBeforeSave": .bool(attachedBeforeSave),
                "hasChangesBeforeSave": .bool(hasChangesBeforeSave),
                "insertedCountBeforeSave": .integer(Int64(insertedCountBeforeSave)),
                "deletedCountBeforeSave": .integer(Int64(deletedCountBeforeSave)),
                "fetchCountBeforeSave": .integer(Int64(fetchCountBeforeSave)),
                "detachedAfterSave": .bool(model.modelContext == nil), "notDeletedAfterSave": .bool(!model.isDeleted),
                "hasChangesAfterSave": .bool(context.hasChanges),
                "insertedCountAfterSave": .integer(Int64(context.insertedModelsArray.count)),
                "deletedCountAfterSave": .integer(Int64(context.deletedModelsArray.count)),
                "storedCountAfterSave": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ContextParityModel>()))),
            ]
        case .reinsertDeletedInsertion:
            let model = ContextParityModel(name: "p")
            context.insert(model)
            context.delete(model)
            context.insert(model)
            values = [
                "stillDeleted": .bool(model.isDeleted),
                "insertedCount": .integer(Int64(context.insertedModelsArray.count)),
                "deletedCount": .integer(Int64(context.deletedModelsArray.count)),
            ]
        case .rollbackDeletedInsertion:
            let model = ContextParityModel(name: "p")
            context.insert(model)
            context.delete(model)
            context.rollback()
            values = [
                "detached": .bool(model.modelContext == nil), "notDeleted": .bool(!model.isDeleted),
                "hasChanges": .bool(context.hasChanges),
            ]
        case .fetchDescriptorDefaults:
            let descriptor = FetchDescriptor<ContextParityModel>()
            values = [
                "predicateAbsent": .bool(descriptor.predicate == nil), "sortEmpty": .bool(descriptor.sortBy.isEmpty),
                "fetchLimitAbsent": .bool(descriptor.fetchLimit == nil), "fetchOffsetAbsent": .bool(descriptor.fetchOffset == nil),
                "includePendingChanges": .bool(descriptor.includePendingChanges),
                "propertiesToFetchEmpty": .bool(descriptor.propertiesToFetch.isEmpty),
                "prefetchRelationshipsEmpty": .bool(descriptor.relationshipKeyPathsForPrefetching.isEmpty),
            ]
        case .fetchDescriptorProperties:
            var descriptor = FetchDescriptor<ContextParityModel>()
            descriptor.propertiesToFetch.append(\.name)
            values = [
                "propertyCount": .integer(Int64(descriptor.propertiesToFetch.count)),
                "containsName": .bool(descriptor.propertiesToFetch == [\.name]),
            ]
        case .fetchDescriptorEquality:
            let base = FetchDescriptor<ContextParityModel>(
                predicate: #Predicate { $0.name == "a" }, sortBy: [SortDescriptor(\.name)])
            let same = FetchDescriptor<ContextParityModel>(
                predicate: #Predicate { $0.name == "a" }, sortBy: [SortDescriptor(\.name)])
            let different = FetchDescriptor<ContextParityModel>(
                predicate: #Predicate { $0.name == "b" }, sortBy: [SortDescriptor(\.name)])
            var limited = base
            limited.fetchLimit = 1
            var pending = base
            pending.includePendingChanges = false
            values = [
                "samePredicateAndSortEqual": .bool(base == same), "differentPredicateUnequal": .bool(base != different),
                "differentLimitUnequal": .bool(base != limited), "differentPendingOptionUnequal": .bool(base != pending),
            ]
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map {
                ParityObservation(step: 0, field: $0, value: values[$0]!)
            })
    }
}
