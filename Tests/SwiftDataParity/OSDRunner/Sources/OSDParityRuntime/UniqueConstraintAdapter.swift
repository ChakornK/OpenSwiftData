import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class UniqueParityKeyedModel {
    @Attribute(.unique) var key: String
    var value: Int
    var note: String?

    init(_ key: String, _ value: Int, _ note: String? = nil) {
        self.key = key
        self.value = value
        self.note = note
    }
}

@Model
final class UniqueParityCompositeModel {
    #Unique<UniqueParityCompositeModel>([\.a, \.b], [\.c])
    var a: Int
    var b: Int
    var c: String
    var value: Int

    init(_ a: Int, _ b: Int, _ c: String, _ value: Int) {
        self.a = a
        self.b = b
        self.c = c
        self.value = value
    }
}

@MainActor
public enum OSDUniqueConstraintAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try UniqueConstraintScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: UniqueConstraintSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard UniqueConstraintExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: UniqueConstraintSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: UniqueParityKeyedModel.self, UniqueParityCompositeModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let values: [String: ObservedValue]

        switch specification.query {
        case .insertingDuplicateOverwrites:
            let original = UniqueParityKeyedModel("k", 1, "n1")
            context.insert(original)
            try context.save()
            let duplicate = UniqueParityKeyedModel("k", 2)
            let oldID = duplicate.persistentModelID
            context.insert(duplicate)
            let preSaveCount = try context.fetchCount(FetchDescriptor<UniqueParityKeyedModel>())
            try context.save()
            let fetched = try context.fetch(FetchDescriptor<UniqueParityKeyedModel>())
            values = [
                "preSaveCount": .integer(Int64(preSaveCount)),
                "storedRows": .array(try storedKeyed(in: container)),
                "originalValue": .integer(Int64(original.value)),
                "originalAttached": .bool(original.modelContext === context),
                "originalDeleted": .bool(original.isDeleted),
                "duplicateAttached": .bool(duplicate.modelContext === context),
                "duplicateIDChangedOnSave": .bool(duplicate.persistentModelID != oldID),
                "contextClean": .bool(!context.hasChanges),
                "fetchedOriginalInstance": .bool(fetched.first === original),
            ]
        case .mergedDuplicateEditsDoNotPersist:
            context.insert(UniqueParityKeyedModel("k", 1))
            try context.save()
            let duplicate = UniqueParityKeyedModel("k", 2)
            context.insert(duplicate)
            try context.save()
            duplicate.value = 99
            let hasChangesAfterEdit = context.hasChanges
            try context.save()
            values = [
                "hasChangesAfterEdit": .bool(hasChangesAfterEdit),
                "storedRowsAfterSecondSave": .array(try storedKeyed(in: container)),
            ]
        case .mergedDuplicateIdentifier:
            context.insert(UniqueParityKeyedModel("k", 1))
            try context.save()
            let duplicate = UniqueParityKeyedModel("k", 2)
            let oldID = duplicate.persistentModelID
            context.insert(duplicate)
            try context.save()
            let survivor = try required(context.fetch(FetchDescriptor<UniqueParityKeyedModel>()).first)
            values = [
                "duplicateIDChangedOnSave": .bool(duplicate.persistentModelID != oldID),
                "duplicateRegistered": .bool(
                    (context.registeredModel(for: duplicate.persistentModelID) as UniqueParityKeyedModel?) === duplicate),
                "duplicateIDDiffersFromSurvivor": .bool(duplicate.persistentModelID != survivor.persistentModelID),
            ]
        case .deletingMergedDuplicate:
            context.insert(UniqueParityKeyedModel("k", 1))
            try context.save()
            let duplicate = UniqueParityKeyedModel("k", 2)
            context.insert(duplicate)
            try context.save()
            context.delete(duplicate)
            try context.save()
            values = ["storedRowsAfterDelete": .array(try storedKeyed(in: container))]
        case .duplicatesInOneSave:
            var survivors: [String] = []
            var everyTrialHasOneRow = true
            for _ in 0..<20 {
                let trialContainer = try makeContainer()
                let trialContext = trialContainer.mainContext
                trialContext.insert(UniqueParityKeyedModel("z", 1))
                trialContext.insert(UniqueParityKeyedModel("z", 2))
                try trialContext.save()
                let rows = try ModelContext(trialContainer).fetch(FetchDescriptor<UniqueParityKeyedModel>())
                everyTrialHasOneRow = everyTrialHasOneRow && rows.count == 1
                survivors.append(contentsOf: rows.map { "\($0.key)/\($0.value)/\($0.note ?? "nil")" })
            }
            values = [
                "everyTrialHasOneRow": .bool(everyTrialHasOneRow),
                "survivorsObserved": .stringSet(survivors),
            ]
        case .updatingIntoConflict:
            context.insert(UniqueParityKeyedModel("k", 2))
            let updated = UniqueParityKeyedModel("m", 5, "mm")
            context.insert(updated)
            try context.save()
            let originalID = updated.persistentModelID
            updated.key = "k"
            try context.save()
            values = [
                "storedRows": .array(try storedKeyed(in: container)),
                "updatedIDUnchanged": .bool(updated.persistentModelID == originalID),
                "updatedAttached": .bool(updated.modelContext === context),
                "updatedDeleted": .bool(updated.isDeleted),
                "updatedValue": .integer(Int64(updated.value)),
            ]
        case .compositeConstraints:
            context.insert(UniqueParityCompositeModel(1, 1, "x", 1))
            try context.save()
            context.insert(UniqueParityCompositeModel(1, 1, "y", 2))
            try context.save()
            context.insert(UniqueParityCompositeModel(2, 2, "y", 3))
            try context.save()
            let rows = try ModelContext(container).fetch(FetchDescriptor<UniqueParityCompositeModel>())
            values = [
                "storedRows": .array(rows.map(compositeProjection)),
            ]
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { field in
                ParityObservation(step: 0, field: field, value: values[field]!)
            })
    }

    private static func storedKeyed(in container: ModelContainer) throws -> [ObservedValue] {
        try ModelContext(container).fetch(
            FetchDescriptor<UniqueParityKeyedModel>(sortBy: [SortDescriptor(\.key)])).map(keyedProjection)
    }

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: UniqueParityKeyedModel.self, UniqueParityCompositeModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func keyedProjection(_ model: UniqueParityKeyedModel) -> ObservedValue {
        .string("\(model.key)/\(model.value)/\(model.note ?? "nil")")
    }

    private static func compositeProjection(_ model: UniqueParityCompositeModel) -> ObservedValue {
        .string("\(model.a)\(model.b)\(model.c)/\(model.value)")
    }

    private static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw UniqueConstraintAdapterError.missingValue }
        return value
    }
}

private enum UniqueConstraintAdapterError: Error {
    case missingValue
}
