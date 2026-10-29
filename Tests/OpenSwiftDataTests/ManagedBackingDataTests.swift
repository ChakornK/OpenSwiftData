import XCTest
import OpenSwiftData
@testable import OpenSwiftData

@Model
private final class UndoRelationshipOwner {
    var name: String
    @Relationship(inverse: nil) var destination: UndoRelationshipDestination?
    init(name: String) { self.name = name }
}

@Model
private final class UndoRelationshipDestination {
    var name: String
    init(name: String) { self.name = name }
}

final class ManagedBackingDataTests: XCTestCase {
    @MainActor
    func testUndoGroupsMultiplePropertyMutationsAndSupportsRedo() throws {
        let container = try ModelContainer(
            for: MacroBackingTestModel.self, configurations: .sqliteMemory("undo-redo-grouping"))
        let context = container.mainContext
        let model = MacroBackingTestModel(value: 10, note: "initial")
        let secondModel = MacroBackingTestModel(value: 50, note: "second")
        context.insert(model)
        context.insert(secondModel)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager
        undoManager.removeAllActions()

        model.value = 20
        model.value = 30
        model.note = "edited"
        secondModel.value = 60
        secondModel.note = "second edited"
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(model.value, 10)
        XCTAssertEqual(model.note, "initial")
        XCTAssertEqual(secondModel.value, 50)
        XCTAssertEqual(secondModel.note, "second")
        XCTAssertTrue(model.hasChanges)
        try context.save()
        let restored = try XCTUnwrap(container.makeContext().fetch(FetchDescriptor<MacroBackingTestModel>()).first)
        XCTAssertEqual(restored.value, 10)
        XCTAssertEqual(restored.note, "initial")
        let restoredSecond = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<MacroBackingTestModel>()).first { $0.value == 50 })
        XCTAssertEqual(restoredSecond.note, "second")

        undoManager.redo()
        XCTAssertEqual(model.value, 30)
        XCTAssertEqual(model.note, "edited")
        XCTAssertEqual(secondModel.value, 60)
        XCTAssertEqual(secondModel.note, "second edited")
        XCTAssertTrue(model.hasChanges)
    }

    @MainActor
    func testUndoAndRedoRestoreRelationshipGraphChanges() throws {
        let container = try ModelContainer(
            for: UndoRelationshipOwner.self, UndoRelationshipDestination.self,
            configurations: .sqliteMemory("undo-relationship-graph"))
        let context = container.mainContext
        let owner = UndoRelationshipOwner(name: "owner")
        let destination = UndoRelationshipDestination(name: "destination")
        context.insert(owner)
        context.insert(destination)
        try context.save()
        context.undoManager = UndoManager()
        XCTAssertNil(owner.destination)

        owner.destination = destination
        XCTAssertTrue(owner.destination === destination)
        context.undoManager?.undo()
        XCTAssertNil(owner.destination)
        try context.save()
        context.undoManager?.redo()
        XCTAssertTrue(owner.destination === destination)
        try context.save()
        let redoneOwner = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<UndoRelationshipOwner>()).first)
        XCTAssertEqual(redoneOwner.destination?.name, "destination")

        context.undoManager?.undo()
        XCTAssertNil(owner.destination)
        try context.save()
        let freshOwner = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<UndoRelationshipOwner>()).first)
        XCTAssertNil(freshOwner.destination)
    }

    @MainActor
    func testFailedTransactionDoesNotContaminateNextUndoGroup() throws {
        let container = try ModelContainer(
            for: MacroBackingTestModel.self, configurations: .sqliteMemory("undo-failed-transaction"))
        let context = container.mainContext
        let model = MacroBackingTestModel(value: 1, note: "baseline")
        context.insert(model)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        XCTAssertThrowsError(
            try context.transaction {
                model.value = 10
                throw SwiftDataError.unsupportedStore("rollback transaction")
            })
        XCTAssertEqual(model.value, 1)
        XCTAssertFalse(undoManager.canUndo)

        model.value = 2
        undoManager.undo()
        XCTAssertEqual(model.value, 1)
    }

    @MainActor
    func testUndoSaveRefreshesBaselineForLaterMutations() throws {
        let container = try ModelContainer(
            for: MacroBackingTestModel.self, configurations: .sqliteMemory("undo-baseline-refresh"))
        let context = container.mainContext
        let model = MacroBackingTestModel(value: 1, note: "baseline")
        context.insert(model)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        model.value = 2
        try context.save()
        undoManager.undo()
        XCTAssertEqual(model.value, 1)
        try context.save()

        model.value = 3
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(context.hasChanges)
        try context.save()
        let fresh = try XCTUnwrap(container.makeContext().fetch(FetchDescriptor<MacroBackingTestModel>()).first)
        XCTAssertEqual(fresh.value, 3)
    }

    @MainActor
    func testRedoAfterSavingUndoRestoresPreviouslyCommittedEdit() throws {
        let container = try ModelContainer(
            for: MacroBackingTestModel.self, configurations: .sqliteMemory("undo-redo-after-save"))
        let context = container.mainContext
        let model = MacroBackingTestModel(value: 1, note: "baseline")
        context.insert(model)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        model.value = 2
        try context.save()
        undoManager.undo()
        try context.save()
        XCTAssertEqual(model.value, 1)

        undoManager.redo()
        XCTAssertEqual(model.value, 2)
        try context.save()
        XCTAssertEqual(
            try container.makeContext().fetch(FetchDescriptor<MacroBackingTestModel>()).first?.value,
            2)
    }

    @MainActor
    func testExplicitRollbackInvalidatesUndoForDiscardedChanges() throws {
        let container = try ModelContainer(
            for: MacroBackingTestModel.self, configurations: .sqliteMemory("undo-explicit-rollback"))
        let context = container.mainContext
        let model = MacroBackingTestModel(value: 1, note: "baseline")
        context.insert(model)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        model.value = 2
        context.rollback()
        XCTAssertEqual(model.value, 1)
        XCTAssertFalse(context.hasChanges)

        undoManager.undo()
        XCTAssertEqual(model.value, 1)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testUndoGroupPreservesRelationshipChangedAfterPropertyEdit() throws {
        let container = try ModelContainer(
            for: UndoRelationshipOwner.self, UndoRelationshipDestination.self,
            configurations: .sqliteMemory("undo-property-then-relationship"))
        let context = container.mainContext
        let owner = UndoRelationshipOwner(name: "before")
        let destination = UndoRelationshipDestination(name: "destination")
        context.insert(owner)
        context.insert(destination)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        owner.name = "after"
        owner.destination = destination
        undoManager.undo()
        XCTAssertEqual(owner.name, "before")
        XCTAssertNil(owner.destination)
    }

    @MainActor
    func testRelationshipEditAfterUndoGetsItsOwnUndoGroup() throws {
        let container = try ModelContainer(
            for: UndoRelationshipOwner.self, UndoRelationshipDestination.self,
            configurations: .sqliteMemory("undo-relationship-next-group"))
        let context = container.mainContext
        let owner = UndoRelationshipOwner(name: "owner")
        let first = UndoRelationshipDestination(name: "first")
        let second = UndoRelationshipDestination(name: "second")
        context.insert(owner)
        context.insert(first)
        context.insert(second)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        owner.destination = first
        undoManager.undo()
        XCTAssertNil(owner.destination)

        owner.destination = second
        undoManager.undo()
        XCTAssertNil(owner.destination)
    }

    @MainActor
    func testReplacingUndoManagerInvalidatesOldManagerActions() throws {
        let container = try ModelContainer(
            for: MacroBackingTestModel.self, configurations: .sqliteMemory("undo-manager-swap"))
        let context = container.mainContext
        let model = MacroBackingTestModel(value: 1, note: "value")
        context.insert(model)
        try context.save()
        let firstManager = UndoManager()
        context.undoManager = firstManager
        model.value = 2

        let replacementManager = UndoManager()
        context.undoManager = replacementManager
        model.value = 3
        firstManager.undo()
        XCTAssertEqual(model.value, 3)
        replacementManager.undo()
        XCTAssertEqual(model.value, 2)
    }

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

    func testManagedSlotAccessPreservesOptionalNilAndRestoresOverlay() {
        let context = ModelContext()
        let backing = ManagedBackingData<MacroBackingTestModel>(
            metadata: MacroBackingTestModel.schemaMetadata(),
            values: [\MacroBackingTestModel.value: 10, \MacroBackingTestModel.note: "baseline" as Any],
            context: context, storeIdentifier: "memory", entityID: 1,
            identifier: PersistentIdentifier(
                storeIdentifier: "memory", entityName: "MacroBackingTestModel", temporaryIdentifier: UUID()))
        let model = MacroBackingTestModel(backingData: backing)
        backing.attach(to: context, model: model)
        let snapshot = backing.snapshot()

        backing.setValue(at: 1, forKey: \MacroBackingTestModel.note, to: nil as String?)
        XCTAssertNil(backing.getValue(at: 1, forKey: \MacroBackingTestModel.note) as String?)
        backing.restore(snapshot)
        XCTAssertEqual(backing.getValue(at: 1, forKey: \MacroBackingTestModel.note), "baseline")
    }

    @MainActor
    func testManagedSlotAccessObservesValuesLoadedByPropertyFaults() {
        let context = ModelContext()
        let backing = ManagedBackingData<MacroBackingTestModel>(
            metadata: MacroBackingTestModel.schemaMetadata(), values: [:], context: context,
            storeIdentifier: "memory", entityID: 1,
            identifier: PersistentIdentifier(
                storeIdentifier: "memory", entityName: "MacroBackingTestModel", temporaryIdentifier: UUID()))
        backing.installFaultLoader(faultedProperties: [\MacroBackingTestModel.value]) { _ in
            [\MacroBackingTestModel.value: 21]
        }
        XCTAssertEqual(backing.getValue(at: 0, forKey: \MacroBackingTestModel.value), 21)
    }

    func testSavedModelMutationSynchronouslyUpdatesPendingStateOffMainActor() async throws {
        let model = try await MainActor.run { () throws -> MacroBackingTestModel in
            let container = try ModelContainer(
                for: MacroBackingTestModel.self, configurations: .sqliteMemory("managed-backing-off-main"))
            let context = container.mainContext
            let model = MacroBackingTestModel(value: 1)
            context.insert(model)
            try context.save()
            return model
        }

        await Task.detached {
            model.value = 12
        }.value

        let result = try await MainActor.run { () throws -> (Int, Bool, Bool) in
            guard let context = model.modelContext else {
                throw SwiftDataError.unsupportedStore("missing test context")
            }
            let result = (
                context.insertedModelsArray.count,
                context.changedModelsArray.contains { $0 === model },
                context.hasChanges
            )
            context.rollback()
            return result
        }
        XCTAssertEqual(result.0, 0)
        XCTAssertTrue(result.1)
        XCTAssertTrue(result.2)

        XCTAssertEqual(model.value, 1)
        XCTAssertFalse(model.hasChanges)
    }
}

@Model
final class MacroBackingTestModel {
    var value: Int
    var note: String?
    init(value: Int, note: String? = nil) {
        self.value = value
        self.note = note
    }
}
