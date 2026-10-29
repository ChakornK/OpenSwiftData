import Foundation
import OSDCore

package enum PredicateNodeCatalog {
    package typealias Entry = PredicateNodeMetadata.Entry
    package static var entries: [String: Entry] { PredicateNodeMetadata.entries }

    package static func entry(for typeName: String) -> Entry? {
        PredicateNodeMetadata.entry(for: typeName)
    }
}

package enum PredicateCatalogError: Error, Equatable {
    case unsupportedNode(String)
    case malformedNode(String, missingChildren: [String])
}
