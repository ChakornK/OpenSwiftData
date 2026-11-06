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
