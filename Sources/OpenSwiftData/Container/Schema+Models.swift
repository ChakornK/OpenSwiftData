import OSDCore

extension Schema {
    /// Creates a schema describing the given model types and their ancestors.
    ///
    /// Entities appear in name order. Invalid model declarations produce an empty entity list here and
    /// throw when a container opens with this schema.
    public init(_ types: [any PersistentModel.Type], version: Version? = nil) {
        do {
            self = try ModelContainer.inferredSchema(for: types, version: version)
        } catch {
            self.init([Entity](), version: version)
            modelTypes = ModelTypes(types: types, inferenceError: error)
        }
    }

    /// Creates a schema describing the given model types and their ancestors.
    public init(_ types: any PersistentModel.Type..., version: Version? = nil) {
        self.init(types, version: version)
    }

    /// Creates an empty schema.
    public init() {
        self.init([Entity](), version: nil)
    }

    /// Creates a schema from a versioned schema's models and version identifier.
    public init(versionedSchema: any VersionedSchema.Type) {
        self.init(versionedSchema.models, version: versionedSchema.versionIdentifier)
    }

    /// Returns the entity name for a model type.
    public static func entityName<T: PersistentModel>(for type: T.Type) -> String {
        String(describing: type).split(separator: ".").last.map(String.init) ?? String(describing: type)
    }

    /// Returns the entity describing a model type, if the schema contains it.
    public func entity<T: PersistentModel>(for type: T.Type) -> Entity? {
        entity(forName: Self.entityName(for: type))
    }
}
