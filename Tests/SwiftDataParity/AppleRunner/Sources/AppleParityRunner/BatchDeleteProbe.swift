import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class AppleBatchDeleteOwner {
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \AppleBatchDeletePet.owner) var pets: [AppleBatchDeletePet] = []

    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class AppleBatchDeletePet {
    var name: String
    var owner: AppleBatchDeleteOwner?

    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class AppleBatchDeleteKeeper {
    var name: String
    @Relationship(deleteRule: .deny, inverse: \AppleBatchDeleteToy.keeper) var toys: [AppleBatchDeleteToy] = []

    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class AppleBatchDeleteToy {
    var name: String
    var keeper: AppleBatchDeleteKeeper?

    init(name: String) { self.name = name }
}

@MainActor
@available(macOS 15, *)
enum AppleBatchDeleteProbe {
    static func run() throws -> [ParityObservation] {
        let container = try ModelContainer(
            for: AppleBatchDeleteOwner.self,
            AppleBatchDeletePet.self,
            AppleBatchDeleteKeeper.self,
            AppleBatchDeleteToy.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var observations: [ParityObservation] = []
        observations.append(try pendingAndRegisteredState(container))
        observations.append(try cascadeCount(container))
        observations.append(try notificationCount(container))
        observations.append(try denyResult(container))
        observations.append(try transactionResult(container))
        observations.append(try noMatchResult(container))
        return observations
    }

    private static func pendingAndRegisteredState(_ container: ModelContainer) throws -> ParityObservation {
        let context = container.mainContext
        let saved = [AppleBatchDeleteOwner(name: "a"), AppleBatchDeleteOwner(name: "b")]
        saved.forEach(context.insert)
        try context.save()
        let pending = AppleBatchDeleteOwner(name: "c")
        context.insert(pending)
        try context.delete(model: AppleBatchDeleteOwner.self, where: #Predicate { $0.name == "a" || $0.name == "c" })
        let otherContext = ModelContext(container)
        let savedNames = try otherContext.fetch(savedOwners()).map(\.name)
        let pendingNames = try context.fetch(FetchDescriptor<AppleBatchDeleteOwner>(sortBy: [SortDescriptor(\.name)])).map(\.name)
        return ParityObservation(step: 0, field: "pendingAndRegistered", value: .object([
            "hasChanges": .bool(context.hasChanges),
            "insertedCount": .integer(Int64(context.insertedModelsArray.count)),
            "deletedCount": .integer(Int64(context.deletedModelsArray.count)),
            "savedADeleted": .bool(saved[0].isDeleted),
            "savedARegistered": .bool(saved[0].modelContext === context),
            "pendingCRegistered": .bool(pending.modelContext === context),
            "otherContextNames": .array(savedNames.map(ObservedValue.string)),
            "mainContextNames": .array(pendingNames.map(ObservedValue.string)),
        ]))
    }

    private static func cascadeCount(_ container: ModelContainer) throws -> ParityObservation {
        let context = container.mainContext
        let owner = AppleBatchDeleteOwner(name: "owner")
        let pet = AppleBatchDeletePet(name: "pet")
        context.insert(owner)
        context.insert(pet)
        owner.pets.append(pet)
        try context.save()
        try context.delete(model: AppleBatchDeleteOwner.self)
        let count = try ModelContext(container).fetchCount(FetchDescriptor<AppleBatchDeletePet>())
        return ParityObservation(step: 0, field: "cascade.petCount", value: .integer(Int64(count)))
    }

    private static func notificationCount(_ container: ModelContainer) throws -> ParityObservation {
        let context = container.mainContext
        context.insert(AppleBatchDeleteOwner(name: "notification"))
        try context.save()
        let counter = BatchDeleteNotificationCounter()
        let tokens = [ModelContext.willSave, ModelContext.didSave].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                guard let source = notification.object as? ModelContext, source.container === container else { return }
                counter.increment()
            }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }
        try context.delete(model: AppleBatchDeleteOwner.self)
        return ParityObservation(step: 0, field: "notifications.count", value: .integer(Int64(counter.value)))
    }

    private static func denyResult(_ container: ModelContainer) throws -> ParityObservation {
        let context = container.mainContext
        let keeper = AppleBatchDeleteKeeper(name: "keeper")
        let toy = AppleBatchDeleteToy(name: "toy")
        context.insert(keeper)
        context.insert(toy)
        keeper.toys.append(toy)
        try context.save()
        do {
            try context.delete(model: AppleBatchDeleteKeeper.self)
            return ParityObservation(step: 0, field: "deny", value: .object(["threw": .bool(false)]))
        } catch {
            let error = error as NSError
            return ParityObservation(step: 0, field: "deny", value: .object([
                "threw": .bool(true),
                "domain": .string(error.domain),
                "code": .integer(Int64(error.code)),
                "relationship": .string(error.userInfo["Relationship"] as? String ?? ""),
                "reason": .string(error.userInfo["Reason"] as? String ?? ""),
                "remainingKeepers": .integer(Int64(try context.fetchCount(FetchDescriptor<AppleBatchDeleteKeeper>()))),
                "toyStillLinked": .bool(toy.keeper === keeper),
            ]))
        }
    }

    private static func transactionResult(_ container: ModelContainer) throws -> ParityObservation {
        let context = container.mainContext
        context.insert(AppleBatchDeleteOwner(name: "transaction"))
        try context.save()
        do {
            try context.transaction {
                try context.delete(model: AppleBatchDeleteOwner.self)
                throw BatchDeleteProbeError.stop
            }
        } catch BatchDeleteProbeError.stop {}
        let count = try ModelContext(container).fetchCount(FetchDescriptor<AppleBatchDeleteOwner>())
        return ParityObservation(step: 0, field: "transaction.remainingCount", value: .integer(Int64(count)))
    }

    private static func noMatchResult(_ container: ModelContainer) throws -> ParityObservation {
        let context = container.mainContext
        context.insert(AppleBatchDeleteOwner(name: "kept"))
        try context.save()
        try context.delete(model: AppleBatchDeleteOwner.self, where: #Predicate { $0.name == "absent" })
        let count = try context.fetchCount(savedOwners())
        return ParityObservation(step: 0, field: "noMatch", value: .object([
            "hasChanges": .bool(context.hasChanges),
            "count": .integer(Int64(count)),
        ]))
    }

    private static func savedOwners() -> FetchDescriptor<AppleBatchDeleteOwner> {
        var descriptor = FetchDescriptor<AppleBatchDeleteOwner>(sortBy: [SortDescriptor(\.name)])
        descriptor.includePendingChanges = false
        return descriptor
    }
}

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

private enum BatchDeleteProbeError: Error { case stop }
