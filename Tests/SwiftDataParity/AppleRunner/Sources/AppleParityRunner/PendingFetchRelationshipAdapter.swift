import Foundation
import ParityContracts
import SwiftData

@Model
final class ApplePendingRelationshipRoot {
    var name: String
    @Relationship(inverse: \ApplePendingRelationshipLeaf.root) var leaves: [ApplePendingRelationshipLeaf] = []
    var partner: ApplePendingRelationshipLeaf?
    init(name: String) { self.name = name }
}

@Model
final class ApplePendingRelationshipLeaf {
    var flag: Bool
    var root: ApplePendingRelationshipRoot?
    init(flag: Bool) { self.flag = flag }
}

@MainActor
enum ApplePendingFetchRelationshipAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try PendingFetchRelationshipScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: PendingFetchRelationshipSpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard PendingFetchRelationshipExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: PendingFetchRelationshipSpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: ApplePendingRelationshipRoot.self, ApplePendingRelationshipLeaf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let values: [String: ObservedValue]

        switch specification.query {
        case .relatedEditsDoNotAffectUnchangedOwners:
            let r1 = ApplePendingRelationshipRoot(name: "r1")
            let r2 = ApplePendingRelationshipRoot(name: "r2")
            let l1 = ApplePendingRelationshipLeaf(flag: false)
            let l2 = ApplePendingRelationshipLeaf(flag: true)
            let partner = ApplePendingRelationshipLeaf(flag: false)
            [r1, r2].forEach(context.insert)
            [l1, l2, partner].forEach(context.insert)
            r1.leaves = [l1]
            r2.leaves = [l2]
            r1.partner = partner
            try context.save()

            let containsFlag = FetchDescriptor<ApplePendingRelationshipRoot>(
                predicate: #Predicate { $0.leaves.contains { $0.flag } }, sortBy: [SortDescriptor(\.name)])
            let partnerUnflagged = FetchDescriptor<ApplePendingRelationshipRoot>(
                predicate: #Predicate { $0.partner?.flag == false })
            l1.flag = true
            let ownerHasChanges = r1.hasChanges
            let afterFirstLeafEdit = try context.fetch(containsFlag).map(\.name)
            partner.flag = true
            let afterPartnerEdit = try context.fetch(partnerUnflagged).map(\.name)
            l2.flag = false
            let afterSecondLeafEdit = try context.fetch(containsFlag).map(\.name)
            try context.save()
            let afterSave = try context.fetch(containsFlag).map(\.name)
            let partnerUnflaggedAfterSave = try context.fetch(partnerUnflagged).map(\.name)
            values = [
                "ownerHasChangesAfterLeafEdit": .bool(ownerHasChanges),
                "containsFlagAfterFirstLeafEdit": .array(afterFirstLeafEdit.map(ObservedValue.string)),
                "partnerUnflaggedAfterPartnerEdit": .array(afterPartnerEdit.map(ObservedValue.string)),
                "containsFlagAfterSecondLeafEdit": .array(afterSecondLeafEdit.map(ObservedValue.string)),
                "containsFlagAfterSave": .array(afterSave.map(ObservedValue.string)),
                "partnerUnflaggedAfterSave": .array(partnerUnflaggedAfterSave.map(ObservedValue.string)),
            ]
        case .relationshipMembershipReevaluatesOwner:
            let root = ApplePendingRelationshipRoot(name: "r1")
            context.insert(root)
            try context.save()
            let leaf = ApplePendingRelationshipLeaf(flag: true)
            context.insert(leaf)
            root.leaves.append(leaf)
            let descriptor = FetchDescriptor<ApplePendingRelationshipRoot>(
                predicate: #Predicate { $0.leaves.contains { $0.flag } })
            values = [
                "ownerHasChanges": .bool(root.hasChanges),
                "matchingOwners": .array(try context.fetch(descriptor).map { .string($0.name) }),
            ]
        case .detachedRelationshipAssignmentUpdatesInverse:
            let root = ApplePendingRelationshipRoot(name: "r")
            context.insert(root)
            try context.save()
            let leaf = ApplePendingRelationshipLeaf(flag: true)
            leaf.root = root
            values = [
                "leafManagedImmediately": .bool(leaf.modelContext === context),
                "ownerHasChanges": .bool(root.hasChanges),
                "ownerLeafCount": .integer(Int64(root.leaves.count)),
            ]
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { field in
                ParityObservation(step: 0, field: field, value: values[field]!)
            })
    }
}
