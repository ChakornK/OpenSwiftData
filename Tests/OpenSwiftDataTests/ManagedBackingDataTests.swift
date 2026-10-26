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

    func testSavedModelMutationSynchronouslyUpdatesPendingStateOffMainActor() async throws {
        let (context, model) = try await MainActor.run { () throws -> (ModelContext, MacroBackingTestModel) in
            let container = try ModelContainer(
                for: MacroBackingTestModel.self, configurations: .sqliteMemory("managed-backing-off-main"))
            let context = container.mainContext
            let model = MacroBackingTestModel(value: 1)
            context.insert(model)
            try context.save()
            return (context, model)
        }

        await Task.detached {
            model.value = 12
        }.value

        let result = await MainActor.run {
            (
                context.insertedModelsArray.count,
                context.changedModelsArray.contains { $0 === model },
                context.hasChanges
            )
        }
        XCTAssertEqual(result.0, 0)
        XCTAssertTrue(result.1)
        XCTAssertTrue(result.2)
        XCTAssertTrue(model.hasChanges)

        await MainActor.run { context.rollback() }
        XCTAssertEqual(model.value, 1)
        let hasChanges = await MainActor.run { context.hasChanges }
        XCTAssertFalse(hasChanges)
    }
}

@Model
final class MacroBackingTestModel {
    var value: Int
    init(value: Int) { self.value = value }
}
