@testable import OpenSwiftData
import Foundation
import Testing

/// A minimal `DataStore`-conforming stub whose default-implementation methods
/// (`cachedSnapshots`, `initializeState`, `invalidateState`) are exercised by
/// the parity tests below. The stub's `fetch`/`save` throw to ensure the tests
/// never accidentally invoke them.
private final class NoOpDefaultsDataStore: DataStore, @unchecked Sendable {
    typealias Configuration = NoOpDefaultsConfiguration
    typealias Snapshot = AppleDefaultSnapshot
    let configuration: Configuration
    let identifier: String
    var schema: Schema { configuration.schema ?? Schema() }

    required init(_ configuration: Configuration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
        identifier = configuration.name
    }

    func fetch<Model: PersistentModel>(_ request: DataStoreFetchRequest<Model>) throws -> DataStoreFetchResult<Model, Snapshot> {
        throw SwiftDataError.unsupportedStore("NoOpDefaultsDataStore does not fetch.")
    }

    func save(_ request: DataStoreSaveChangesRequest<Snapshot>) throws -> DataStoreSaveChangesResult<Snapshot> {
        throw SwiftDataError.unsupportedStore("NoOpDefaultsDataStore does not save.")
    }
}

private struct NoOpDefaultsConfiguration: DataStoreConfiguration {
    typealias Store = NoOpDefaultsDataStore
    let name: String
    var schema: Schema?
}

extension NoOpDefaultsConfiguration: Equatable, Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// The no-op default `DataStore` methods (`cachedSnapshots`, `initializeState`,
/// `invalidateState`) are callable and return their default empty values, matching
/// Apple's SwiftData surface.
@MainActor struct DataStoreNoOpDefaultsParityTests {
    @Test func `cachedSnapshots returns an empty dictionary`() throws {
        let store = try NoOpDefaultsDataStore(NoOpDefaultsConfiguration(name: "no-op"), migrationPlan: nil)
        let editingState = EditingState(id: UUID(), author: nil)
        let snapshots = try store.cachedSnapshots(for: [], editingState: editingState)
        #expect(snapshots.isEmpty)
    }

    @Test func `initializeState returns without throwing`() throws {
        let store = try NoOpDefaultsDataStore(NoOpDefaultsConfiguration(name: "no-op"), migrationPlan: nil)
        let editingState = EditingState(id: UUID(), author: nil)
        store.initializeState(for: editingState)
        #expect(true)
    }

    @Test func `invalidateState returns without throwing`() throws {
        let store = try NoOpDefaultsDataStore(NoOpDefaultsConfiguration(name: "no-op"), migrationPlan: nil)
        let editingState = EditingState(id: UUID(), author: nil)
        store.invalidateState(for: editingState)
        #expect(true)
    }
}
