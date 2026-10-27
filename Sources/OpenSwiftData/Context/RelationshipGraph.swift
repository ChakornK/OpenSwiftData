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
    /// Builds a relationship value from endpoints of the statically known destination type.
    func makeValue(_ endpoints: [any PersistentModel]) throws -> Any
    /// Builds a typed inverse value from endpoints.
    func makeInverseValue(_ endpoints: [any PersistentModel]) throws -> Any
    /// Returns a relationship's endpoint values from a supplied model value.
    func endpoints(in value: Any) throws -> [any PersistentModel]
    /// Assigns a relationship value without dispatching through the property setter.
    func assign(_ value: Any, to model: Model) throws
    /// Routes a generated property write through the context relationship graph.
    func mutate(_ value: Any, on model: Model, using mutation: (Model, Any, Any) throws -> Void) throws
}

public extension RelationshipPropertyAdapter {
    /// Writes a typed relationship value and reports old and new values synchronously.
    func write(_ value: Any, to model: Model) throws {
        _ = (value, model)
        throw SwiftDataError.unsupportedSchemaProperty("This relationship adapter does not implement writes.")
    }

    func makeValue(_ endpoints: [any PersistentModel]) throws -> Any {
        _ = endpoints
        throw SwiftDataError.unsupportedSchemaProperty("This relationship adapter cannot build values.")
    }
    func makeInverseValue(_ endpoints: [any PersistentModel]) throws -> Any { try makeValue(endpoints) }
    func endpoints(in value: Any) throws -> [any PersistentModel] {
        _ = value
        throw SwiftDataError.unsupportedSchemaProperty("This relationship adapter cannot inspect values.")
    }
    func assign(_ value: Any, to model: Model) throws {
        try write(value, to: model)
    }
    func mutate(_ value: Any, on model: Model, using mutation: (Model, Any, Any) throws -> Void) throws {
        _ = (value, model, mutation)
        throw SwiftDataError.unsupportedSchemaProperty("This relationship adapter cannot dispatch property writes.")
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
    private let buildValue: ([Destination]) throws -> Value
    private let buildInverseValue: ([Destination]) throws -> Value

    /// Creates a statically typed relationship adapter.
    public init(
        _ name: String,
        keyPath: KeyPath<Owner, Value>,
        metadata: Schema.Relationship? = nil,
        read: @escaping (Owner) -> Value,
        endpoints: @escaping (Value) -> [Destination],
        build: @escaping ([Destination]) throws -> Value,
        inverseBuild: (([Destination]) throws -> Value)? = nil,
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
        buildValue = build
        buildInverseValue = inverseBuild ?? build
        assignValue = { owner, value in
            owner.persistentBackingData.withMutation {
                owner.persistentBackingData.setValue(forKey: keyPath, to: value)
            }
        }
    }

    /// Creates a legacy adapter that can read and write only through its existing property value.
    public init(
        _ name: String,
        keyPath: KeyPath<Owner, Value>,
        metadata: Schema.Relationship? = nil,
        read: @escaping (Owner) -> Value,
        endpoints: @escaping (Value) -> [Destination],
        isToMany: Bool = true,
        explicitInverseKeyPath: AnyKeyPath? = nil
    ) {
        self.init(
            name,
            keyPath: keyPath,
            metadata: metadata,
            read: read,
            endpoints: endpoints,
            build: { _ in
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Legacy relationship adapter '\(name)' cannot build a value from endpoints.")
            },
            isToMany: isToMany,
            explicitInverseKeyPath: explicitInverseKeyPath)
    }

    /// Creates a copy carrying the resolved schema relationship metadata.
    public func resolved(with relationship: Schema.Relationship) -> any RelationshipPropertyAdapter<Owner> {
        let copy = Self(
            name, keyPath: typedKeyPath, metadata: relationship, read: readOwnerValue, endpoints: endpointValues,
            build: buildValue, inverseBuild: buildInverseValue,
            isToMany: relationship.isToMany, explicitInverseKeyPath: explicitInverseKeyPath)
        return copy
    }

    private var typedKeyPath: KeyPath<Owner, Value> { storedKeyPath }
    private let storedKeyPath: KeyPath<Owner, Value>

    /// Reads the current related endpoint values.
    public func read(_ model: Owner) -> [any PersistentModel] { readValue(model) }

    /// Builds a typed value from compatible destination models.
    public func makeValue(_ endpoints: [any PersistentModel]) throws -> Any {
        let typedEndpoints = try endpoints.map { endpoint -> Destination in
            guard let endpoint = endpoint as? Destination else {
                throw SwiftDataError.relationshipValueTypeMismatch(
                    property: name,
                    expected: String(reflecting: Destination.self),
                    actual: String(reflecting: type(of: endpoint)))
            }
            return endpoint
        }
        return try buildValue(typedEndpoints)
    }

    /// Builds a typed inverse value from compatible destination models.
    public func makeInverseValue(_ endpoints: [any PersistentModel]) throws -> Any {
        let typedEndpoints = try endpoints.map { endpoint -> Destination in
            guard let endpoint = endpoint as? Destination else {
                throw SwiftDataError.relationshipValueTypeMismatch(
                    property: name, expected: String(reflecting: Destination.self),
                    actual: String(reflecting: type(of: endpoint)))
            }
            return endpoint
        }
        return try buildInverseValue(typedEndpoints)
    }

    /// Reads endpoints from a relationship value after validating its type.
    public func endpoints(in value: Any) throws -> [any PersistentModel] {
        guard let typedValue = value as? Value else {
            throw SwiftDataError.relationshipValueTypeMismatch(
                property: name, expected: String(reflecting: Value.self), actual: String(reflecting: type(of: value)))
        }
        return readValue(from: typedValue)
    }

    private func readValue(from value: Value) -> [any PersistentModel] {
        endpointValues(value).map { $0 as any PersistentModel }
    }

    /// Validates and assigns a typed relationship value, then journals its endpoint change.
    public func write(_ value: Any, to model: Owner) throws {
        guard metadata != nil else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(name)' is not bound to resolved schema metadata.")
        }
        guard let typedValue = value as? Value else {
            throw SwiftDataError.relationshipValueTypeMismatch(
                property: name,
                expected: String(reflecting: Value.self),
                actual: String(reflecting: Swift.type(of: value)))
        }
        if let context = model.persistentBackingData.modelContext {
            guard let metadata else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Relationship adapter '\(name)' is not bound to resolved schema metadata.")
            }
            try context.state.mutateRelationship(
                owner: model, adapter: RelationshipAdapterBox(self, resolved: metadata), value: typedValue)
        } else {
            model.persistentBackingData.withMutation {
                assignValue(model, typedValue)
            }
        }
    }

    /// Assigns a validated relationship value without dispatching through its setter.
    public func assign(_ value: Any, to model: Owner) throws {
        guard let typedValue = value as? Value else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(name)' received an incompatible owner or value.")
        }
        assignValue(model, typedValue)
    }

    /// Routes a generated property write through the context relationship graph.
    public func mutate(
        _ value: Any,
        on model: Owner,
        using mutation: (Owner, Any, Any) throws -> Void
    ) throws {
        guard let typedValue = value as? Value else {
            throw SwiftDataError.relationshipValueTypeMismatch(
                property: name, expected: String(reflecting: Value.self), actual: String(reflecting: type(of: value)))
        }
        try mutation(model, self, typedValue)
    }

}
