import Observation

/// A scalar leaf declared by a flattened Codable composite.
public struct FlattenedComponent<Composite> {
    /// The component's stable logical name.
    public let name: String
    /// The scalar type name used by the schema.
    public let columnType: String
    /// The key path to the scalar leaf within the composite.
    public let keyPath: AnyKeyPath
    private let encodeBody: (Composite) throws -> StoredValue
    private let decodeBody: (StoredValue, Composite) throws -> Composite

    /// Creates a component with typed scalar access and reconstruction behavior.
    public init<Value: Codable & Sendable>(
        _ name: String,
        keyPath: KeyPath<Composite, Value>,
        set: @escaping (Value, Composite) throws -> Composite
    ) {
        self.name = name
        columnType = String(reflecting: Value.self)
        self.keyPath = keyPath
        encodeBody = { try PersistentValue.encode($0[keyPath: keyPath]) }
        decodeBody = { value, composite in
            try set(PersistentValue.decode(Value.self, from: value), composite)
        }
    }

    /// Encodes the component value from a composite.
    public func encode(_ value: Composite) throws -> StoredValue { try encodeBody(value) }
    /// Decodes a stored scalar into an existing composite value.
    public func decode(_ value: StoredValue, into composite: Composite) throws -> Composite {
        try decodeBody(value, composite)
    }

    /// Composes the model property path with this component path when Swift can preserve the type relation.
    public func componentKeyPath<Model>(from parent: KeyPath<Model, Composite>) -> AnyKeyPath? {
        (parent as AnyKeyPath).appending(path: keyPath)
    }

    /// Creates a model adapter that maps this component to a physical column.
    public func modelAdapter<Model: PersistentModel>(
        propertyName: String,
        propertyKeyPath: KeyPath<Model, Composite>,
        componentKeyPath: AnyKeyPath? = nil,
        setComposite: @escaping (Composite, Model) -> Void
    ) -> FlattenedPropertyAdapter<Model, Composite> {
        FlattenedPropertyAdapter(
            propertyName: propertyName,
            propertyKeyPath: propertyKeyPath,
            componentKeyPath: componentKeyPath ?? self.componentKeyPath(from: propertyKeyPath) ?? keyPath,
            component: self,
            setComposite: setComposite)
    }
}

/// Supplies explicit scalar components for an opt-in flattened Codable value.
public protocol FlattenableComposite: Codable & Sendable, FlattenedCompositeMetadataProviding {
    /// Components in the value's declared schema order.
    static var flattenedComponents: [FlattenedComponent<Self>] { get }
    /// Creates an initial value before applying stored components.
    static func emptyFlattenedValue() throws -> Self
}

/// Provides a type-erased component manifest for schema construction.
public protocol FlattenedCompositeMetadataProviding {
    /// Component names and scalar types in schema order.
    static var flattenedComponentsForSchema: [(String, String)] { get }
}

public extension FlattenableComposite {
    static var flattenedComponentsForSchema: [(String, String)] {
        flattenedComponents.map { ($0.name, $0.columnType) }
    }
}

/// Type-erased component access attached to a model's top-level composite property.
public protocol AnyFlattenedPropertyAdapter {
    /// The model property that owns the composite.
    var propertyName: String { get }
    /// The SQL column storing this component.
    var columnName: String { get }
    /// The component's stable logical name.
    var componentName: String { get }
    /// The composed model key path to this component.
    var componentKeyPath: AnyKeyPath { get }
    /// The composite-local component key path.
    var localComponentKeyPath: AnyKeyPath { get }
    /// The model key path to the composite property.
    var propertyKeyPath: AnyKeyPath { get }
    /// The scalar type name used in the schema.
    var columnType: String { get }
    /// Creates an initial composite value for row materialization.
    func makeEmptyComposite() throws -> Any
    /// Encodes this component from a model instance.
    func encoded(_ model: Any) throws -> StoredValue
    /// Applies a stored scalar to an in-progress composite value.
    func decoded(_ value: StoredValue, into composite: Any) throws -> Any
    /// Assigns a completed composite to a model instance.
    func assign(_ composite: Any, to model: Any) throws
}

