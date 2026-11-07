import Foundation
import OpenSwiftData
import Testing

@Model final class GraphParityParent {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \GraphParityChild.parent) var children: [GraphParityChild] = []
    @Relationship(deleteRule: .nullify, inverse: \GraphParityPet.owner) var pets: [GraphParityPet] = []
    var favorite: GraphParityToy?
    init(name: String) { self.name = name }
}

@Model final class GraphParityChild {
    var name: String
    var parent: GraphParityParent?
    init(name: String) { self.name = name }
}

@Model final class GraphParityPet {
    var name: String
    var owner: GraphParityParent?
    init(name: String) { self.name = name }
}

@Model final class GraphParityToy {
    var name: String
    init(name: String) { self.name = name }
}

/// Relationship graph maintenance, matching Apple's SwiftData.
@MainActor @Suite struct RelationshipGraphParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: GraphParityParent.self, GraphParityChild.self, GraphParityPet.self, GraphParityToy.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `inserting a model inserts the detached models it relates to`() throws {
        let parent = GraphParityParent(name: "p")
        let child = GraphParityChild(name: "c")
        let toy = GraphParityToy(name: "t")
        parent.children.append(child)
        parent.favorite = toy
        #expect(child.parent === parent)

        context.insert(parent)
        #expect(context.insertedModelsArray.count == 3)
        #expect(child.modelContext === context)
        #expect(toy.modelContext === context)
        try context.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<GraphParityChild>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<GraphParityToy>()) == 1)
    }

    @Test func `appending a detached model to a managed collection inserts it`() throws {
        let parent = GraphParityParent(name: "p")
        context.insert(parent)
        try context.save()
        let child = GraphParityChild(name: "c")
        parent.children.append(child)
        #expect(child.modelContext === context)
        #expect(child.parent === parent)
        #expect(context.insertedModelsArray.count == 1)
    }
}

@Model final class DeleteRuleParityKeeper {
    var name: String
    @Relationship(deleteRule: .deny, inverse: \DeleteRuleParityItem.keeper) var items: [DeleteRuleParityItem] = []
    init(name: String) { self.name = name }
}

@Model final class DeleteRuleParityItem {
    var name: String
    var keeper: DeleteRuleParityKeeper?
    init(name: String) { self.name = name }
}

@Model final class DeleteRuleParityBox {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \DeleteRuleParityThing.box) var things: [DeleteRuleParityThing] = []
    init(name: String) { self.name = name }
}

@Model final class DeleteRuleParityThing {
    var name: String
    var box: DeleteRuleParityBox?
    @Relationship(deleteRule: .cascade) var part: DeleteRuleParityPart?
    init(name: String) { self.name = name }
}

@Model final class DeleteRuleParityPart {
    var name: String
    init(name: String) { self.name = name }
}

/// Delete rules, matching Apple's SwiftData.
@MainActor @Suite struct DeleteRuleParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: DeleteRuleParityKeeper.self, DeleteRuleParityItem.self, DeleteRuleParityBox.self,
            DeleteRuleParityThing.self, DeleteRuleParityPart.self, GraphParityParent.self, GraphParityChild.self,
            GraphParityPet.self, GraphParityToy.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `deny rules are not enforced and related models are nullified on save`() throws {
        let keeper = DeleteRuleParityKeeper(name: "k")
        let item = DeleteRuleParityItem(name: "i")
        context.insert(keeper)
        keeper.items.append(item)
        try context.save()

        context.delete(keeper)
        #expect(keeper.isDeleted)
        #expect(context.deletedModelsArray.count == 1)
        #expect(item.keeper != nil)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<DeleteRuleParityKeeper>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DeleteRuleParityItem>()) == 1)
        #expect(item.keeper == nil)
        #expect(!context.hasChanges)
    }

    @Test func `cascade destinations are marked deleted immediately and recursively`() throws {
        let box = DeleteRuleParityBox(name: "b")
        let thing = DeleteRuleParityThing(name: "t")
        let part = DeleteRuleParityPart(name: "p")
        context.insert(box)
        box.things.append(thing)
        thing.part = part
        try context.save()

        context.delete(box)
        #expect(thing.isDeleted)
        #expect(part.isDeleted)
        #expect(context.deletedModelsArray.count == 3)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<DeleteRuleParityThing>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DeleteRuleParityPart>()) == 0)
        #expect(thing.modelContext == nil)
        #expect(!thing.isDeleted)
    }

    @Test func `rolling back restores cascaded deletions`() throws {
        let box = DeleteRuleParityBox(name: "b")
        let thing = DeleteRuleParityThing(name: "t")
        context.insert(box)
        box.things.append(thing)
        try context.save()
        context.delete(box)
        #expect(thing.isDeleted)
        context.rollback()
        #expect(!thing.isDeleted)
        #expect(!box.isDeleted)
        #expect(box.things.count == 1)
    }

    @Test func `nullify applies when saving`() throws {
        let parent = GraphParityParent(name: "p")
        let pet = GraphParityPet(name: "pet")
        context.insert(parent)
        parent.pets.append(pet)
        try context.save()
        context.delete(parent)
        #expect(pet.owner != nil)
        try context.save()
        #expect(pet.owner == nil)
        #expect(try context.fetchCount(FetchDescriptor<GraphParityPet>()) == 1)
    }

    @Test func `removing a model from a collection clears its inverse immediately`() throws {
        let parent = GraphParityParent(name: "p")
        let child = GraphParityChild(name: "c")
        context.insert(parent)
        parent.children.append(child)
        try context.save()
        parent.children.removeAll { $0 === child }
        #expect(child.parent == nil)
        #expect(!child.isDeleted)
    }

    @Test func `deleted rows never reuse primary keys`() throws {
        let first = GraphParityToy(name: "a")
        context.insert(first)
        try context.save()
        let firstID = first.persistentModelID
        context.delete(first)
        try context.save()
        let second = GraphParityToy(name: "b")
        context.insert(second)
        try context.save()
        #expect(second.persistentModelID != firstID)
    }
}
