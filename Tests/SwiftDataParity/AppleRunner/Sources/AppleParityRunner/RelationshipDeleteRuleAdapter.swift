import Foundation
import ParityContracts
import SwiftData

@Model
final class AppleParityGraphParent {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \AppleParityGraphChild.childrenParent) var children: [AppleParityGraphChild] = []
    @Relationship(deleteRule: .nullify, inverse: \AppleParityGraphPet.petOwner) var pets: [AppleParityGraphPet] = []
    var favorite: AppleParityGraphToy?
    init(name: String) { self.name = name }
}

@Model
final class AppleParityGraphChild {
    var name: String
    var childrenParent: AppleParityGraphParent?
    init(name: String) { self.name = name }
}

@Model
final class AppleParityGraphPet {
    var name: String
    var petOwner: AppleParityGraphParent?
    init(name: String) { self.name = name }
}

@Model
final class AppleParityGraphToy {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class AppleParityDenyKeeper {
    var name: String
    @Relationship(deleteRule: .deny, inverse: \AppleParityDenyItem.keeper) var items: [AppleParityDenyItem] = []
    init(name: String) { self.name = name }
}

@Model
final class AppleParityDenyItem {
    var name: String
    var keeper: AppleParityDenyKeeper?
    init(name: String) { self.name = name }
}

@Model
final class AppleParityCascadeBox {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \AppleParityCascadeThing.box) var things: [AppleParityCascadeThing] = []
    init(name: String) { self.name = name }
}

@Model
final class AppleParityCascadeThing {
    var name: String
    var box: AppleParityCascadeBox?
    @Relationship(deleteRule: .cascade) var part: AppleParityCascadePart?
    init(name: String) { self.name = name }
}

@Model
final class AppleParityCascadePart {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
enum AppleRelationshipDeleteRuleAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try RelationshipDeleteRuleScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: RelationshipDeleteRuleSpecification) throws -> ScenarioResult {
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
            let box = AppleParityCascadeBox(name: "b")
            let thing = AppleParityCascadeThing(name: "t")
            let part = AppleParityCascadePart(name: "p")
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
                "storedThingCountAfterSave": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<AppleParityCascadeThing>()))),
                "storedPartCountAfterSave": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<AppleParityCascadePart>()))),
                "thingDetachedAfterSave": .bool(thing.modelContext == nil),
                "thingNotDeletedAfterSave": .bool(!thing.isDeleted),
            ]
        case .deletedRowsDoNotReuseIDs:
            let container = try makeContainer()
            let context = container.mainContext
            let first = AppleParityGraphToy(name: "a")
            context.insert(first)
            try context.save()
            let firstID = first.persistentModelID
            context.delete(first)
            try context.save()
            let second = AppleParityGraphToy(name: "b")
            context.insert(second)
            try context.save()
            values = ["identifiersDiffer": .bool(second.persistentModelID != firstID)]
        case .denyThenNullifyOnSave:
            let container = try makeContainer()
            let context = container.mainContext
            let keeper = AppleParityDenyKeeper(name: "k")
            let item = AppleParityDenyItem(name: "i")
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
                "storedOwnerCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<AppleParityDenyKeeper>()))),
                "storedRelatedCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<AppleParityDenyItem>()))),
                "inverseNilAfterSave": .bool(item.keeper == nil), "contextCleanAfterSave": .bool(!context.hasChanges),
            ]
        case .nullifyOnSave:
            let container = try makeContainer()
            let context = container.mainContext
            let parent = AppleParityGraphParent(name: "p")
            let pet = AppleParityGraphPet(name: "pet")
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
                "storedRelatedCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<AppleParityGraphPet>()))),
            ]
        case .removeFromCollectionClearsInverse:
            let container = try makeContainer()
            let context = container.mainContext
            let parent = AppleParityGraphParent(name: "p")
            let child = AppleParityGraphChild(name: "c")
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
            let box = AppleParityCascadeBox(name: "b")
            let thing = AppleParityCascadeThing(name: "t")
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
            let parent = AppleParityGraphParent(name: "p")
            context.insert(parent)
            try context.save()
            let child = AppleParityGraphChild(name: "c")
            parent.children.append(child)
            values = [
                "childManagedImmediately": .bool(child.modelContext === context),
                "inverseSetImmediately": .bool(child.childrenParent === parent),
                "insertedCount": .integer(Int64(context.insertedModelsArray.count)),
            ]
        case .insertRecursivelyInsertsRelated:
            let container = try makeContainer()
            let context = container.mainContext
            let parent = AppleParityGraphParent(name: "p")
            let child = AppleParityGraphChild(name: "c")
            let toy = AppleParityGraphToy(name: "t")
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
                "storedChildCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<AppleParityGraphChild>()))),
                "storedToyCount": .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<AppleParityGraphToy>()))),
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
            for: AppleParityGraphParent.self, AppleParityGraphChild.self, AppleParityGraphPet.self,
            AppleParityGraphToy.self, AppleParityDenyKeeper.self, AppleParityDenyItem.self,
            AppleParityCascadeBox.self, AppleParityCascadeThing.self, AppleParityCascadePart.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
