import Observation

/// A scalar leaf declared by a flattened Codable composite.
public struct FlattenedComponent<Composite> {
    /// The component's stable logical name.
    public let name: String
    /// The scalar type name used by the schema.
    public let columnType: String
    /// The leaf's runtime Swift metatype.
    public let valueType: Any.Type
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
        valueType = Value.self
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
    /// Runtime component types in the same order as `flattenedComponents`.
    static var flattenedComponentTypesForSchema: [(String, Any.Type)] { get }
}

/// Provides a type-erased component manifest for schema construction.
public protocol FlattenedCompositeMetadataProviding {
    /// Component names and scalar types in schema order.
    static var flattenedComponentsForSchema: [(String, String)] { get }
    /// Component names and runtime scalar types in schema order.
    static var flattenedComponentTypesForSchema: [(String, Any.Type)] { get }
}

public extension FlattenedCompositeMetadataProviding {
    static var flattenedComponentTypesForSchema: [(String, Any.Type)] { [] }
}

public extension FlattenableComposite {
    static var flattenedComponentsForSchema: [(String, String)] {
        flattenedComponents.map { ($0.name, $0.columnType) }
    }

    static var flattenedComponentTypesForSchema: [(String, Any.Type)] {
        flattenedComponents.map { ($0.name, $0.valueType) }
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

public extension AnyFlattenedPropertyAdapter {
    /// Encodes this component from a persistent model.
    func encoded(_ model: any PersistentModel) throws -> StoredValue { try encoded(model as Any) }
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
public protocol PersistentModel: AnyObject, Observable, Hashable, Identifiable {
    associatedtype Model: PersistentModel = Self
    /// Type-erased backing used by subclass properties whose key paths are rooted at a derived model type.
    var anyBackingData: any AnyBackingData { get }
    /// The parent model in an inheritance hierarchy, when present.
    static var parentModel: (any PersistentModel.Type)? { get }
    /// Persists subclass-initialized values after its inherited backing is available.
    func prepareForPersistence()
    var persistentModelID: PersistentIdentifier { get }
    var modelContext: ModelContext? { get }
    var isDeleted: Bool { get }
    var hasChanges: Bool { get }
    var persistentBackingData: any BackingData<Model> { get set }
    init(backingData: any BackingData<Model>)
    static func schemaMetadata() -> [SchemaDescriptor.PropertyMetadata]
    /// Returns the persisted property name associated with a model-rooted key path.
    static func propertyName(forKeyPath keyPath: AnyKeyPath) -> String?
    /// Returns property descriptors keyed by paths rooted at this model's dynamic class.
    static func propertyDescriptorsByKeyPath() -> [AnyKeyPath: PropertyDescriptor]
    static func schemaIndexes() -> [SchemaDescriptor.Index]
    /// The generated, declaration-ordered property descriptor table.
    static var propertyDescriptors: [PropertyDescriptor] { get }
    /// Returns the slot associated with a property key path, if one exists.
    static func propertySlot(forKeyPath keyPath: AnyKeyPath) -> Int?
    static func createManagedBackingData(
        values: [AnyKeyPath: Any], context: ModelContext, storeIdentifier: String,
        entityID: Int, identifier: PersistentIdentifier
    ) -> any BackingData<Model>
    static func createBackingData() -> DetachedBackingData<Model>
    static func persistenceAdapters() -> [any PersistencePropertyAdapter<Model>]
    /// Returns persistence adapters that can operate on heterogeneous runtime model instances.
    static func erasedPersistenceAdapters() -> [any AnyPersistencePropertyAdapter]
    static func flattenedPropertyAdapters() -> [any AnyFlattenedPropertyAdapter]
    func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value
    func getValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>) -> Value
    func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value)
    func setValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>, to value: Value)
    func getInheritedValue<Value>(at slot: Int, keyPath: AnyKeyPath, property: String, as type: Value.Type) -> Value
    func setInheritedValue<Value>(at slot: Int, keyPath: AnyKeyPath, to value: Value)
    func getInheritedValue<Value>(keyPath: AnyKeyPath, property: String, as type: Value.Type) -> Value
    func setInheritedValue<Value>(keyPath: AnyKeyPath, to value: Value)
}

