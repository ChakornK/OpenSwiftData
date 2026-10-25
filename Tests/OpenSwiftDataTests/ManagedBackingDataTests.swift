import XCTest
import OpenSwiftData
@testable import OpenSwiftData

final class ManagedBackingDataTests: XCTestCase {
    @MainActor
    func testSnapshotKeepsBaselineAndOverlaysWritesUntilRestore() {
        let context = ModelContext()
        let backing = ManagedBackingData<MacroBackingTestModel>(
            metadata: MacroBackingTestModel.schemaMetadata(),
            values: [\MacroBackingTestModel.value: 10], context: context,
            storeIdentifier: "memory", entityID: 1,
            identifier: PersistentIdentifier(
                storeIdentifier: "memory", entityName: "MacroBackingTestModel", temporaryIdentifier: UUID())
        )
        let model = MacroBackingTestModel(backingData: backing)
        backing.attach(to: context, model: model)
        let initial = backing.snapshot()

        model.value = 12
        XCTAssertEqual(model.value, 12)
        XCTAssertTrue(model.hasChanges)
        backing.restore(initial)
        XCTAssertEqual(model.value, 10)
        XCTAssertFalse(model.hasChanges)
    }
}

@Model
final class MacroBackingTestModel {
    var value: Int
    init(value: Int) { self.value = value }
}