/// A typed adapter that persists one scalar component of a composite property.
public struct FlattenedPropertyAdapter<Model: PersistentModel, Composite: FlattenableComposite>:
    AnyFlattenedPropertyAdapter
{
    /// The model property that owns the composite.
    public let propertyName: String
    /// The physical SQL column name for the component.
    public let columnName: String
    /// The stable component name inside its composite.
    public let componentName: String
    /// The composed model key path to the component.
    public let componentKeyPath: AnyKeyPath
    /// The component-local key path.
    public let localComponentKeyPath: AnyKeyPath
    /// The key path to the composite property.
    public let propertyKeyPath: AnyKeyPath
    /// The scalar type name stored in the column.
    public let columnType: String
    private let component: FlattenedComponent<Composite>
    private let getComposite: (Model) -> Composite
    private let setComposite: (Composite, Model) -> Void

    /// Creates an adapter for one component of a flattened model property.
    public init(
        propertyName: String,
        propertyKeyPath: KeyPath<Model, Composite>,
        componentKeyPath: AnyKeyPath,
        component: FlattenedComponent<Composite>,
        setComposite: @escaping (Composite, Model) -> Void
    ) {
        self.propertyName = propertyName
        columnName = "\(propertyName)_\(component.name)"
        componentName = component.name
        self.componentKeyPath = componentKeyPath
        localComponentKeyPath = component.keyPath
        self.propertyKeyPath = propertyKeyPath
        columnType = component.columnType
        self.component = component
        getComposite = { $0[keyPath: propertyKeyPath] }
        self.setComposite = setComposite
    }

    /// Encodes this component from a model instance.
    public func encoded(_ model: Any) throws -> StoredValue {
        guard let model = model as? Model else {
            throw SwiftDataError.unsupportedSchemaProperty("Flattened adapter model mismatch")
        }
        do {
            return try component.encode(getComposite(model))
        } catch {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Encoding flattened component '\(propertyName).\(componentName)' failed: \(error)")
        }
    }

    /// Creates an initial composite value for row materialization.
    public func makeEmptyComposite() throws -> Any {
        try Composite.emptyFlattenedValue()
    }

    /// Applies a stored scalar to an in-progress composite value.
    public func decoded(_ value: StoredValue, into composite: Any) throws -> Any {
        guard let composite = composite as? Composite else {
            throw SwiftDataError.unsupportedSchemaProperty("Flattened composite value type mismatch")
        }
        do {
            return try component.decode(value, into: composite)
        } catch {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Decoding flattened component '\(propertyName).\(componentName)' failed: \(error)")
        }
    }

    /// Assigns a completed composite to a model instance.
    public func assign(_ composite: Any, to model: Any) throws {
        guard let composite = composite as? Composite, let model = model as? Model else {
            throw SwiftDataError.unsupportedSchemaProperty("Flattened composite assignment type mismatch")
        }
        setComposite(composite, model)
    }

}

/// A model whose properties are stored in OpenSwiftData backing data.
public protocol PersistentModel: AnyObject {
    associatedtype Model: PersistentModel = Self
    var persistentModelID: PersistentIdentifier { get }
    var modelContext: ModelContext? { get }
    var isDeleted: Bool { get }
    var hasChanges: Bool { get }
    var persistentBackingData: any BackingData<Self> { get set }
    init(backingData: any BackingData<Self>)
    static func schemaMetadata() -> [Schema.PropertyMetadata]
    static func schemaIndexes() -> [Schema.Index]
    static func createManagedBackingData(
        values: [AnyKeyPath: Any], context: ModelContext, storeIdentifier: String,
        entityID: Int, identifier: PersistentIdentifier
    ) -> any BackingData<Self>
    static func createBackingData() -> DetachedBackingData<Self>
    static func persistenceAdapters() -> [any PersistencePropertyAdapter<Self>]
    static func flattenedPropertyAdapters() -> [any AnyFlattenedPropertyAdapter]
    func getValue<Value>(forKey keyPath: KeyPath<Self, Value>) -> Value
    func setValue<Value>(forKey keyPath: KeyPath<Self, Value>, to value: Value)
}

