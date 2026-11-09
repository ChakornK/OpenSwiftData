import ParityContracts
import SwiftData

@Model
final class AppleParityActorThing {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
enum AppleModelActorParityAdapter {
    static func runAll() throws -> [ScenarioResult] {
        let specification = ModelActorParityScenarioCatalog.wrapExistingContext
        let container = try ModelContainer(
            for: AppleParityActorThing.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let executor = DefaultSerialModelExecutor(modelContext: context)
        let result = ScenarioResult(id: specification.id, observations: [
            ParityObservation(
                step: 0, field: "executorContextIdentityMatches",
                value: .bool(executor.modelContext === context)),
        ])
        guard ModelActorParityExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return [result]
    }
}
