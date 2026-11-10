import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class RollbackParityOwnerModel {
    var name: String
    var age: Int
    var tag: String?
    var tags: [String] = []
    @Relationship(inverse: \RollbackParityItemModel.owner) var items: [RollbackParityItemModel] = []

    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

@Model
final class RollbackParityItemModel {
    var value: Int
    var owner: RollbackParityOwnerModel?
    init(value: Int) { self.value = value }
}

@MainActor
public enum OSDRollbackAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try NonComparableScenarios.apply(RollbackParityScenarioCatalog.all.map(runAndValidate))
            .sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: RollbackParitySpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard RollbackParityExpectationValidator.validate(
            result, against: specification, implementation: "openswiftdata") else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: RollbackParitySpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: RollbackParityOwnerModel.self, RollbackParityItemModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var values: [String: ObservedValue]

        switch specification.query {
        case .committedValues:
            let owner = RollbackParityOwnerModel(name: "a", age: 1)
            context.insert(owner)
            try context.save()
            owner.age = 2
            owner.name = "a2"
            owner.tag = "t"
            owner.tags = ["x"]
            context.rollback()
            var saved = FetchDescriptor<RollbackParityOwnerModel>()
            saved.includePendingChanges = false
            let fetched = try context.fetch(saved)
            let otherContext = ModelContext(container)
            let stored = try otherContext.fetch(saved)
            values = [
                "age": .integer(Int64(owner.age)), "name": .string(owner.name),
                "tag": owner.tag.map(ObservedValue.string) ?? .null,
                "tags": .array(owner.tags.map(ObservedValue.string)),
                "modelHasChanges": .bool(owner.hasChanges), "contextHasChanges": .bool(context.hasChanges),
                "modelRemainsAttached": .bool(owner.modelContext === context),
                "storedAges": .array(stored.map { .integer(Int64($0.age)) }),
                "sameRegisteredInstance": .bool(fetched.first === owner),
            ]
        case .committedRelationship:
            let owner = RollbackParityOwnerModel(name: "a", age: 1)
            let item = RollbackParityItemModel(value: 1)
            context.insert(owner)
            context.insert(item)
            try context.save()
            owner.items.append(item)
            context.rollback()
            values = [
                "ownerItemCount": .integer(Int64(owner.items.count)),
                "itemOwnerAbsent": .bool(item.owner == nil), "contextHasChanges": .bool(context.hasChanges),
            ]
        case .relatedInsertion:
            let owner = RollbackParityOwnerModel(name: "a", age: 1)
            context.insert(owner)
            try context.save()
            let item = RollbackParityItemModel(value: 2)
            owner.items.append(item)
            context.rollback()
            values = [
                "ownerItemCount": .integer(Int64(owner.items.count)),
                "itemDetached": .bool(item.modelContext == nil), "itemOwnerAbsent": .bool(item.owner == nil),
                "ownerHasChanges": .bool(owner.hasChanges), "contextHasChanges": .bool(context.hasChanges),
                "storedItemCount": .integer(Int64(try context.fetchCount(FetchDescriptor<RollbackParityItemModel>()))),
            ]
        case .repeatedEdits:
            let owner = RollbackParityOwnerModel(name: "a", age: 1)
            context.insert(owner)
            try context.save()
            owner.age = 2
            owner.age = 3
            context.rollback()
            let afterFirst = owner.age
            let unchangedFirst = !owner.hasChanges
            owner.age = 4
            let changedSecond = owner.hasChanges
            context.rollback()
            values = [
                "ageAfterFirstRollback": .integer(Int64(afterFirst)),
                "unchangedAfterFirstRollback": .bool(unchangedFirst),
                "hasChangesAfterSecondEdit": .bool(changedSecond),
                "ageAfterSecondRollback": .integer(Int64(owner.age)),
                "unchangedAfterSecondRollback": .bool(!owner.hasChanges),
            ]
        case .editedDeletion:
            let owner = RollbackParityOwnerModel(name: "a", age: 1)
            context.insert(owner)
            try context.save()
            owner.age = 2
            context.delete(owner)
            context.rollback()
            values = [
                "age": .integer(Int64(owner.age)), "notDeleted": .bool(!owner.isDeleted),
                "modelRemainsAttached": .bool(owner.modelContext === context),
                "contextHasChanges": .bool(context.hasChanges),
            ]
        case .insertionAndDeletion:
            let inserted = RollbackParityOwnerModel(name: "b", age: 5)
            context.insert(inserted)
            context.rollback()
            let insertedDetached = inserted.modelContext == nil
            let insertedNotDeleted = !inserted.isDeleted
            let insertedModelsEmpty = context.insertedModelsArray.isEmpty
            let insertionValue = inserted.name

            let owner = RollbackParityOwnerModel(name: "a", age: 1)
            context.insert(owner)
            try context.save()
            context.delete(owner)
            let deletionApplied = owner.isDeleted
            context.rollback()
            values = [
                "rolledBackInsertionDetached": .bool(insertedDetached),
                "rolledBackInsertionNotDeleted": .bool(insertedNotDeleted),
                "insertedModelsEmpty": .bool(insertedModelsEmpty), "insertionValueRetained": .string(insertionValue),
                "deletionWasApplied": .bool(deletionApplied), "restoredDeletionNotDeleted": .bool(!owner.isDeleted),
                "restoredDeletionAttached": .bool(owner.modelContext === context),
                "storedOwnerCount": .integer(Int64(try context.fetchCount(FetchDescriptor<RollbackParityOwnerModel>()))),
            ]
        case .relationshipNotSaved:
            let owner = RollbackParityOwnerModel(name: "a", age: 1)
            let item = RollbackParityItemModel(value: 1)
            context.insert(owner)
            context.insert(item)
            try context.save()
            owner.items.append(item)
            context.rollback()
            let changedModelsEmpty = context.changedModelsArray.isEmpty
            try context.save()
            let stored = try ModelContext(container).fetch(FetchDescriptor<RollbackParityOwnerModel>())
            values = [
                "changedModelsEmpty": .bool(changedModelsEmpty),
                "storedRelationshipCount": .integer(Int64(stored.first?.items.count ?? -1)),
            ]
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map {
                ParityObservation(step: 0, field: $0, value: values[$0]!)
            })
    }
}