public extension PersistentModel {
    /// The model's persistent identifier.
    var id: PersistentIdentifier { persistentModelID }

    /// Returns whether both operands are the same model instance.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs === rhs }

    /// Hashes the model's current persistent identifier.
    ///
    /// The hash changes when saving replaces a temporary identifier with a permanent one, and instances
    /// of the same row in different contexts hash equally while comparing unequal.
    func hash(into hasher: inout Hasher) { hasher.combine(persistentModelID) }

    // An explicit witness avoids a synthesized one that fails to link for non-final model classes.
    var hashValue: Int { persistentModelID.hashValue }

    static var parentModel: (any PersistentModel.Type)? { nil }
    func prepareForPersistence() {}
    var anyBackingData: any AnyBackingData {
        if let backing = persistentBackingData as? any AnyBackingData { return backing }
        return persistentBackingData.erasedBackingData()
    }
    static func schemaIndexes() -> [SchemaDescriptor.Index] { [] }
    static func propertyName(forKeyPath keyPath: AnyKeyPath) -> String? {
        propertyDescriptorsByKeyPath()[keyPath]?.name
            ?? schemaMetadata().first(where: { $0.keypath == keyPath })?.name
    }
    static func propertyDescriptorsByKeyPath() -> [AnyKeyPath: PropertyDescriptor] {
        Dictionary(uniqueKeysWithValues: propertyDescriptors.map { ($0.keyPath, $0) })
    }
    static var propertyDescriptors: [PropertyDescriptor] { [] }
    static func propertySlot(forKeyPath keyPath: AnyKeyPath) -> Int? {
        propertyDescriptorsByKeyPath()[keyPath]?.slot
            ?? propertyDescriptors.first(where: { $0.keyPath == keyPath })?.slot
    }
    static func createManagedBackingData(
        values: [AnyKeyPath: Any], context: ModelContext, storeIdentifier: String,
        entityID: Int, identifier: PersistentIdentifier
    ) -> any BackingData<Model> {
        ManagedBackingData<Model>(
            metadata: schemaMetadata(), values: values, context: context,
            storeIdentifier: storeIdentifier, entityID: entityID,
            identifier: identifier)
    }
    static func persistenceAdapters() -> [any PersistencePropertyAdapter<Model>] { [] }
    static func erasedPersistenceAdapters() -> [any AnyPersistencePropertyAdapter] {
        persistenceAdapters().map { ErasedPersistencePropertyAdapter($0) }
    }
    static func flattenedPropertyAdapters() -> [any AnyFlattenedPropertyAdapter] { [] }
    static func hasFlattenedKeyPath(_ keyPath: AnyKeyPath) -> Bool {
        flattenedPropertyAdapters().contains { $0.componentKeyPath == keyPath }
    }
    var persistentModelID: PersistentIdentifier { persistentBackingData.persistentModelID }
    var modelContext: ModelContext? { persistentBackingData.modelContext }
    var isDeleted: Bool { persistentBackingData.isDeleted }
    var hasChanges: Bool { persistentBackingData.hasChanges }
    func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value {
        if let slot = Model.propertySlot(forKeyPath: keyPath) {
            return persistentBackingData.getValue(at: slot, forKey: keyPath)
        }
        return persistentBackingData.getValue(forKey: keyPath)
    }

