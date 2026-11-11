import Foundation

/// Apple's relationship-collection protocol, reimplemented as a stub for
/// API-surface coverage. OpenSwiftData represents to-many relationships as
/// Swift arrays and does not expose a `RelationshipCollection` protocol.
public protocol RelationshipCollection {
    /// The element type stored by the relationship collection.
    associatedtype PersistentElement: PersistentModel
}
