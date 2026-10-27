import OSDCore

/// A persistent model that provides statically typed relationship candidate adapters.
public protocol RelationshipModel: PersistentModel {
    /// Returns candidates for explicitly declared relationships.
    static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox]
    /// Returns candidates for relationships inferred from model property types.
    static func inferredRelationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox]
    static func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox]
}

public extension RelationshipModel {
    /// Returns candidates for explicitly declared relationships.
    static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] { [] }
    /// Returns candidates for relationships inferred from model property types.
    static func inferredRelationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] { [] }
    static func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox] {
        relationshipAdapterCandidates() + inferredRelationshipAdapterCandidates()
    }
}
