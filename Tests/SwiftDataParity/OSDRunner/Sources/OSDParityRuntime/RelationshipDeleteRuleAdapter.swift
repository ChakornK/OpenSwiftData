import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class ParityGraphParent {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \ParityGraphChild.childrenParent) var children: [ParityGraphChild] = []
    @Relationship(deleteRule: .nullify, inverse: \ParityGraphPet.petOwner) var pets: [ParityGraphPet] = []
    var favorite: ParityGraphToy?
    init(name: String) { self.name = name }
}

@Model
final class ParityGraphChild {
    var name: String
    var childrenParent: ParityGraphParent?
    init(name: String) { self.name = name }
}

@Model
final class ParityGraphPet {
    var name: String
    var petOwner: ParityGraphParent?
    init(name: String) { self.name = name }
}

@Model
final class ParityGraphToy {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class ParityDenyKeeper {
    var name: String
    @Relationship(deleteRule: .deny, inverse: \ParityDenyItem.keeper) var items: [ParityDenyItem] = []
    init(name: String) { self.name = name }
}

@Model
final class ParityDenyItem {
    var name: String
    var keeper: ParityDenyKeeper?
    init(name: String) { self.name = name }
}

@Model
final class ParityCascadeBox {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \ParityCascadeThing.box) var things: [ParityCascadeThing] = []
    init(name: String) { self.name = name }
}

@Model
final class ParityCascadeThing {
    var name: String
    var box: ParityCascadeBox?
    @Relationship(deleteRule: .cascade) var part: ParityCascadePart?
    init(name: String) { self.name = name }
}

