import Foundation
import OSDCore

/// Supplies typed relationship reads and mutation notifications for a model property.
public protocol RelationshipPropertyAdapter<Model> {
    associatedtype Model: PersistentModel
    /// The relationship property name.
    var name: String { get }
    /// The statically known relationship property key path.
    var keyPath: AnyKeyPath { get }
    /// The statically known destination model type.
    var destinationType: any PersistentModel.Type { get }
    /// Whether the property is a collection relationship.
    var isToMany: Bool { get }
    /// The key path to an explicitly declared inverse, when present.
    var explicitInverseKeyPath: AnyKeyPath? { get }
    /// Establishes the schema-resolved relationship metadata.
    func resolved(with relationship: Schema.Relationship) -> any RelationshipPropertyAdapter<Model>
    /// Reads the current related endpoint values.
    func read(_ model: Model) -> [any PersistentModel]
    /// Writes a typed relationship value and reports old and new values synchronously.
    func write(_ value: Any, to model: Model) throws
}

public extension RelationshipPropertyAdapter {
    /// Writes a typed relationship value and reports old and new values synchronously.
    func write(_ value: Any, to model: Model) throws {
        _ = (value, model)
        throw SwiftDataError.unsupportedSchemaProperty("This relationship adapter does not implement writes.")
    }
}

/// A generated typed adapter for one optional or collection relationship property.
public struct TypedRelationshipPropertyAdapter<Owner: PersistentModel, Value, Destination: PersistentModel>:
    RelationshipPropertyAdapter
{
    /// The relationship property name.
    public let name: String
    /// The statically known relationship property key path.
    public let keyPath: AnyKeyPath
    /// The statically known destination model type.
    public var destinationType: any PersistentModel.Type { Destination.self }
    /// Whether the property is a collection relationship.
    public let isToMany: Bool
    /// The key path to an explicitly declared inverse, when present.
    public let explicitInverseKeyPath: AnyKeyPath?
    /// The schema metadata for this relationship, when specified.
    public let metadata: Schema.Relationship?
    private let readValue: (Owner) -> [any PersistentModel]
    private let readOwnerValue: (Owner) -> Value
    private let endpointValues: (Value) -> [Destination]
    private let assignValue: (Owner, Value) -> Void

    /// Creates a statically typed relationship adapter.
    public init(
        _ name: String,
        keyPath: KeyPath<Owner, Value>,
        metadata: Schema.Relationship? = nil,
        read: @escaping (Owner) -> Value,
        endpoints: @escaping (Value) -> [Destination],
        isToMany: Bool = true,
        explicitInverseKeyPath: AnyKeyPath? = nil
    ) {
        self.name = name
        self.keyPath = keyPath
        storedKeyPath = keyPath
        self.metadata = metadata
        self.isToMany = isToMany
        self.explicitInverseKeyPath = explicitInverseKeyPath
        self.readOwnerValue = read
        readValue = { owner in endpoints(read(owner)).map { $0 as any PersistentModel } }
        endpointValues = endpoints
        assignValue = { owner, value in owner.setValue(forKey: keyPath, to: value) }
    }

    /// Creates a copy carrying the resolved schema relationship metadata.
    public func resolved(with relationship: Schema.Relationship) -> any RelationshipPropertyAdapter<Owner> {
        Self(
            name, keyPath: typedKeyPath, metadata: relationship, read: readOwnerValue, endpoints: endpointValues,
            isToMany: relationship.isToMany, explicitInverseKeyPath: explicitInverseKeyPath)
    }

    private var typedKeyPath: KeyPath<Owner, Value> { storedKeyPath }
    private let storedKeyPath: KeyPath<Owner, Value>

    /// Reads the current related endpoint values.
    public func read(_ model: Owner) -> [any PersistentModel] { readValue(model) }

    /// Validates and assigns a typed relationship value, then journals its endpoint change.
    public func write(_ value: Any, to model: Owner) throws {
        guard let metadata else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(name)' is not bound to resolved schema metadata.")
        }
        guard let typedValue = value as? Value else {
            throw SwiftDataError.relationshipValueTypeMismatch(
                property: name,
                expected: String(reflecting: Value.self),
                actual: String(reflecting: Swift.type(of: value)))
        }
        let oldEndpoints = readValue(model)
        let newEndpoints = endpointValues(typedValue).map { $0 as any PersistentModel }
        if let context = model.persistentBackingData.modelContext {
            _ = context.state.mutate(model, snapshot: { model.snapshotLifecycle() }) {
                context.state.recordRelationshipMutation(
                    owner: model, property: name, relationship: metadata, oldValues: oldEndpoints,
                    newValues: newEndpoints)
                assignValue(model, typedValue)
            }
        } else {
            model.persistentBackingData.withMutation {
                assignValue(model, typedValue)
            }
        }
    }
}
