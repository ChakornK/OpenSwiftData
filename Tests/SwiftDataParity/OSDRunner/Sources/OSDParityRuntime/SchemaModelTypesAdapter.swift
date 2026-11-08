import OpenSwiftData
import ParityContracts

@Model
final class SchemaParityTrip {
    var name: String
    var stops: [SchemaParityStop] = []

    init(name: String) { self.name = name }
}

@Model
final class SchemaParityStop {
    var label: String
    var trip: SchemaParityTrip?

    init(label: String) { self.label = label }
}

enum SchemaParityVersionedV2: VersionedSchema {
    static var versionIdentifier: SchemaDescriptor.Version { SchemaDescriptor.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [SchemaParityTrip.self, SchemaParityStop.self] }
}

@MainActor
public enum OSDSchemaModelTypesAdapter {
    public static func runAll() throws -> [ScenarioResult] {
        try SchemaModelTypesScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    private static func runAndValidate(_ specification: SchemaModelTypesSpecification) throws -> ScenarioResult {
        let observations: [String: ObservedValue]
        switch specification.id {
        case SchemaModelTypesScenarioCatalog.entitiesInNameOrder.id:
            let schema = Schema([SchemaParityTrip.self, SchemaParityStop.self])
            let variadicSchema = Schema(SchemaParityTrip.self, SchemaParityStop.self)
            observations = [
                "entities.names": .array(schema.entities.map { .string($0.name) }),
                "schema.version": versionValue(schema.version),
                "schema.variadicEntityCount": .integer(Int64(variadicSchema.entities.count)),
            ]
        case SchemaModelTypesScenarioCatalog.relationshipDestinations.id:
            let schema = Schema([SchemaParityTrip.self, SchemaParityStop.self])
            observations = [
                "stop.lookup": .bool(schema.entity(for: SchemaParityStop.self) != nil),
                "trip.entityName": .string(Schema.entityName(for: SchemaParityTrip.self)),
            ]
        case SchemaModelTypesScenarioCatalog.emptySchema.id:
            let schema = Schema()
            observations = [
                "entities.names": .unorderedStrings(schema.entities.map(\.name)),
                "schema.version": versionValue(schema.version),
            ]
        case SchemaModelTypesScenarioCatalog.versionedSchema.id:
            let schema = Schema(versionedSchema: SchemaParityVersionedV2.self)
            observations = [
                "schema.version": versionValue(schema.version),
                "entities.count": .integer(Int64(schema.entities.count)),
            ]
        case SchemaModelTypesScenarioCatalog.containerRoundTrip.id:
            let schema = Schema([SchemaParityTrip.self, SchemaParityStop.self])
            let container = try ModelContainer(
                for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            let trip = SchemaParityTrip(name: "Coast")
            let stop = SchemaParityStop(label: "A")
            context.insert(trip)
            context.insert(stop)
            trip.stops.append(stop)
            try context.save()
            let freshContext = ModelContext(container)
            let fetchedTrips = try freshContext.fetch(FetchDescriptor<SchemaParityTrip>())
            let tripNames = fetchedTrips.map { ObservedValue.string($0.name) }
            let stopLabels = fetchedTrips.flatMap(\.stops).map { ObservedValue.string($0.label) }
            observations = [
                "fetched.tripNames": .array(tripNames),
                "fetched.stopLabels": .array(stopLabels),
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

    private static func versionValue(_ version: Schema.Version) -> ObservedValue {
        .array([.integer(Int64(version.major)), .integer(Int64(version.minor)), .integer(Int64(version.patch))])
    }
}