@Model
final class ParityCascadePart {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
public enum OSDRelationshipDeleteRuleAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try RelationshipDeleteRuleScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: RelationshipDeleteRuleSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard RelationshipDeleteRuleExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: RelationshipDeleteRuleSpecification) throws -> ScenarioResult {
        let values: [String: ObservedValue]
        switch specification.query {
        case .cascadeImmediateAndRecursive:
            let container = try makeContainer()
            let context = container.mainContext
            let box = ParityCascadeBox(name: "b")
            let thing = ParityCascadeThing(name: "t")
            let part = ParityCascadePart(name: "p")
            context.insert(box)
            box.things.append(thing)
            thing.part = part
            try context.save()
            context.delete(box)
            let thingDeleted = thing.isDeleted
            let partDeleted = part.isDeleted
            let deletedCount = context.deletedModelsArray.count
            try context.save()
            values = [
                "thingDeletedBeforeSave": .bool(thingDeleted), "partDeletedBeforeSave": .bool(partDeleted),
                "deletedCountBeforeSave": .integer(Int64(deletedCount)),
                "storedThingCountAfterSave": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ParityCascadeThing>()))),
                "storedPartCountAfterSave": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ParityCascadePart>()))),
                "thingDetachedAfterSave": .bool(thing.modelContext == nil),
                "thingNotDeletedAfterSave": .bool(!thing.isDeleted),
            ]
        case .deletedRowsDoNotReuseIDs:
            let container = try makeContainer()
            let context = container.mainContext
            let first = ParityGraphToy(name: "a")
            context.insert(first)
            try context.save()
            let firstID = first.persistentModelID
            context.delete(first)
            try context.save()
            let second = ParityGraphToy(name: "b")
            context.insert(second)
            try context.save()
            values = ["identifiersDiffer": .bool(second.persistentModelID != firstID)]
        case .denyThenNullifyOnSave:
            let container = try makeContainer()
            let context = container.mainContext
            let keeper = ParityDenyKeeper(name: "k")
            let item = ParityDenyItem(name: "i")
            context.insert(keeper)
            keeper.items.append(item)
            try context.save()
            context.delete(keeper)
            let deleteApplied = keeper.isDeleted
            let itemAttached = item.modelContext === context
            let inversePresent = item.keeper != nil
            var saveReturned = true
            do { try context.save() } catch { saveReturned = false }
            values = [
                "deleteApplied": .bool(deleteApplied),
                "relatedModelAttachedBeforeSave": .bool(itemAttached),
                "relatedModelHasInverseBeforeSave": .bool(inversePresent),
                "saveReturned": .bool(saveReturned),
                "storedOwnerCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ParityDenyKeeper>()))),
                "storedRelatedCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ParityDenyItem>()))),
                "inverseNilAfterSave": .bool(item.keeper == nil), "contextCleanAfterSave": .bool(!context.hasChanges),
            ]
        case .nullifyOnSave:
            let container = try makeContainer()
            let context = container.mainContext
            let parent = ParityGraphParent(name: "p")
            let pet = ParityGraphPet(name: "pet")
            context.insert(parent)
            parent.pets.append(pet)
            try context.save()
            context.delete(parent)
            let inversePresentImmediately = pet.petOwner != nil
            try context.save()
            let inversePresentAfterSave = pet.petOwner != nil
            values = [
                "inversePresentImmediatelyAfterDelete": .bool(inversePresentImmediately),
                "inversePresentAfterSave": .bool(inversePresentAfterSave),
                "storedRelatedCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ParityGraphPet>()))),
            ]
        case .removeFromCollectionClearsInverse:
            let container = try makeContainer()
            let context = container.mainContext
            let parent = ParityGraphParent(name: "p")
            let child = ParityGraphChild(name: "c")
            context.insert(parent)
            parent.children.append(child)
            try context.save()
            parent.children.removeAll { $0 === child }
            values = [
                "inverseNilImmediately": .bool(child.childrenParent == nil),
                "childNotDeleted": .bool(!child.isDeleted),
            ]
        case .rollbackRestoresCascade:
            let container = try makeContainer()
            let context = container.mainContext
            let box = ParityCascadeBox(name: "b")
            let thing = ParityCascadeThing(name: "t")
            context.insert(box)
            box.things.append(thing)
            try context.save()
            context.delete(box)
            let deletedBeforeRollback = thing.isDeleted
            context.rollback()
            values = [
                "destinationDeletedBeforeRollback": .bool(deletedBeforeRollback),
                "destinationNotDeletedAfterRollback": .bool(!thing.isDeleted),
                "ownerNotDeletedAfterRollback": .bool(!box.isDeleted),
                "relationshipRestored": .bool(box.things.count == 1),
            ]
        case .appendDetachedInserts:
            let container = try makeContainer()
            let context = container.mainContext
            let parent = ParityGraphParent(name: "p")
            context.insert(parent)
            try context.save()
            let child = ParityGraphChild(name: "c")
            parent.children.append(child)
            values = [
                "childManagedImmediately": .bool(child.modelContext === context),
                "inverseSetImmediately": .bool(child.childrenParent === parent),
                "insertedCount": .integer(Int64(context.insertedModelsArray.count)),
            ]
        case .insertRecursivelyInsertsRelated:
            let container = try makeContainer()
            let context = container.mainContext
            let parent = ParityGraphParent(name: "p")
            let child = ParityGraphChild(name: "c")
            let toy = ParityGraphToy(name: "t")
            parent.children.append(child)
            parent.favorite = toy
            let inverseSet = child.childrenParent === parent
            context.insert(parent)
            let insertedCount = context.insertedModelsArray.count
            let childAttached = child.modelContext === context
            let toyAttached = toy.modelContext === context
            try context.save()
            values = [
                "childInverseSetBeforeInsert": .bool(inverseSet),
                "insertedCountAfterInsert": .integer(Int64(insertedCount)),
                "childManagedAfterInsert": .bool(childAttached), "toyManagedAfterInsert": .bool(toyAttached),
                "storedChildCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ParityGraphChild>()))),
                "storedToyCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<ParityGraphToy>()))),
            ]
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { field in
                ParityObservation(step: 0, field: field, value: values[field]!)
            })
    }

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ParityGraphParent.self, ParityGraphChild.self, ParityGraphPet.self, ParityGraphToy.self,
            ParityDenyKeeper.self, ParityDenyItem.self, ParityCascadeBox.self, ParityCascadeThing.self,
            ParityCascadePart.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
