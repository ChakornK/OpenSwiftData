import OSDCore

/// Provides a named, versioned schema and the model types it contains.
public protocol VersionedSchema: Sendable {
    /// The version identity persisted with this schema.
    static var versionIdentifier: Schema.Version { get }
    /// The model types used to materialize values during migration stages.
    static var models: [any PersistentModel.Type] { get }
    /// The schema layout for this version.
    static var schema: Schema { get }
}

/// Declares the ordered schemas and transitions used to migrate a model container.
public protocol SchemaMigrationPlan: Sendable {
    /// The available schema versions in migration order.
    static var schemas: [any VersionedSchema.Type] { get }
    /// The transitions connecting adjacent schemas.
    static var stages: [MigrationStage] { get }
}

/// Describes one migration transition between two versioned schemas.
public struct MigrationStage: @unchecked Sendable {
    /// The transition strategy.
    public enum Strategy {
        /// Applies the supported schema changes without custom callbacks.
        case lightweight
        /// Runs custom context callbacks around schema changes supported by the lightweight engine.
        case custom
    }

    /// The source schema version.
    public let sourceVersion: Schema.Version
    /// The destination schema version.
    public let destinationVersion: Schema.Version
    /// The strategy for this transition.
    public let strategy: Strategy
    /// Runs transactionally with a context using the source schema before the transition.
    public let willMigrate: (@Sendable (ModelContext) throws -> Void)?
    /// Runs transactionally with a context using the destination schema after the transition.
    public let didMigrate: (@Sendable (ModelContext) throws -> Void)?

    /// Creates a lightweight transition.
    public static func lightweight<Source: VersionedSchema, Destination: VersionedSchema>(
        fromVersion source: Source.Type,
        toVersion destination: Destination.Type
    ) -> Self {
        Self(
            sourceVersion: Source.versionIdentifier,
            destinationVersion: Destination.versionIdentifier,
            strategy: .lightweight,
            willMigrate: nil,
            didMigrate: nil)
    }

    /// Creates a transition with source and destination context callbacks. Structural changes still use the
    /// lightweight engine; unsupported table-layout changes fail closed.
    public static func custom<Source: VersionedSchema, Destination: VersionedSchema>(
        fromVersion source: Source.Type,
        toVersion destination: Destination.Type,
        willMigrate: (@Sendable (ModelContext) throws -> Void)? = nil,
        didMigrate: (@Sendable (ModelContext) throws -> Void)? = nil
    ) -> Self {
        Self(
            sourceVersion: Source.versionIdentifier,
            destinationVersion: Destination.versionIdentifier,
            strategy: .custom,
            willMigrate: willMigrate,
            didMigrate: didMigrate)
    }

    private init(
        sourceVersion: Schema.Version,
        destinationVersion: Schema.Version,
        strategy: Strategy,
        willMigrate: (@Sendable (ModelContext) throws -> Void)?,
        didMigrate: (@Sendable (ModelContext) throws -> Void)?
    ) {
        self.sourceVersion = sourceVersion
        self.destinationVersion = destinationVersion
        self.strategy = strategy
        self.willMigrate = willMigrate
        self.didMigrate = didMigrate
    }
}

struct MigrationPlanDescriptor: @unchecked Sendable {
    let schemas: [(version: Schema.Version, schema: Schema, models: [any PersistentModel.Type])]
    let stages: [MigrationStage]

    init<Plan: SchemaMigrationPlan>(_ plan: Plan.Type) throws {
        schemas = Plan.schemas.map { versioned in
            (version: versioned.versionIdentifier, schema: versioned.schema, models: versioned.models)
        }
        stages = Plan.stages
        try validate()
    }

    private func validate() throws {
        guard !schemas.isEmpty, stages.count == schemas.count - 1 else {
            throw SwiftDataError.migrationUnsupported("Migration plans must connect every ordered schema version.")
        }
        var identifiers: Set<String> = []
        for schema in schemas {
            guard schema.schema.version == schema.version else {
                throw SwiftDataError.migrationUnsupported(
                    "Versioned schema '\(schema.version.identifier)' must carry its declared schema version.")
            }
            guard identifiers.insert(schema.version.identifier).inserted else {
                throw SwiftDataError.migrationUnsupported("Migration plan contains duplicate schema versions.")
            }
        }
        for (index, stage) in stages.enumerated() {
            guard stage.sourceVersion == schemas[index].version,
                stage.destinationVersion == schemas[index + 1].version
            else {
                throw SwiftDataError.migrationUnsupported("Migration stages must connect adjacent ordered schemas.")
            }
            if case .custom = stage.strategy, stage.willMigrate == nil, stage.didMigrate == nil {
                throw SwiftDataError.migrationUnsupported("Custom migration stages require at least one callback.")
            }
        }
    }
}
