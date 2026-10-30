import Foundation
import OSDCore

/// A type-erased relationship adapter bound to one owner model type.
public protocol AnyRelationshipAdapterBox: Sendable {
    /// The runtime identity of the owning model type.
    var ownerType: ObjectIdentifier { get }
    /// The relationship property name.
    var name: String { get }
    /// The relationship property key path.
    var keyPath: AnyKeyPath { get }
    /// The destination model type.
    var destinationType: any PersistentModel.Type { get }
    /// Whether the relationship contains multiple destinations.
    var isToMany: Bool { get }
    /// The explicitly declared inverse key path, when present.
    var explicitInverseKeyPath: AnyKeyPath? { get }
    /// The resolved schema relationship metadata, when available.
    var metadata: Schema.Relationship? { get }
    /// Mutates the relationship through its resolved graph when the key path matches.
    func mutate(
        _ value: Any,
        on owner: AnyObject,
        keyPath: AnyKeyPath,
        using mutation: (AnyObject, AnyRelationshipAdapterBox, Any) throws -> Void
    ) -> Bool

    /// Reads endpoints when the supplied owner has the expected type.
    func read(_ owner: AnyObject) -> [any PersistentModel]?
    /// Writes a value after validating the supplied owner's type.
    func write(_ value: Any, to owner: AnyObject) throws
    /// Builds a typed relationship value containing the supplied endpoints.
    func makeValue(_ endpoints: [any PersistentModel]) throws -> Any
    /// Builds a typed inverse relationship value.
    func makeInverseValue(_ endpoints: [any PersistentModel]) throws -> Any
    /// Reads endpoints from a supplied relationship value.
    func endpoints(in value: Any) throws -> [any PersistentModel]
    /// Assigns a typed relationship value without dispatching through a model property setter.
    func assign(_ value: Any, to owner: AnyObject) throws
    /// Returns a box carrying resolved schema relationship metadata.
    func resolved(with relationship: Schema.Relationship) -> any AnyRelationshipAdapterBox
}

public extension AnyRelationshipAdapterBox {
    func mutate(
        _ value: Any,
        on owner: AnyObject,
        keyPath: AnyKeyPath,
        using mutation: (AnyObject, AnyRelationshipAdapterBox, Any) throws -> Void
    ) -> Bool {
        _ = (value, owner, keyPath, mutation)
        return false
    }
}

/// Retains a typed relationship adapter while exposing checked owner-erased operations.
public struct RelationshipAdapterBox<Owner: PersistentModel>: AnyRelationshipAdapterBox, @unchecked Sendable {
    private let candidate: any RelationshipPropertyAdapter<Owner>
    private let resolvedMetadata: Schema.Relationship?

    /// The runtime identity of the owning model type.
    public var ownerType: ObjectIdentifier { ObjectIdentifier(Owner.self) }
    /// The relationship property name.
    public var name: String { candidate.name }
    /// The relationship property key path.
    public var keyPath: AnyKeyPath { candidate.keyPath }
    /// The destination model type.
    public var destinationType: any PersistentModel.Type { candidate.destinationType }
    /// Whether the relationship contains multiple destinations.
    public var isToMany: Bool { candidate.isToMany }
    /// The explicitly declared inverse key path, when present.
    public var explicitInverseKeyPath: AnyKeyPath? { candidate.explicitInverseKeyPath }
    /// The resolved schema relationship metadata, when available.
    public var metadata: Schema.Relationship? { resolvedMetadata }

    /// Mutates the relationship through its resolved graph when the key path matches.
    public func mutate(
        _ value: Any,
        on owner: AnyObject,
        keyPath: AnyKeyPath,
        using mutation: (AnyObject, AnyRelationshipAdapterBox, Any) throws -> Void
    ) -> Bool {
        guard keyPath == candidate.keyPath, let typedOwner = owner as? Owner else { return false }
        do {
            try candidate.mutate(value, on: typedOwner) { model, _, typedValue in
                try mutation(model, self, typedValue)
            }
        } catch {
            return true
        }
        return true
    }

