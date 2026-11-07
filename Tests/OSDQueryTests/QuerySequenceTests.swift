import Foundation
import OpenSwiftDataSQLite
import OpenSwiftData
@testable import OSDQuery
import XCTest

private final class StoreIdentity {}

@Model
private final class QuerySequenceFixture {
    var title: String
    init(title: String) { self.title = title }
}

final class QuerySequenceTests: XCTestCase {
    func testUnrelatedChangesDoNotRefreshAndRelevantChangesDiffIdentifiers() async throws {
        let identity = StoreIdentity()
        let storeID = ObjectIdentifier(identity)
        let changes = ChangeInbox()
        let first = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 1)
        let second = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 2)
        let counter = RefreshCounter([first])
        let sequence = QuerySequence(
            changes: changes,
            storeIdentifier: storeID,
            dependencyEntityNames: ["Person", "Pet"],
            resultEntityNames: ["Person"],
            refresh: { counter.refresh() })
        var iterator = sequence.makeAsyncIterator()

        let initialValue = try await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertEqual(initial.identifiers, [first])
        XCTAssertEqual(initial.inserted, [first])
        XCTAssertTrue(initial.isFullSnapshot)
        var callCount = counter.callCount
        XCTAssertEqual(callCount, 1)

        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 1,
                updated: [StoreEntityKey(entityName: "Address", primaryKey: 8)]))
        counter.set([first, second])
        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 2,
                inserted: [StoreEntityKey(entityName: "Person", primaryKey: 2)],
                updated: [StoreEntityKey(entityName: "Pet", primaryKey: 4)]))
        let insertionValue = try await iterator.next()
        let insertion = try XCTUnwrap(insertionValue)
        XCTAssertEqual(insertion.inserted, [second])
        XCTAssertEqual(insertion.updated, [first, second])
        XCTAssertTrue(insertion.deleted.isEmpty)
        XCTAssertTrue(insertion.isFullSnapshot)
        XCTAssertEqual(insertion.identifiers, [first, second])
        callCount = counter.callCount
        XCTAssertEqual(callCount, 2)

        counter.set([second])
        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 3,
                updated: [StoreEntityKey(entityName: "Pet", primaryKey: 4)]))
        let deletionValue = try await iterator.next()
        let deletion = try XCTUnwrap(deletionValue)
        XCTAssertEqual(deletion.deleted, [first])
        XCTAssertTrue(deletion.inserted.isEmpty)
        XCTAssertEqual(deletion.identifiers, [second])
        callCount = counter.callCount
        XCTAssertEqual(callCount, 3)

    }

    func testWildcardChangeRefreshesAndMarksCurrentIdentifiersUpdated() async throws {
        let identity = StoreIdentity()
        let storeID = ObjectIdentifier(identity)
        let changes = ChangeInbox()
        let identifier = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 7)
        let counter = RefreshCounter([identifier])
        let sequence = QuerySequence(
            changes: changes,
            storeIdentifier: storeID,
            dependencyEntityNames: ["Person"],
            resultEntityNames: ["Person"],
            refresh: { counter.refresh() })
        var iterator = sequence.makeAsyncIterator()
        _ = try await iterator.next()

        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 1,
                allEntitiesChanged: true))
        let updateValue = try await iterator.next()
        let update = try XCTUnwrap(updateValue)
        XCTAssertEqual(update.updated, [identifier])
        XCTAssertTrue(update.isFullSnapshot)
        XCTAssertEqual(update.identifiers, [identifier])
        let callCount = counter.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testMultipleIteratorsReceiveIndependentChangeEvents() async throws {
        let identity = StoreIdentity()
        let storeID = ObjectIdentifier(identity)
        let changes = ChangeInbox()
        let identifier = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 1)
        let counter = RefreshCounter([identifier])
        let sequence = QuerySequence(
            changes: changes,
            storeIdentifier: storeID,
            dependencyEntityNames: ["Person"],
            resultEntityNames: ["Person"],
            refresh: { counter.refresh() })
        var firstIterator = sequence.makeAsyncIterator()
        var secondIterator = sequence.makeAsyncIterator()
        _ = try await firstIterator.next()
        _ = try await secondIterator.next()

        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 1,
                updated: [StoreEntityKey(entityName: "Person", primaryKey: 1)]))
        let firstUpdate = try await firstIterator.next()
        let secondUpdate = try await secondIterator.next()
        XCTAssertEqual(firstUpdate?.updated, [identifier])
        XCTAssertEqual(secondUpdate?.updated, [identifier])
    }

    func testInboxOverflowForcesFullQuerySnapshot() async throws {
        let identity = StoreIdentity()
        let storeID = ObjectIdentifier(identity)
        let changes = ChangeInbox(bufferingLimit: 1)
        let first = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 1)
        let second = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 2)
        let counter = RefreshCounter([first])
        let sequence = QuerySequence(
            changes: changes,
            storeIdentifier: storeID,
            dependencyEntityNames: ["Person"],
            resultEntityNames: ["Person"],
            refresh: { counter.refresh() })
        var iterator = sequence.makeAsyncIterator()
        _ = try await iterator.next()

        counter.set([first, second])
        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 1,
                inserted: [StoreEntityKey(entityName: "Person", primaryKey: 2)]))
        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 2,
                updated: [StoreEntityKey(entityName: "Person", primaryKey: 1)]))

        let updateValue = try await iterator.next()
        let update = try XCTUnwrap(updateValue)
        XCTAssertTrue(update.isFullSnapshot)
        XCTAssertEqual(Set(update.identifiers), [first, second])
        XCTAssertEqual(update.updated, [first, second])

        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 3,
                updated: [StoreEntityKey(entityName: "Person", primaryKey: 1)]))
        let followingValue = try await iterator.next()
        let following = try XCTUnwrap(followingValue)
        XCTAssertTrue(following.isFullSnapshot)
        XCTAssertEqual(following.updated, [first])
    }

    func testRefreshSnapshotMayIncludeCommitsNewerThanTriggerGeneration() async throws {
        let identity = StoreIdentity()
        let storeID = ObjectIdentifier(identity)
        let changes = ChangeInbox()
        let first = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 1)
        let second = PersistentIdentifier(storeIdentifier: "store", entityName: "Person", primaryKey: 2)
        let counter = RefreshCounter([first])
        let sequence = QuerySequence(
            changes: changes,
            storeIdentifier: storeID,
            dependencyEntityNames: ["Person"],
            resultEntityNames: ["Person"],
            refresh: { counter.refresh() })
        var iterator = sequence.makeAsyncIterator()
        _ = try await iterator.next()

        counter.set([first, second])
        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 1,
                updated: [StoreEntityKey(entityName: "Person", primaryKey: 1)]))
        let updateValue = try await iterator.next()
        let update = try XCTUnwrap(updateValue)
        XCTAssertEqual(update.generation, 1)
        XCTAssertTrue(update.isFullSnapshot)
        XCTAssertEqual(Set(update.identifiers), [first, second])
        XCTAssertEqual(update.inserted, [second])
    }

    func testRefreshErrorsPropagateToConsumer() async throws {
        let identity = StoreIdentity()
        let storeID = ObjectIdentifier(identity)
        let changes = ChangeInbox()
        let counter = FailingRefreshCounter()
        let sequence = QuerySequence(
            changes: changes,
            storeIdentifier: storeID,
            dependencyEntityNames: ["Person"],
            resultEntityNames: ["Person"],
            refresh: { try counter.refresh() })
        var iterator = sequence.makeAsyncIterator()
        _ = try await iterator.next()
        changes.enqueue(
            ChangeSet(
                storeIdentifier: storeID,
                sourceSubscription: UUID(),
                generation: 1,
                inserted: [StoreEntityKey(entityName: "Person", primaryKey: 1)]))
        do {
            let unexpected = try await iterator.next()
            if unexpected != nil { XCTFail("Expected refresh error") }
        } catch QueryRefreshError.failed {
        }
        let afterError = try await iterator.next()
        XCTAssertNil(afterError)
    }

    @MainActor
    func testModelContextSequenceTracksCrossContextInsertions() async throws {
        let container = try ModelContainer(
            for: QuerySequenceFixture.self,
            configurations: .sqliteMemory("query-sequence-cross-context"))
        let queryContext = container.mainContext
        let writerContext = container.makeContext()
        let descriptor = FetchDescriptor<QuerySequenceFixture>()
        let sequence = try QuerySequence(
            context: queryContext,
            dependencyEntityNames: [String(describing: QuerySequenceFixture.self)],
            resultEntityNames: [String(describing: QuerySequenceFixture.self)],
            refresh: {
                try queryContext.processPendingChangesThrowing()
                return try queryContext.fetchIdentifiers(descriptor)
            })
        var iterator = sequence.makeAsyncIterator()
        let initialValue = try await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertTrue(initial.identifiers.isEmpty)

        writerContext.insert(QuerySequenceFixture(title: "inserted"))
        try writerContext.save()

        let updateValue = try await iterator.next()
        let update = try XCTUnwrap(updateValue)
        XCTAssertEqual(update.inserted.count, 1)
        XCTAssertEqual(update.identifiers.count, 1)
    }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [PersistentIdentifier]
    private var calls = 0

    init(_ identifiers: [PersistentIdentifier]) {
        self.identifiers = identifiers
    }

    func set(_ identifiers: [PersistentIdentifier]) {
        lock.lock()
        defer { lock.unlock() }
        self.identifiers = identifiers
    }

    func refresh() -> [PersistentIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return identifiers
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private enum QueryRefreshError: Error {
    case failed
}

private final class FailingRefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func refresh() throws -> [PersistentIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls > 1 { throw QueryRefreshError.failed }
        return []
    }
}