public extension PersistentModel {
    static func schemaIndexes() -> [Schema.Index] { [] }
    static func createManagedBackingData(
        values: [AnyKeyPath: Any], context: ModelContext, storeIdentifier: String,
        entityID: Int, identifier: PersistentIdentifier
    ) -> any BackingData<Self> {
        ManagedBackingData<Self>(
            metadata: schemaMetadata(), values: values, context: context,
            storeIdentifier: storeIdentifier, entityID: entityID,
            identifier: identifier)
    }
    static func persistenceAdapters() -> [any PersistencePropertyAdapter<Self>] { [] }
    static func flattenedPropertyAdapters() -> [any AnyFlattenedPropertyAdapter] { [] }
    static func hasFlattenedKeyPath(_ keyPath: AnyKeyPath) -> Bool {
        flattenedPropertyAdapters().contains { $0.componentKeyPath == keyPath }
    }
    var persistentModelID: PersistentIdentifier { persistentBackingData.persistentModelID }
    var modelContext: ModelContext? { persistentBackingData.modelContext }
    var isDeleted: Bool { persistentBackingData.isDeleted }
    var hasChanges: Bool { persistentBackingData.hasChanges }
    func getValue<Value>(forKey keyPath: KeyPath<Self, Value>) -> Value {
        persistentBackingData.getValue(forKey: keyPath)
    }

    func setValue<Value>(forKey keyPath: KeyPath<Self, Value>, to value: Value) {
        persistentBackingData.withMutation {
            persistentBackingData.setValue(forKey: keyPath, to: value)
        }
    }

    static func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox] { [] }

    func setRelationshipValue<Value>(forKey keyPath: KeyPath<Self, Value>, to value: Value) {
        guard let context = persistentBackingData.modelContext else {
            guard let modelType = Self.self as? any RelationshipModel.Type,
                let adapter =
                    (modelType.relationshipAdapterCandidates() + modelType.inferredRelationshipAdapterCandidates())
                    .first(where: { $0.keyPath == keyPath })
            else {
                setValue(forKey: keyPath, to: value)
                return
            }
            do {
                let endpoints = try adapter.endpoints(in: value)
                let typedValue = try adapter.makeValue(endpoints)
                try adapter.assign(typedValue, to: self)
            } catch {
                return
            }
            return
        }
        if !context.state.setRelationship(model: self, keyPath: keyPath, value: value, autoInsertDestinations: true) {
            setValue(forKey: keyPath, to: value)
        }
    }

    func snapshotLifecycle() -> BackingDataSnapshot { persistentBackingData.snapshot() }
    func setInsertionChanged() { persistentBackingData.restoreInsertionState() }
    func markPersistedLifecycle(storeIdentifier: String, entityID: Int, primaryKey: Int64, version: Int) {
        persistentBackingData.markPersisted(
            storeIdentifier: storeIdentifier, entityID: entityID, primaryKey: primaryKey, version: version)
    }
    func markSavedLifecycle() { persistentBackingData.markSaved() }
    func restoreLifecycle(_ snapshot: BackingDataSnapshot) { persistentBackingData.restore(snapshot) }
    func restoreValuesLifecycle(_ snapshot: BackingDataSnapshot) { persistentBackingData.restoreValues(snapshot) }
    func restoreValuesAndDetachLifecycle(_ snapshot: BackingDataSnapshot) {
        persistentBackingData.restoreValuesAndDetach(snapshot)
    }
    func detachLifecycle() { persistentBackingData.detach() }
    func detachDeletedLifecycle() { persistentBackingData.detachDeleted() }
}
