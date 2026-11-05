/// Defines query traversal limits shared by the context and storage layers.
package enum OSDQueryLimits {
    /// Maximum nesting depth for to-many collection predicates.
    package static let maximumNestedCollectionPredicateDepth = 5
}