    /// Creates an unresolved box retaining the typed adapter.
    public init(_ candidate: any RelationshipPropertyAdapter<Owner>) {
        self.candidate = candidate
        resolvedMetadata = nil
    }

    /// Creates a box with resolved schema metadata.
    public init(_ candidate: any RelationshipPropertyAdapter<Owner>, resolved relationship: Schema.Relationship) {
        self.candidate = candidate
        resolvedMetadata = relationship
    }

    /// Returns a new box with the supplied resolved relationship.
    public func resolved(with relationship: Schema.Relationship) -> any AnyRelationshipAdapterBox {
        let resolvedCandidate = candidate.resolved(with: relationship)
        return RelationshipAdapterBox(resolvedCandidate, resolved: relationship)
    }

    /// Reads relationship endpoints after validating the owner type.
    public func read(_ owner: AnyObject) -> [any PersistentModel]? {
        guard let owner = owner as? Owner else { return nil }
        return candidate.read(owner)
    }

    /// Writes a relationship value after validating the owner type.
    public func write(_ value: Any, to owner: AnyObject) throws {
        guard let owner = owner as? Owner else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(name)' cannot operate on owner type '\(String(reflecting: type(of: owner)))'.")
        }
        try candidate.write(value, to: owner)
    }

    /// Builds a typed relationship value after validating every endpoint type.
    public func makeValue(_ endpoints: [any PersistentModel]) throws -> Any {
        try candidate.makeValue(endpoints)
    }

    /// Builds a typed inverse relationship value.
    public func makeInverseValue(_ endpoints: [any PersistentModel]) throws -> Any {
        try candidate.makeInverseValue(endpoints)
    }

    /// Reads endpoints from a relationship value after validating its type.
    public func endpoints(in value: Any) throws -> [any PersistentModel] {
        try candidate.endpoints(in: value)
    }

    /// Assigns a typed relationship value without dispatching through a model property setter.
    public func assign(_ value: Any, to owner: AnyObject) throws {
        guard let owner = owner as? Owner else {
            throw SwiftDataError.unsupportedSchemaProperty(
                "Relationship adapter '\(name)' received an incompatible owner.")
        }
        try candidate.assign(value, to: owner)
    }
}

struct ReownedRelationshipAdapterBox: AnyRelationshipAdapterBox, @unchecked Sendable {
    private let adapter: any AnyRelationshipAdapterBox
    let ownerType: ObjectIdentifier

    init(_ adapter: any AnyRelationshipAdapterBox, ownerType: ObjectIdentifier) {
        self.adapter = adapter
        self.ownerType = ownerType
    }

    var name: String { adapter.name }
    var keyPath: AnyKeyPath { adapter.keyPath }
    var destinationType: any PersistentModel.Type { adapter.destinationType }
    var isToMany: Bool { adapter.isToMany }
    var explicitInverseKeyPath: AnyKeyPath? { adapter.explicitInverseKeyPath }
    var metadata: Schema.Relationship? { adapter.metadata }

    func mutate(
        _ value: Any,
        on owner: AnyObject,
        keyPath: AnyKeyPath,
        using mutation: (AnyObject, AnyRelationshipAdapterBox, Any) throws -> Void
    ) -> Bool {
        adapter.mutate(value, on: owner, keyPath: keyPath, using: mutation)
    }

    func read(_ owner: AnyObject) -> [any PersistentModel]? { adapter.read(owner) }
    func write(_ value: Any, to owner: AnyObject) throws { try adapter.write(value, to: owner) }
    func makeValue(_ endpoints: [any PersistentModel]) throws -> Any { try adapter.makeValue(endpoints) }
    func makeInverseValue(_ endpoints: [any PersistentModel]) throws -> Any { try adapter.makeInverseValue(endpoints) }
    func endpoints(in value: Any) throws -> [any PersistentModel] { try adapter.endpoints(in: value) }
    func assign(_ value: Any, to owner: AnyObject) throws { try adapter.assign(value, to: owner) }
    func resolved(with relationship: Schema.Relationship) -> any AnyRelationshipAdapterBox {
        ReownedRelationshipAdapterBox(adapter.resolved(with: relationship), ownerType: ownerType)
    }
}
