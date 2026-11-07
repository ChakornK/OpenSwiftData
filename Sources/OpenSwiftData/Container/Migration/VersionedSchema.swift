import OSDCore

/// Provides a named, versioned schema and the model types it contains.
public protocol VersionedSchema: Sendable {
    /// The version identity persisted with this schema.
    static var versionIdentifier: Schema.Version { get }
    /// The model types used to materialize values during migration stages.
    static var models: [any PersistentModel.Type] { get }
    /// The schema layout for this version; defaults to the schema inferred from `models`.
    static var schema: Schema { get }
}

extension VersionedSchema {
    /// A schema of `models` at `versionIdentifier`.
    public static var schema: Schema { Schema(models, version: versionIdentifier) }
}

/// Declares the ordered schemas and transitions used to migrate a model container.
public protocol SchemaMigrationPlan: Sendable {
    /// The available schema versions in migration order.
    static var schemas: [any VersionedSchema.Type] { get }
    /// The transitions connecting adjacent schemas.
    static var stages: [MigrationStage] { get }
}

/// Describes one migration transition between two versioned schemas.
public enum MigrationStage: @unchecked Sendable {
    /// Applies the supported schema changes without custom callbacks.
    case lightweight(fromVersion: any VersionedSchema.Type, toVersion: any VersionedSchema.Type)
    /// Runs context callbacks around the schema change.
    ///
    /// `willMigrate` runs transactionally with a context using the source schema before the change, and
    /// `didMigrate` with a context using the destination schema after it. Structural changes still use the
    /// lightweight engine; unsupported table-layout changes fail closed.
    case custom(
        fromVersion: any VersionedSchema.Type,
        toVersion: any VersionedSchema.Type,
        willMigrate: (@Sendable (_ context: ModelContext) throws -> Void)? = nil,
        didMigrate: (@Sendable (_ context: ModelContext) throws -> Void)? = nil
    )

    /// How a stage applies its schema change.
    enum Strategy {
        case lightweight
        case custom
    }

    var sourceVersion: Schema.Version {
        switch self {
        case .lightweight(let from, _), .custom(let from, _, _, _): from.versionIdentifier
        }
    }

    var destinationVersion: Schema.Version {
        switch self {
        case .lightweight(_, let to), .custom(_, let to, _, _): to.versionIdentifier
        }
    }

    var strategy: Strategy {
        if case .custom = self { return .custom }
        return .lightweight
    }

    var willMigrate: (@Sendable (ModelContext) throws -> Void)? {
        if case .custom(_, _, let willMigrate, _) = self { return willMigrate }
        return nil
    }

    var didMigrate: (@Sendable (ModelContext) throws -> Void)? {
        if case .custom(_, _, _, let didMigrate) = self { return didMigrate }
        return nil
    }
}

struct MigrationPlanDescriptor: @unchecked Sendable {
    let schemas: [(version: Schema.Version, schema: Schema, models: [any PersistentModel.Type])]
    let stages: [MigrationStage]

    init(_ plan: any SchemaMigrationPlan.Type) throws {
        schemas = plan.schemas.map { versioned in
            (version: versioned.versionIdentifier, schema: versioned.schema, models: versioned.models)
        }
        stages = plan.stages
        try validate()
    }

    private func validate() throws {
        guard !schemas.isEmpty, stages.count == schemas.count - 1 else {
            throw SwiftDataError.migrationUnsupported("Migration plans must connect every ordered schema version.")
        }
        var identifiers: Set<String> = []
        for schema in schemas {
            guard schema.schema.declaredVersion == schema.version else {
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
