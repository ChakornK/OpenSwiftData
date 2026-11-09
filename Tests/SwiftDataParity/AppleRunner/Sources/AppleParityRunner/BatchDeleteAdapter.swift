import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class BatchParityOwner {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \BatchParityPet.owner) var pets: [BatchParityPet] = []
    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class BatchParityPet {
    var name: String
    var owner: BatchParityOwner?
    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class BatchParityKeeper {
    var name: String
    @Relationship(deleteRule: .deny, inverse: \BatchParityToy.keeper) var toys: [BatchParityToy] = []
    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class BatchParityToy {
    var name: String
    var keeper: BatchParityKeeper?
    init(name: String) { self.name = name }
}

@MainActor
@available(macOS 15, *)
enum AppleBatchDeleteAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try BatchDeleteScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: BatchDeleteSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard BatchDeleteExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    static func run(_ specification: BatchDeleteSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: BatchParityOwner.self, BatchParityPet.self, BatchParityKeeper.self, BatchParityToy.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let observations = try specification.steps.enumerated().map { step, item in
            ParityObservation(
                step: step,
                field: item.observationField,
                value: try observe(item.operation, container: container, context: context))
        }
        return ScenarioResult(id: specification.id, observations: observations)
    }

    private static func observe(
        _ operation: BatchDeleteSpecification.Operation,
        container: ModelContainer,
        context: ModelContext
    ) throws -> ObservedValue {
        switch operation {
        case .pendingAndRegisteredState:
            let saved = [BatchParityOwner(name: "a"), BatchParityOwner(name: "b")]
            saved.forEach(context.insert)
            try context.save()
            let pending = BatchParityOwner(name: "c")
            context.insert(pending)
            try context.delete(model: BatchParityOwner.self, where: #Predicate { $0.name == "a" || $0.name == "c" })
            let hasChanges = context.hasChanges
            let insertedCount = context.insertedModelsArray.count
            let deletedCount = context.deletedModelsArray.count
            let otherNames = try ModelContext(container).fetch(savedOwners()).map(\.name)
            let currentNames = try context.fetch(FetchDescriptor<BatchParityOwner>(sortBy: [SortDescriptor(\.name)])).map(\.name)
            try context.save()
            let afterSaveNames = try ModelContext(container).fetch(savedOwners()).map(\.name)
            return .object([
                "hasChanges": .bool(hasChanges),
                "insertedCount": .integer(Int64(insertedCount)),
                "deletedCount": .integer(Int64(deletedCount)),
                "savedADeleted": .bool(saved[0].isDeleted),
                "savedARegistered": .bool(saved[0].modelContext === context),
                "pendingCRegistered": .bool(pending.modelContext === context),
                "otherContextNames": .array(otherNames.map(ObservedValue.string)),
                "mainContextNames": .array(currentNames.map(ObservedValue.string)),
                "afterSaveNames": .array(afterSaveNames.map(ObservedValue.string)),
            ])
        case .cascadePetCount:
            let owner = BatchParityOwner(name: "owner")
            let pet = BatchParityPet(name: "pet")
            context.insert(owner)
            context.insert(pet)
            owner.pets.append(pet)
            try context.save()
            try context.delete(model: BatchParityOwner.self)
            return .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<BatchParityPet>())))
        case .notificationCount:
            context.insert(BatchParityOwner(name: "notification"))
            try context.save()
            let counter = BatchDeleteNotificationCounter()
            let tokens = [ModelContext.willSave, ModelContext.didSave].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                    guard let source = notification.object as? ModelContext, source.container === container else { return }
                    counter.increment()
                }
            }
            defer { tokens.forEach(NotificationCenter.default.removeObserver) }
            try context.delete(model: BatchParityOwner.self)
            return .integer(Int64(counter.value))
        case .denyError:
            let keeper = BatchParityKeeper(name: "keeper")
            let toy = BatchParityToy(name: "toy")
            context.insert(keeper)
            context.insert(toy)
            keeper.toys.append(toy)
            try context.save()
            do {
                try context.delete(model: BatchParityKeeper.self)
                return .object(["threw": .bool(false)])
            } catch {
                let error = error as NSError
                return .object([
                    "threw": .bool(true),
                    "domain": .string(error.domain),
                    "code": .integer(Int64(error.code)),
                    "relationship": .string(error.userInfo["Relationship"] as? String ?? ""),
                    "reason": .string(error.userInfo["Reason"] as? String ?? ""),
                    "remainingKeepers": .integer(Int64(try context.fetchCount(FetchDescriptor<BatchParityKeeper>()))),
                    "toyStillLinked": .bool(toy.keeper === keeper),
                ])
            }
        case .transactionRemainingCount:
            context.insert(BatchParityOwner(name: "transaction"))
            try context.save()
            do {
                try context.transaction {
                    try context.delete(model: BatchParityOwner.self)
                    throw BatchDeleteAdapterError.stop
                }
            } catch BatchDeleteAdapterError.stop {}
            return .integer(Int64(try ModelContext(container).fetchCount(FetchDescriptor<BatchParityOwner>())))
        case .noMatchState:
            context.insert(BatchParityOwner(name: "kept"))
            try context.save()
            try context.delete(model: BatchParityOwner.self, where: #Predicate { $0.name == "absent" })
            return .object([
                "hasChanges": .bool(context.hasChanges),
                "count": .integer(Int64(try context.fetchCount(savedOwners()))),
            ])
        }
    }

    private static func savedOwners() -> FetchDescriptor<BatchParityOwner> {
        var descriptor = FetchDescriptor<BatchParityOwner>(sortBy: [SortDescriptor(\.name)])
        descriptor.includePendingChanges = false
        return descriptor
    }
}

private enum BatchDeleteAdapterError: Error { case stop }

private final class BatchDeleteNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
