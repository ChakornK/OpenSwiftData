import Foundation

/// Describes a persisted model property and its storage behavior.
public struct PropertyDescriptor: @unchecked Sendable {
    /// The stable declaration-order index used by generated model accessors.
    public let slot: Int
    /// The persisted model property name.
    public let name: String
    /// The statically known model property key path.
    public let keyPath: AnyKeyPath
    /// Whether the property stores an attribute or relationship.
    public let kind: Kind
    /// The declared value type used by the property's codec.
    public let codec: Any.Type
    /// The declared persistence option names.
    public let options: [String]

    /// Creates a property descriptor with its generated slot and storage metadata.
    public init(slot: Int, name: String, keyPath: AnyKeyPath, kind: Kind, codec: Any.Type, options: [String]) {
        self.slot = slot
        self.name = name
        self.keyPath = keyPath
        self.kind = kind
        self.codec = codec
        self.options = options
    }

    /// The storage category of a property.
    public enum Kind {
        case attribute
        case relationship
    }
}
