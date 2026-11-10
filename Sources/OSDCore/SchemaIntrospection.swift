/// A persisted property of a schema entity: an attribute or a relationship.
///
/// Mirrors the inspection surface of SwiftData's `SchemaProperty`. Unlike SwiftData, the original
/// name stays optional and value types are described by name, because OpenSwiftData's schema values
/// also describe stored layouts.
public protocol SchemaProperty: Hashable {
    /// The property name.
    var name: String { get }
    /// Whether the property is an attribute.
    var isAttribute: Bool { get }
    /// Whether the property is a relationship.
    var isRelationship: Bool { get }
    /// Whether the property is transient. Persisted schema properties never are.
    var isTransient: Bool { get }
    /// Whether the property can hold `nil` (or, for to-many relationships, be empty).
    var isOptional: Bool { get }
    /// Whether the property's value must be unique across the entity's instances.
    var isUnique: Bool { get }
}

extension SchemaProperty {
    /// Persisted schema properties are never transient.
    public var isTransient: Bool { false }
}

extension SchemaDescriptor.Attribute: SchemaProperty {
    /// Always `true`.
    public var isAttribute: Bool { true }
    /// Always `false`.
    public var isRelationship: Bool { false }
    /// Whether the attribute carries the `.unique` option.
    public var isUnique: Bool { options.contains(.unique) }
    /// Whether the attribute is stored through a value transformer.
    public var isTransformable: Bool {
        options.contains { if case .transformable = $0 { true } else { false } }
    }
}

extension SchemaDescriptor.Relationship: SchemaProperty {
    /// Always `false`.
    public var isAttribute: Bool { false }
    /// Always `true`.
    public var isRelationship: Bool { true }
    /// Whether the relationship carries the `.unique` option.
    public var isUnique: Bool { options.contains(.unique) }
    /// Whether the relationship holds at most one destination.
    public var isToOneRelationship: Bool { !isToMany }
    /// The inverse relationship's name, if known.
    public var inverseName: String? { inverse }
}

extension SchemaDescriptor.Entity {
    /// The entity's attributes and relationships, including inherited ones, in declaration order.
    public var properties: [any SchemaProperty] { attributes + relationships }
    /// The entity's attributes keyed by name.
    public var attributesByName: [String: SchemaDescriptor.Attribute] {
        Dictionary(attributes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// The entity's relationships keyed by name.
    public var relationshipsByName: [String: SchemaDescriptor.Relationship] {
        Dictionary(relationships.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// The property names of each uniqueness constraint, including single `.unique` attributes.
    public var uniquenessConstraints: [[String]] {
        // `.unique` attributes are also recorded as single-property unique indexes.
        let indexed = indexes.filter(\.isUnique).map(\.properties)
        return attributes.filter { $0.isUnique && !indexed.contains([$0.name]) }.map { [$0.name] } + indexed
    }
    /// The property names of each non-unique index.
    public var indices: [[String]] { indexes.filter { !$0.isUnique }.map(\.properties) }
}
