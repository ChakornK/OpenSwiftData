import Foundation

/// A stable identifier for a persisted or not-yet-persisted model.
public struct PersistentIdentifier: Hashable, Codable, Sendable {
    /// The identity of the store containing this model.
    public let storeIdentifier: String
    /// The model entity name.
    public let entityName: String
    /// The permanent primary key, or `nil` while the identifier is temporary.
    public let primaryKey: Int64?
    /// The temporary UUID, or `nil` after the identifier becomes permanent.
    public let temporaryIdentifier: UUID?

    /// Creates a temporary identifier for a model in a store.
    public init(storeIdentifier: String, entityName: String, temporaryIdentifier: UUID) {
        self.storeIdentifier = storeIdentifier
        self.entityName = entityName
        self.primaryKey = nil
        self.temporaryIdentifier = temporaryIdentifier
    }

    /// Creates a permanent identifier for a model in a store.
    public init(storeIdentifier: String, entityName: String, primaryKey: Int64) {
        self.storeIdentifier = storeIdentifier
        self.entityName = entityName
        self.primaryKey = primaryKey
        self.temporaryIdentifier = nil
    }

    /// Whether this identifier refers to a model that has not yet been saved.
    public var isTemporary: Bool {
        temporaryIdentifier != nil
    }

    private enum CodingKeys: String, CodingKey {
        case storeIdentifier
        case entityName
        case kind
        case payload
    }

    private enum PayloadKeys: String, CodingKey {
        case primaryKey
        case temporaryIdentifier
    }

    private enum ValueKeys: String, CodingKey {
        case value
    }

    private enum IdentifierKind: String, Codable {
        case primaryKey
        case temporary
    }

    /// Decodes an identifier from its tagged representation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storeIdentifier = try container.decode(String.self, forKey: .storeIdentifier)
        let entityName = try container.decode(String.self, forKey: .entityName)
        let kind = try container.decode(IdentifierKind.self, forKey: .kind)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)

        self.storeIdentifier = storeIdentifier
        self.entityName = entityName

        switch kind {
        case .primaryKey:
            let primaryKey = try payload.nestedContainer(keyedBy: ValueKeys.self, forKey: .primaryKey)
            self.primaryKey = try primaryKey.decode(Int64.self, forKey: .value)
            self.temporaryIdentifier = nil
        case .temporary:
            let temporaryIdentifier = try payload.nestedContainer(keyedBy: ValueKeys.self, forKey: .temporaryIdentifier)
            self.primaryKey = nil
            self.temporaryIdentifier = try temporaryIdentifier.decode(UUID.self, forKey: .value)
        }
    }

    /// Encodes the identifier using a stable kind and payload representation.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storeIdentifier, forKey: .storeIdentifier)
        try container.encode(entityName, forKey: .entityName)

        if let primaryKey {
            try container.encode(IdentifierKind.primaryKey, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            var primaryKeyPayload = payload.nestedContainer(keyedBy: ValueKeys.self, forKey: .primaryKey)
            try primaryKeyPayload.encode(primaryKey, forKey: .value)
        } else if let temporaryIdentifier {
            try container.encode(IdentifierKind.temporary, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            var temporaryIdentifierPayload = payload.nestedContainer(
                keyedBy: ValueKeys.self,
                forKey: .temporaryIdentifier
            )
            try temporaryIdentifierPayload.encode(temporaryIdentifier, forKey: .value)
        } else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "A persistent identifier must have exactly one identifier form."
                )
            )
        }
    }
}
