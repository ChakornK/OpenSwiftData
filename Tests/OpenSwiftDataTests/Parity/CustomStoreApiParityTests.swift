import Foundation
import OpenSwiftData
import Testing

@Model final class CustomStoreApiThing {
    var name: String
    init(name: String) { self.name = name }
}

/// A concrete `RelationshipCollection`-conforming stub so the parity test can
/// reference `ConcreteRelationshipCollection.PersistentElement` (a
/// `MemberTypeSyntax` on a concrete type). `PersistentElement` is bound to
/// `CustomStoreApiThing`.
private struct ConcreteRelationshipCollection: RelationshipCollection {
    typealias PersistentElement = CustomStoreApiThing
}

/// Custom-store API surface that OpenSwiftData does not reimplement, referenced
/// for parity API coverage. Each reference exercises a display name that
/// OpenSwiftData stubs for coverage but does not wire into its runtime.
@MainActor struct CustomStoreApiParityTests {
    @Test func `DataStoreError cases are referable`() throws {
        let errors: [DataStoreError] = [
            .invalidPredicate,
            .preferInMemoryFilter,
            .preferInMemorySort,
            .unsupportedFeature,
        ]
        #expect(errors == [.invalidPredicate, .preferInMemoryFilter, .preferInMemorySort, .unsupportedFeature])
    }

    @Test func `DefaultStore type and historyType static member are referable`() throws {
        let _: DefaultStore.Type = DefaultStore.self
        let _: DefaultHistoryTransaction.Type = DefaultStore.historyType
        #expect(true)
    }

    @Test func `HistoryProviding protocol and HistoryType associatedtype are referable`() throws {
        let _: (any HistoryProviding.Type)? = nil
        let _: DefaultStore.HistoryType.Type? = nil
        #expect(true)
    }

    @Test func `RelationshipCollection protocol and PersistentElement associatedtype are referable`() throws {
        let _: (any RelationshipCollection.Type)? = nil
        let _: ConcreteRelationshipCollection.PersistentElement.Type? = nil
        #expect(true)
    }
}
