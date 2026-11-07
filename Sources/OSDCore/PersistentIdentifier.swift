import Foundation

/// A stable identifier for a persisted or not-yet-persisted model.
///
/// Identifiers compare equal when they name the same store, entity, and key. Ordering is total and
/// consistent with equality but otherwise unspecified.
public struct PersistentIdentifier: Hashable, Identifiable, Comparable, Codable, Sendable {
    /// An opaque value that uniquely identifies a persistent identifier.
    public struct ID: Hashable, Sendable {
        fileprivate let key: Key
        fileprivate let store: String
        fileprivate let entityName: String
    }

    fileprivate enum Key: Hashable, Sendable {
        case row(Int64)
        case temporary(UUID)
        case custom(typeName: String, description: String, encoded: Data)
    }

    /// The opaque identity of this identifier.
    public var id: ID { ID(key: key, store: identityStore, entityName: entityName) }

    /// The store component of identity; temporary identifiers are unique without one.
    private var identityStore: String { isTemporary ? "" : resolvedStoreIdentifier }

    /// Returns whether both identifiers name the same model; temporary identifiers ignore the store.
    public static func == (lhs: PersistentIdentifier, rhs: PersistentIdentifier) -> Bool {
        lhs.id == rhs.id
    }

    /// Hashes the same components that equality compares.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// The store that holds the model, or `nil` while the identifier is temporary.
    public var storeIdentifier: String? { isTemporary ? nil : resolvedStoreIdentifier }

    /// The store an identifier belongs to, including temporary identifiers of inserted models.
    package let resolvedStoreIdentifier: String
    /// The model entity name.
    public let entityName: String
    private let key: Key

    /// The permanent row primary key, or `nil` for temporary and developer-provided identifiers.
    public var primaryKey: Int64? {
        if case .row(let value) = key { return value }
        return nil
    }

    /// The temporary UUID, or `nil` after the identifier becomes permanent.
    public var temporaryIdentifier: UUID? {
        if case .temporary(let value) = key { return value }
        return nil
    }

    /// Creates a temporary identifier for a model in a store.
    public init(storeIdentifier: String, entityName: String, temporaryIdentifier: UUID) {
        self.resolvedStoreIdentifier = storeIdentifier
        self.entityName = entityName
        self.key = .temporary(temporaryIdentifier)
    }

    /// Creates a permanent identifier for a model in a store.
    public init(storeIdentifier: String, entityName: String, primaryKey: Int64) {
        self.resolvedStoreIdentifier = storeIdentifier
        self.entityName = entityName
        self.key = .row(primaryKey)
    }

    private init(storeIdentifier: String, entityName: String, key: Key) {
        self.resolvedStoreIdentifier = storeIdentifier
        self.entityName = entityName
        self.key = key
    }

    /// Creates a permanent identifier with a developer-provided primary key, for use by custom data stores.
    ///
    /// Identifiers made from equal store identifiers, entity names, and keys of the same type are equal.
    public static func identifier<T>(
        for storeIdentifier: String, entityName: String, primaryKey: T
    ) throws -> PersistentIdentifier where T: Codable & Comparable & CustomStringConvertible & Hashable {
        let encoded = try JSONEncoder().encode(primaryKey)
        return PersistentIdentifier(
            storeIdentifier: storeIdentifier, entityName: entityName,
            key: .custom(
                typeName: String(reflecting: T.self), description: primaryKey.description, encoded: encoded))
    }

    /// Whether this identifier refers to a model that has not yet been saved.
    public var isTemporary: Bool {
        if case .temporary = key { return true }
        return false
    }

