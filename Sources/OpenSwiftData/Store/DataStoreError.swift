import Foundation

/// Apple's custom-store error enum, reimplemented as a stub for API-surface
/// coverage. OpenSwiftData's custom-store shape surfaces errors via
/// ``SwiftDataError`` instead; this enum exists so the parity API surface
/// covers Apple's `DataStoreError` symbol.
public enum DataStoreError: Error, Equatable, Sendable {
    /// The predicate is not supported by the store.
    case invalidPredicate
    /// The store prefers the consumer filter the result set in memory.
    case preferInMemoryFilter
    /// The store prefers the consumer sort the result set in memory.
    case preferInMemorySort
    /// The feature is not supported by the store.
    case unsupportedFeature
}
