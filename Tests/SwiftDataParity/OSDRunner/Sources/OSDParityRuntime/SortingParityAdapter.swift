import Foundation
import OpenSwiftData
import ParityContracts

@Model
final class ParitySortingThing {
    var name: String
    var optionalName: String?
    var rank: Double
    init(name: String, optionalName: String?, rank: Double) {
        self.name = name
        self.optionalName = optionalName
        self.rank = rank
    }
}

@Model
final class ParityModelContextInitThing {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
public enum OSDModelContextInitAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try ModelContextInitScenarioCatalog.all.map { specification in
            let container = try ModelContainer(
                for: ParityModelContextInitThing.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let result = ScenarioResult(id: specification.id, observations: [
                ParityObservation(step: 0, field: "contextAutosaveEnabled", value: .bool(context.autosaveEnabled)),
                ParityObservation(step: 0, field: "containerIdentityMatches", value: .bool(context.container === container)),
                ParityObservation(step: 0, field: "undoManagerAbsent", value: .bool(context.undoManager == nil)),
                ParityObservation(step: 0, field: "contextHasNoChanges", value: .bool(!context.hasChanges)),
                ParityObservation(step: 0, field: "mainContextAutosaveEnabled", value: .bool(container.mainContext.autosaveEnabled)),
            ])
            guard ModelContextInitExpectationValidator.validate(result, against: specification) else {
                throw ScenarioExpectationError(id: result.id, observations: result.observations)
            }
            return result
        }.sorted { $0.id.description < $1.id.description }
    }
}

@MainActor
public enum OSDSortingParityAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try SortingParityScenarioCatalog.all.filter(isAvailable).map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    public static func runAndValidate(_ specification: SortingParitySpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard SortingParityExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func isAvailable(_ specification: SortingParitySpecification) -> Bool {
        #if canImport(Darwin)
            true
        #else
            specification.query != .nameLocalizedStandard && specification.query != .nameLocalized
        #endif
    }

    private static func run(_ specification: SortingParitySpecification) throws -> ScenarioResult {
        let values: [String: ObservedValue]
        if specification.query == .descriptorAcceptsSortOrder {
            let order: Foundation.SortOrder = .reverse
            let sort: [Foundation.SortDescriptor<ParitySortingThing>] = [SortDescriptor(\.name, order: order)]
            let descriptor = FetchDescriptor<ParitySortingThing>(sortBy: sort)
            values = ["sortOrderPreserved": .bool(descriptor.sortBy.first?.order == .reverse)]
        } else {
            let names = ["b", "B", "a", "A", "item10", "item2", "é", "e", "Z", "_x", "10", "9", "ä"]
            let container = try ModelContainer(
                for: ParitySortingThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            for (index, name) in names.enumerated() {
                context.insert(ParitySortingThing(name: name, optionalName: index % 3 == 0 ? nil : name, rank: Double(index) - 5.5))
            }
            var descriptor = FetchDescriptor<ParitySortingThing>(sortBy: sorting(for: specification.query) + [SortDescriptor(\.rank)])
            let pending = try context.fetch(descriptor).map(\.name)
            try context.save()
            descriptor.includePendingChanges = false
            let saved = try context.fetch(descriptor).map(\.name)
            values = [
                "pending.names": .array(pending.map(ObservedValue.string)),
                "saved.names": .array(saved.map(ObservedValue.string)),
            ]
        }
        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { ParityObservation(step: 0, field: $0, value: values[$0]!) })
    }

    private static func sorting(for query: SortingParitySpecification.Query) -> [Foundation.SortDescriptor<ParitySortingThing>] {
        switch query {
        case .nameAscending: [SortDescriptor(\.name)]
        case .nameReverse: [SortDescriptor(\.name, order: .reverse)]
        case .nameLexical: [SortDescriptor(\.name, comparator: .lexical)]
        case .optionalNameAscending: [SortDescriptor(\.optionalName)]
        case .optionalNameReverse: [SortDescriptor(\.optionalName, order: .reverse)]
        case .rankReverse: [SortDescriptor(\.rank, order: .reverse)]
        #if canImport(Darwin)
        case .nameLocalizedStandard: [SortDescriptor(\.name, comparator: .localizedStandard)]
        case .nameLocalized: [SortDescriptor(\.name, comparator: .localized)]
        #else
        case .nameLocalizedStandard, .nameLocalized: []
        #endif
        case .descriptorAcceptsSortOrder: []
        }
    }
}