    /// The developer-provided primary key decoded as `T`, or `nil` when the key has another form or type.
    package func developerPrimaryKey<T: Decodable>(as type: T.Type) -> T? {
        guard case .custom(let typeName, _, let encoded) = key, typeName == String(reflecting: T.self) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: encoded)
    }

    /// Orders identifiers by store, entity, key form, and key value.
    public static func < (lhs: PersistentIdentifier, rhs: PersistentIdentifier) -> Bool {
        if lhs.identityStore != rhs.identityStore { return lhs.identityStore < rhs.identityStore }
        if lhs.entityName != rhs.entityName { return lhs.entityName < rhs.entityName }
        switch (lhs.key, rhs.key) {
        case (.row(let left), .row(let right)): return left < right
        case (.temporary(let left), .temporary(let right)): return left.uuidString < right.uuidString
        case (.custom(let leftType, let left, let leftData), .custom(let rightType, let right, let rightData)):
            if leftType != rightType { return leftType < rightType }
            if left != right { return left < right }
            return leftData.lexicographicallyPrecedes(rightData)
        default: return lhs.key.rank < rhs.key.rank
        }
    }

    /// Encodes the complete identifier as deterministic bytes for pending predicate comparison.
    package func predicateIdentityBytes() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Array(try encoder.encode(self))
    }

    private var primaryKeyString: String {
        switch key {
        case .row(let value): "p\(value)"
        case .temporary(let value): value.uuidString
        case .custom(_, let description, _): description
        }
    }

    private var uriRepresentation: String {
        switch key {
        case .row: "x-coredata://\(resolvedStoreIdentifier)/\(entityName)/\(primaryKeyString)"
        case .temporary: "x-swiftdata://\(entityName)/\(primaryKeyString)"
        case .custom: "developer-provided://\(resolvedStoreIdentifier)/\(entityName)/\(primaryKeyString)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case implementation
    }

    private enum ImplementationKeys: String, CodingKey {
        case entityName, isTemporary, primaryKey, storeIdentifier, typedPrimaryKey, uriRepresentation, typeName
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case storeIdentifier, entityName, kind, payload
    }

    private enum LegacyPayloadKeys: String, CodingKey {
        case primaryKey, temporaryIdentifier
    }

    private enum LegacyValueKeys: String, CodingKey {
        case value
    }

    /// Decodes an identifier from SwiftData's `implementation` representation or the legacy tagged form.
    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        guard root.contains(.implementation) else {
            try self.init(legacyFrom: decoder)
            return
        }
        let container = try root.nestedContainer(keyedBy: ImplementationKeys.self, forKey: .implementation)
        let entityName = try container.decode(String.self, forKey: .entityName)
        let primaryKey = try container.decode(String.self, forKey: .primaryKey)
        let storeIdentifier = try container.decodeIfPresent(String.self, forKey: .storeIdentifier)
        let key: Key
        if try container.decode(Bool.self, forKey: .isTemporary) {
            guard let uuid = UUID(uuidString: primaryKey) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .primaryKey, in: container, debugDescription: "A temporary primary key must be a UUID.")
            }
            key = .temporary(uuid)
        } else if container.contains(.typedPrimaryKey) {
            let typed = try container.superDecoder(forKey: .typedPrimaryKey)
            let typeName = try container.decodeIfPresent(String.self, forKey: .typeName)
            key = .custom(
                typeName: typeName ?? String(reflecting: String.self), description: primaryKey,
                encoded: try Self.reencodedTypedKey(from: typed))
        } else if primaryKey.first == "p", let row = Int64(primaryKey.dropFirst()) {
            key = .row(row)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .primaryKey, in: container, debugDescription: "Unrecognized primary key '\(primaryKey)'.")
        }
        self.init(storeIdentifier: storeIdentifier ?? "", entityName: entityName, key: key)
    }

    /// Re-encodes a decoded typed key as JSON so equality does not depend on the outer coder.
    private static func reencodedTypedKey(from decoder: Decoder) throws -> Data {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { return try JSONEncoder().encode(string) }
        if let integer = try? value.decode(Int.self) { return try JSONEncoder().encode(integer) }
        if let double = try? value.decode(Double.self) { return try JSONEncoder().encode(double) }
        if let uuid = try? value.decode(UUID.self) { return try JSONEncoder().encode(uuid) }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Unsupported developer-provided primary key."))
    }

    private init(legacyFrom decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let storeIdentifier = try container.decode(String.self, forKey: .storeIdentifier)
        let entityName = try container.decode(String.self, forKey: .entityName)
        let kind = try container.decode(String.self, forKey: .kind)
        let payload = try container.nestedContainer(keyedBy: LegacyPayloadKeys.self, forKey: .payload)
        switch kind {
        case "primaryKey":
            let value = try payload.nestedContainer(keyedBy: LegacyValueKeys.self, forKey: .primaryKey)
            self.init(
                storeIdentifier: storeIdentifier, entityName: entityName,
                key: .row(try value.decode(Int64.self, forKey: .value)))
        case "temporary":
            let value = try payload.nestedContainer(keyedBy: LegacyValueKeys.self, forKey: .temporaryIdentifier)
            self.init(
                storeIdentifier: storeIdentifier, entityName: entityName,
                key: .temporary(try value.decode(UUID.self, forKey: .value)))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown identifier kind '\(kind)'.")
        }
    }

    /// Encodes the identifier in SwiftData's `implementation` representation.
    ///
    /// Temporary identifiers omit the store identifier. Developer-provided keys also carry
    /// `typedPrimaryKey` and the key's type name.
    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        var container = root.nestedContainer(keyedBy: ImplementationKeys.self, forKey: .implementation)
        try container.encode(entityName, forKey: .entityName)
        try container.encode(isTemporary, forKey: .isTemporary)
        try container.encode(primaryKeyString, forKey: .primaryKey)
        if !isTemporary { try container.encode(resolvedStoreIdentifier, forKey: .storeIdentifier) }
        if case .custom(let typeName, _, let encoded) = key {
            let decoder = JSONDecoder()
            if let string = try? decoder.decode(String.self, from: encoded) {
                try container.encode(string, forKey: .typedPrimaryKey)
            } else if let integer = try? decoder.decode(Int64.self, from: encoded) {
                try container.encode(integer, forKey: .typedPrimaryKey)
            } else if let double = try? decoder.decode(Double.self, from: encoded) {
                try container.encode(double, forKey: .typedPrimaryKey)
            } else {
                try container.encode(primaryKeyString, forKey: .typedPrimaryKey)
            }
            try container.encode(typeName, forKey: .typeName)
        }
        try container.encode(uriRepresentation, forKey: .uriRepresentation)
    }
}

extension PersistentIdentifier.Key {
    fileprivate var rank: Int {
        switch self {
        case .row: 0
        case .temporary: 1
        case .custom: 2
        }
    }
}
