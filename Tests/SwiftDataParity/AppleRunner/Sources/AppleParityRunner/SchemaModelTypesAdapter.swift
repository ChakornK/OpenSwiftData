import ParityContracts
import SwiftData

@available(macOS 26, *)
@Model
final class SchemaParityTrip {
    var name: String
    var stops: [SchemaParityStop] = []

    init(name: String) { self.name = name }
}

@available(macOS 26, *)
@Model
final class SchemaParityStop {
    var label: String
    var trip: SchemaParityTrip?

    init(label: String) { self.label = label }
}

@available(macOS 26, *)
enum SchemaParityVersionedV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [SchemaParityTrip.self, SchemaParityStop.self] }
}

@MainActor
@available(macOS 26, *)
enum AppleSchemaModelTypesAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try SchemaModelTypesScenarioCatalog.all.map(run)
            .sorted { $0.id.description < $1.id.description }
    }

    private static func run(_ specification: SchemaModelTypesSpecification) throws -> ScenarioResult {
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
            let context = ModelContext(container)
            let trip = SchemaParityTrip(name: "Coast")
            let stop = SchemaParityStop(label: "A")
            context.insert(trip)
            context.insert(stop)
            trip.stops.append(stop)
            try context.save()
            let freshContext = ModelContext(container)
            let fetchedTrips = try freshContext.fetch(FetchDescriptor<SchemaParityTrip>())
            observations = [
                "fetched.tripNames": .array(fetchedTrips.map { .string($0.name) }),
                "fetched.stopLabels": .array(fetchedTrips.flatMap(\.stops).map { .string($0.label) }),
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
