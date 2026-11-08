import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class IdentityParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@available(macOS 15, *)
@Model
final class IdentityParityCustomID {
    var id: UUID
    var name: String
    init(id: UUID, name: String) { self.id = id; self.name = name }
}

@MainActor
@available(macOS 15, *)
enum AppleModelIdentityAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try ModelIdentityScenarioCatalog.all.map(run)
            .sorted { $0.id.description < $1.id.description }
    }

    private static func run(_ specification: ModelIdentitySpecification) throws -> ScenarioResult {
        let container = try makeContainer()
        let observations: [String: ObservedValue]
        switch specification.id {
        case ModelIdentityScenarioCatalog.instancesCompareByIdentity.id:
            let first = IdentityParityThing(name: "a")
            let second = IdentityParityThing(name: "a")
            let beforeSaveEqual = first != second
            container.mainContext.insert(first)
            container.mainContext.insert(second)
            try container.mainContext.save()
            observations = [
                "instances.sameReferenceEqual": .bool(first == first),
                "instances.distinctEqual": .bool(!beforeSaveEqual),
                "instances.distinctHashesDiffer": .bool(first.hashValue != second.hashValue),
                "instances.remainUnequalAfterSave": .bool(first != second),
            ]
        case ModelIdentityScenarioCatalog.idIsPersistentIdentifier.id:
            let model = IdentityParityThing(name: "a")
            let beforeSave = model.id == model.persistentModelID
            container.mainContext.insert(model)
            try container.mainContext.save()
            observations = [
                "id.matchesPersistentIDBeforeSave": .bool(beforeSave),
                "id.matchesPersistentIDAfterSave": .bool(model.id == model.persistentModelID),
            ]
        case ModelIdentityScenarioCatalog.savingReplacesTemporaryID.id:
            let model = IdentityParityThing(name: "a")
            container.mainContext.insert(model)
            let temporary = model.persistentModelID
            try container.mainContext.save()
            observations = [
                "id.changedAfterSave": .bool(model.persistentModelID != temporary),
                "id.temporaryStoreAbsent": .bool(temporary.storeIdentifier == nil),
                "id.savedStorePresent": .bool(model.persistentModelID.storeIdentifier != nil),
            ]
        case ModelIdentityScenarioCatalog.contextsUseDistinctInstances.id:
            let model = IdentityParityThing(name: "a")
            container.mainContext.insert(model)
            try container.mainContext.save()
            let otherContext = ModelContext(container)
            let copy = try otherContext.fetch(FetchDescriptor<IdentityParityThing>()).first
            observations = [
                "contexts.distinctReferences": .bool(copy.map { $0 !== model } ?? false),
                "contexts.modelsUnequal": .bool(copy.map { $0 != model } ?? false),
                "contexts.hashesEqual": .bool(copy.map { $0.hashValue == model.hashValue } ?? false),
                "contexts.setCount": .integer(Int64(copy.map { Set([model, $0]).count } ?? 0)),
            ]
        case ModelIdentityScenarioCatalog.declaredIDReplacesIdentifierID.id:
            let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let model = IdentityParityCustomID(id: uuid, name: "w")
            observations = ["customID.matchesDeclaredUUID": .bool(model.id == uuid)]
        case ModelIdentityScenarioCatalog.modelsConformToProtocols.id:
            let model = IdentityParityThing(name: "a")
            observations = [
                "conformance.identifiable": .bool(isIdentifiable(model)),
                "conformance.observable": .bool(isObservable(model)),
            ]
        default:
            throw ScenarioExpectationError(id: specification.id, observations: [])
        }
        return ScenarioResult(
            id: specification.id,
            observations: observations.sorted { $0.key < $1.key }.enumerated().map { step, pair in
                ParityObservation(step: step, field: pair.key, value: pair.value)
            })
    }

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: IdentityParityThing.self, IdentityParityCustomID.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func isIdentifiable<T: Identifiable>(_ value: T) -> Bool { true }
    private static func isObservable<T: Observable>(_ value: T) -> Bool { true }
}
