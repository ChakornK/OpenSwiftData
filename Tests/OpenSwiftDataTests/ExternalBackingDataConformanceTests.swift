import OpenSwiftData
import XCTest

final class ExternalBackingDataConformanceTests: XCTestCase {
    func testLegacyBackingDataConformerUsesDefaultMutationHook() {
        let backing = LegacyBackingData()
        backing.withMutation {}
        XCTAssertEqual(backing.mutationEvents, ["will", "record"])
    }
}

private final class LegacyBackingData: BackingData {
    typealias Model = LegacyModel

    var mutationEvents: [String] = []
    var persistentModelID: PersistentIdentifier { fatalError("Unused fixture API") }
    var modelContext: ModelContext? { nil }
    var isDeleted: Bool { false }
    var hasChanges: Bool { false }

    func getValue<Value>(forKey keyPath: KeyPath<LegacyModel, Value>) -> Value { fatalError("Unused fixture API") }
    func setValue<Value>(forKey keyPath: KeyPath<LegacyModel, Value>, to value: Value) {}
    func willMutate() { mutationEvents.append("will") }
    func recordMutation() { mutationEvents.append("record") }
    func snapshot() -> BackingDataSnapshot { fatalError("Unused fixture API") }
    func restore(_ snapshot: BackingDataSnapshot) {}
    func restoreValues(_ snapshot: BackingDataSnapshot) {}
    func restoreValuesAndDetach(_ snapshot: BackingDataSnapshot) {}
    func restoreValuesAndDetach() {}
    func restoreLifecycleAndDetach(_ snapshot: BackingDataSnapshot) {}
    func cancelInsertion(restoring snapshot: BackingDataSnapshot) {}
    func markPersisted(storeIdentifier: String, entityID: Int, primaryKey: Int64, version: Int) {}
    func restoreInsertionState() {}
    func attach(to context: ModelContext, model: LegacyModel) {}
    func markDeleted() {}
    func cancelInsertion() {}
    func markSaved() {}
    func detach() {}
    func detachDeleted() {}
}

private final class LegacyModel: PersistentModel {
    var persistentBackingData: any BackingData<LegacyModel> {
        get { fatalError("Unused fixture API") }
        set { fatalError("Unused fixture API") }
    }

    init(backingData: any BackingData<LegacyModel>) {}
    static func schemaMetadata() -> [Schema.PropertyMetadata] { [] }
    static func createBackingData() -> DetachedBackingData<LegacyModel> {
        DetachedBackingData(metadata: [])
    }
}
