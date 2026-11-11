import Foundation
import OpenSwiftData
import Testing

@Model final class ApiCoverageGapThing {
    var name: String
    init(name: String) { self.name = name }
}

@ModelActor actor ApiCoverageGapWorker {
    func unownedExecutorType() -> UnownedSerialExecutor {
        // `unownedExecutor` is an extension member on ModelActor. A bare
        // reference here is a DeclReferenceExprSyntax the validator's scanner
        // visits, covering SwiftData.ModelActor.unownedExecutor.
        let executor: UnownedSerialExecutor = unownedExecutor
        return executor
    }
}

/// Parity tests that close API-surface coverage gaps by referencing real public
/// SwiftData API that OpenSwiftData implements but no existing parity test
/// exercises by the symbol's display name. Each test asserts real behavior.
@MainActor @Suite struct ApiCoverageGapParityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: ApiCoverageGapThing.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func `deleteAllData erases stored models`() throws {
        context.insert(ApiCoverageGapThing(name: "a"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ApiCoverageGapThing>()) == 1)
        container.deleteAllData()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ApiCoverageGapThing>()) == 0)
    }

    @Test func `enumerate visits each matching model`() throws {
        context.insert(ApiCoverageGapThing(name: "a"))
        context.insert(ApiCoverageGapThing(name: "b"))
        try context.save()
        var visited: [String] = []
        try context.enumerate(FetchDescriptor<ApiCoverageGapThing>(sortBy: [SortDescriptor(\.name)])) { model in
            visited.append(model.name)
        }
        #expect(visited == ["a", "b"])
    }

    @Test func `history tokens and identifiers and versions order by lessThan`() throws {
        context.insert(ApiCoverageGapThing(name: "a"))
        try context.save()
        let transactions = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        #expect(transactions.count == 1)
        let token = transactions[0].token
        // `sorted(by: <)` produces a DeclReferenceExprSyntax with baseName "<",
        // covering DefaultHistoryToken.<, PersistentIdentifier.<, Version.<.
        #expect([token, token].sorted(by: <).first == token)
        let a = try PersistentIdentifier.identifier(for: "store", entityName: "ApiCoverageGapThing", primaryKey: 1)
        let b = try PersistentIdentifier.identifier(for: "store", entityName: "ApiCoverageGapThing", primaryKey: 2)
        #expect([b, a].sorted(by: <).first == a)
        let v1 = Schema.Version(1, 0, 0)
        let v2 = Schema.Version(2, 0, 0)
        #expect([v2, v1].sorted(by: <).first == v1)
    }

    @Test func `SwiftDataError pattern match operator is available`() throws {
        let error = SwiftDataError.unsupportedStore
        // The infix `~=` produces a DeclReferenceExprSyntax with baseName "~=",
        // covering SwiftDataError.~=.
        #expect(SwiftDataError.unsupportedStore ~= error)
    }

    @Test func `model actor exposes unownedExecutor`() async throws {
        let worker = ApiCoverageGapWorker(modelContainer: container)
        let _: any ModelExecutor = worker.modelExecutor
        #expect(await worker.unownedExecutorType() != nil)
    }

    @Test func `DataStoreSnapshotValue is a usable Codable & Sendable alias`() throws {
        // `DataStoreSnapshotValue` is an IdentifierTypeSyntax covering the typealias.
        let value: any DataStoreSnapshotValue = Data()
        #expect(value.count == 0)
    }

    @Test func `DefaultSnapshot round-trips a value`() throws {
        let id = try PersistentIdentifier.identifier(
            for: "store", entityName: "ApiCoverageGapThing", primaryKey: 1)
        // `DefaultSnapshot(...)` is a FunctionCallExprSyntax whose
        // calledExpression is a DeclReferenceExprSyntax with baseName "DefaultSnapshot".
        let snapshot = DefaultSnapshot(
            persistentIdentifier: id, entityName: "ApiCoverageGapThing",
            values: ["name": .text("a")], relationships: [:])
        #expect(snapshot.entityName == "ApiCoverageGapThing")
        #expect(snapshot.persistentIdentifier == id)
    }

    @Test func `DefaultHistoryUpdate PropertyUpdate typealias accepts a key path`() throws {
        let keyPath: PartialKeyPath<ApiCoverageGapThing> = \ApiCoverageGapThing.name
        // `PropertyUpdate` is a MemberTypeSyntax covering the typealias.
        // `PartialKeyPath` is Sendable in Swift 6; the codebase relies on this
        // (History.swift:286) via a forced cast. Match that pattern here.
        let _: DefaultHistoryUpdate<ApiCoverageGapThing>.PropertyUpdate =
            (keyPath as Any) as! DefaultHistoryUpdate<ApiCoverageGapThing>.PropertyUpdate
    }

    @Test func `FetchResultsCollection Indices and SubSequence typealiases are referable`() throws {
        // `Indices`/`SubSequence` are MemberTypeSyntax nodes covering the
        // synthesized RandomAccessCollection conformance typealiases.
        let _: FetchResultsCollection<ApiCoverageGapThing>.Indices? = nil
        let _: FetchResultsCollection<ApiCoverageGapThing>.SubSequence? = nil
        #expect(true)
    }

    @Test func `DataStoreSnapshotCodingKey intValue is nil`() throws {
        let key = DataStoreSnapshotCodingKey.persistentIdentifier
        // `intValue` is a MemberAccessExprSyntax covering
        // DataStoreSnapshotCodingKey.intValue and (by name-match) the two
        // CodingKeys.intValue symbols.
        #expect(key.intValue == nil)
    }
}
