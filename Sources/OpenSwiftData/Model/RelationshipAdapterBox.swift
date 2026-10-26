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
    /// Reads endpoints when the supplied owner has the expected type.
    func read(_ owner: AnyObject) -> [any PersistentModel]?
    /// Writes a value after validating the supplied owner's type.
    func write(_ value: Any, to owner: AnyObject) throws
    /// Returns a box carrying resolved schema relationship metadata.
    func resolved(with relationship: Schema.Relationship) -> any AnyRelationshipAdapterBox
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

    /// Creates an unresolved box retaining the typed adapter.
    public init(_ candidate: any RelationshipPropertyAdapter<Owner>) {
        self.candidate = candidate
        resolvedMetadata = nil
    }

    /// Creates a box with resolved schema metadata.
    public init(_ candidate: any RelationshipPropertyAdapter<Owner>, resolved relationship: Schema.Relationship) {
        self.candidate = candidate.resolved(with: relationship)
        resolvedMetadata = relationship
    }

    /// Returns a new box with the supplied resolved relationship.
    public func resolved(with relationship: Schema.Relationship) -> any AnyRelationshipAdapterBox {
        RelationshipAdapterBox(candidate, resolved: relationship)
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
}
