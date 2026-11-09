import OpenSwiftData
import ParityContracts

@Model
final class ParityActorThing {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
public enum OSDModelActorParityAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        let specification = ModelActorParityScenarioCatalog.wrapExistingContext
        let container = try ModelContainer(
            for: ParityActorThing.self,
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