    func getValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>) -> Value {
        persistentBackingData.getValue(at: slot, forKey: keyPath)
    }

    func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        persistentBackingData.withMutation {
            if let slot = Model.propertySlot(forKeyPath: keyPath) {
                persistentBackingData.setValue(at: slot, forKey: keyPath, to: value)
            } else {
                persistentBackingData.setValue(forKey: keyPath, to: value)
            }
        }
    }

    func setValue<Value>(at slot: Int, forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        persistentBackingData.withMutation {
            persistentBackingData.setValue(at: slot, forKey: keyPath, to: value)
        }
    }

    func getInheritedValue<Value>(
        at slot: Int, keyPath: AnyKeyPath, property: String, as valueType: Value.Type
    ) -> Value {
        if let value = anyBackingData.getValue(at: slot, keyPath: keyPath, as: valueType) { return value }
        if let optional = Value.self as? any _OptionalType.Type, let nilValue = optional.nilValue as? Value {
            return nilValue
        }
        fatalError("OSD: property '\(property)' of \(type(of: self)) was read before assignment")
    }

    func getInheritedValue<Value>(
        keyPath: AnyKeyPath, property: String, as valueType: Value.Type
    ) -> Value {
        getInheritedValue(
            at: Model.propertySlot(forKeyPath: keyPath) ?? -1,
            keyPath: keyPath,
            property: property,
            as: valueType)
    }

    func setInheritedValue<Value>(at slot: Int, keyPath: AnyKeyPath, to value: Value) {
        let backing = anyBackingData
        guard backing.supportsSubclassKeyPaths else {
            OSDLog.debug("Subclass property mutation requires a backing that supports subclass key paths")
            return
        }
        backing.withMutation {
            _ = backing.setValue(at: slot, keyPath: keyPath, to: value)
        }
    }

    func setInheritedValue<Value>(keyPath: AnyKeyPath, to value: Value) {
        setInheritedValue(at: Model.propertySlot(forKeyPath: keyPath) ?? -1, keyPath: keyPath, to: value)
    }

    func setInheritedRelationshipValue<Value>(forKey keyPath: AnyKeyPath, to value: Value) {
        guard let context = modelContext else {
            setInheritedValue(at: Model.propertySlot(forKeyPath: keyPath) ?? -1, keyPath: keyPath, to: value)
            return
        }
        context.registerUndoIfNeeded(self, snapshot: snapshotLifecycle())
        if !context.state.setRelationship(
            model: self, keyPath: keyPath, value: value, autoInsertDestinations: true)
        {
            setInheritedValue(at: Model.propertySlot(forKeyPath: keyPath) ?? -1, keyPath: keyPath, to: value)
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
                let backing = anyBackingData
                backing.withMutation {
                    _ = backing.setValue(
                        at: Model.propertySlot(forKeyPath: keyPath) ?? -1,
                        keyPath: keyPath,
                        to: value)
                }
                return
            }
            do {
                let endpoints = try adapter.endpoints(in: value)
                // Relating a detached model to a managed one inserts it into the managed model's context.
                if let managedContext = endpoints.lazy.compactMap(\.modelContext).first {
                    managedContext.insert(self)
                    setRelationshipValue(forKey: keyPath, to: value)
                    return
                }
                try DetachedRelationshipGraph.assign(
                    endpoints: endpoints, owner: self, ownerType: modelType, adapter: adapter)
            } catch {
                return
            }
            return
        }
        context.registerUndoIfNeeded(self, snapshot: snapshotLifecycle())
        if !context.state.setRelationship(
            model: self, keyPath: keyPath, value: value, autoInsertDestinations: true)
        {
            let backing = anyBackingData
            backing.withMutation {
                _ = backing.setValue(
                    at: Model.propertySlot(forKeyPath: keyPath) ?? -1,
                    keyPath: keyPath,
                    to: value)
            }
        }
    }

    func snapshotLifecycle() -> BackingDataSnapshot { persistentBackingData.snapshot() }
    func setInsertionChanged() { persistentBackingData.restoreInsertionState() }
    func markPersistedLifecycle(
        storeIdentifier: String, displayedStoreIdentifier: String, entityName: String? = nil,
        entityID: Int, primaryKey: Int64, version: Int
    ) {
        persistentBackingData.markPersisted(
            storeIdentifier: storeIdentifier, displayedStoreIdentifier: displayedStoreIdentifier,
            entityID: entityID, primaryKey: primaryKey, version: version)
        if let entityName { anyBackingData.setConcreteEntityName(entityName) }
    }
    func markSavedLifecycle() { persistentBackingData.markSaved() }
    func restoreLifecycle(_ snapshot: BackingDataSnapshot) { persistentBackingData.restore(snapshot) }
    func attachBackingData(to context: ModelContext) {
        anyBackingData.attach(to: context, model: self)
    }
    func restoreValuesLifecycle(_ snapshot: BackingDataSnapshot) { persistentBackingData.restoreValues(snapshot) }
    func restoreValuesAndDetachLifecycle(_ snapshot: BackingDataSnapshot) {
        persistentBackingData.restoreValuesAndDetach(snapshot)
    }
    func detachLifecycle() { persistentBackingData.detach() }
    func detachDeletedLifecycle() { persistentBackingData.detachDeleted() }
}

