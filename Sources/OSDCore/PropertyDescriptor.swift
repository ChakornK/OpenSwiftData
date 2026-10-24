import Foundation

/// Describes a persisted model property and its storage behavior.
package struct PropertyDescriptor {
    package let slot: Int
    package let name: String
    package let keyPath: AnyKeyPath
    package let kind: Kind
    package let codec: Any.Type
    package let options: [String]

    /// The storage category of a property.
    package enum Kind {
        case attribute
        case relationship
    }
}