private enum DetachedRelationshipGraph {
    private struct Plan {
        let owner: any PersistentModel
        let adapter: any AnyRelationshipAdapterBox
        let original: [any PersistentModel]
        var endpoints: [any PersistentModel]
        let initialValue: Any?
    }

    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let property: String
    }

    static func assign(
        endpoints: [any PersistentModel],
        owner: any PersistentModel,
        ownerType: any RelationshipModel.Type,
        adapter: any AnyRelationshipAdapterBox
    ) throws {
        let endpoints = unique(endpoints)
        let typedValue = try adapter.makeValue(endpoints)
        guard endpoints.allSatisfy({ $0.modelContext == nil }) else {
            try adapter.assign(typedValue, to: owner)
            return
        }

        let sourceHasValue = owner.anyBackingData.hasValue(forKeyPath: adapter.keyPath)
        let original = sourceHasValue ? unique(adapter.read(owner) ?? []) : []
        let declaredRelationship =
            ownerType.schemaMetadata()
            .first(where: { $0.name == adapter.name })?.metadata?.base as? SchemaDescriptor.Relationship
        let explicitInverseName = adapter.explicitInverseKeyPath.flatMap { inverseKeyPath in
            (original + endpoints).compactMap { endpoint in
                type(of: endpoint).schemaMetadata().first(where: { $0.keypath == inverseKeyPath })?.name
            }.first
        }
        let inverseName =
            adapter.metadata?.inverse
            ?? declaredRelationship?.inverse
            ?? explicitInverseName
            ?? inferredInverseName(for: adapter, owner: owner, relatedModels: original + endpoints)
        guard let inverseName else {
            try adapter.assign(typedValue, to: owner)
            return
        }
        guard (original + endpoints).allSatisfy({ $0.modelContext == nil }) else {
            try adapter.assign(typedValue, to: owner)
            return
        }

        var plans: [Key: Plan] = [:]
        var order: [Key] = []
        let ownerKey = Key(owner: ObjectIdentifier(owner), property: adapter.name)
        plans[ownerKey] = Plan(
            owner: owner, adapter: adapter, original: original, endpoints: endpoints, initialValue: typedValue)
        order.append(ownerKey)

        let removed = original.filter { old in !endpoints.contains(where: { $0 === old }) }
        let added = endpoints.filter { new in !original.contains(where: { $0 === new }) }
        for endpoint in added + removed where endpoint.modelContext == nil {
            guard let inverse = relationshipAdapter(on: endpoint, named: inverseName)
            else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Detached relationship inverse '\(inverseName)' has no unique typed adapter.")
            }
            let inverseCurrent = readEndpoints(of: inverse, on: endpoint)
            let inverseKey = Key(owner: ObjectIdentifier(endpoint), property: inverseName)
            var inversePlan =
                plans[inverseKey]
                ?? Plan(
                    owner: endpoint, adapter: inverse, original: unique(inverseCurrent),
                    endpoints: unique(inverseCurrent), initialValue: nil)
            if removed.contains(where: { $0 === endpoint }) {
                inversePlan.endpoints.removeAll { $0 === owner }
            } else if inverse.isToMany {
                if !inversePlan.endpoints.contains(where: { $0 === owner }) { inversePlan.endpoints.append(owner) }
            } else {
                for displaced in inversePlan.endpoints where displaced !== owner {
                    guard displaced.modelContext == nil,
                        let displacedAdapter = relationshipAdapter(on: displaced, named: adapter.name)
                    else {
                        throw SwiftDataError.unsupportedSchemaProperty(
                            "Detached inverse displacement requires detached relationship endpoints.")
                    }
                    let displacedKey = Key(owner: ObjectIdentifier(displaced), property: adapter.name)
                    var displacedPlan =
                        plans[displacedKey]
                        ?? Plan(
                            owner: displaced, adapter: displacedAdapter,
                            original: readEndpoints(of: displacedAdapter, on: displaced),
                            endpoints: readEndpoints(of: displacedAdapter, on: displaced), initialValue: nil)
                    displacedPlan.endpoints.removeAll { $0 === endpoint }
                    if plans[displacedKey] == nil { order.append(displacedKey) }
                    plans[displacedKey] = displacedPlan
                }
                inversePlan.endpoints = [owner]
            }
            if plans[inverseKey] == nil { order.append(inverseKey) }
            plans[inverseKey] = inversePlan
        }

        try apply(plans, order: order)
    }

    private static func relationshipAdapter(
        on owner: any PersistentModel, named property: String
    ) -> (any AnyRelationshipAdapterBox)? {
        guard let relationshipModel = type(of: owner) as? any RelationshipModel.Type else { return nil }
        let matches = relationshipModel.relationshipAdapterCandidatesForMutation().filter {
            $0.name == property
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func unique(_ endpoints: [any PersistentModel]) -> [any PersistentModel] {
        var result: [any PersistentModel] = []
        for endpoint in endpoints where !result.contains(where: { $0 === endpoint }) {
            result.append(endpoint)
        }
        return result
    }

    private static func readEndpoints(
        of adapter: any AnyRelationshipAdapterBox, on owner: any PersistentModel
    ) -> [any PersistentModel] {
        guard owner.anyBackingData.hasValue(forKeyPath: adapter.keyPath) else { return [] }
        return unique(adapter.read(owner) ?? [])
    }

    private static func inferredInverseName(
        for adapter: any AnyRelationshipAdapterBox,
        owner: any PersistentModel,
        relatedModels: [any PersistentModel]
    ) -> String? {
        guard !relatedModels.isEmpty else { return nil }
        var inverseNames = Set<String>()
        for model in relatedModels {
            let matches = type(of: model).schemaMetadata().compactMap { metadata -> String? in
                guard let relationship = metadata.metadata?.base as? SchemaDescriptor.Relationship,
                    relationship.inverse == adapter.name
                else { return nil }
                return metadata.name
            }
            guard matches.count == 1, let name = matches.first else { return nil }
            let reciprocalAdapters =
                (type(of: model) as? any RelationshipModel.Type)?
                .relationshipAdapterCandidatesForMutation().filter {
                    $0.name == name && $0.destinationType == type(of: owner)
                } ?? []
            guard reciprocalAdapters.count == 1 else { return nil }
            inverseNames.insert(name)
        }
        return inverseNames.count == 1 ? inverseNames.first : nil
    }

    private static func apply(_ plans: [Key: Plan], order: [Key]) throws {
        let models = order.compactMap { plans[$0]?.owner }
        var snapshots: [ObjectIdentifier: (any PersistentModel, BackingDataSnapshot)] = [:]
        for model in models {
            let identifier = ObjectIdentifier(model)
            if snapshots[identifier] == nil { snapshots[identifier] = (model, model.snapshotLifecycle()) }
        }
        do {
            for key in order {
                guard let plan = plans[key] else { continue }
                let value: Any
                if let initialValue = plan.initialValue {
                    value = initialValue
                } else {
                    value = try plan.adapter.makeInverseValue(plan.endpoints)
                }
                try plan.adapter.assign(value, to: plan.owner)
            }
        } catch {
            for (model, snapshot) in snapshots.values { model.restoreLifecycle(snapshot) }
            throw error
        }
    }
}

public extension PersistentModel {
    /// Apple's transformable-value accessor, stubbed to delegate to ``getValue(forKey:)``.
    func getTransformableValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value {
        getValue(forKey: keyPath)
    }

    /// Apple's transformable-value mutator, stubbed to delegate to ``setValue(forKey:to:)``.
    func setTransformableValue<Value>(forKey keyPath: KeyPath<Model, Value>, to newValue: Value) {
        setValue(forKey: keyPath, to: newValue)
    }
}
