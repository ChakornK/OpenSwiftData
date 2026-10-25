import OSDCore

/// Encodes and decodes one statically known model property.
public protocol PersistencePropertyAdapter<Model> {
    associatedtype Model: PersistentModel
    /// The persisted property name.
    var name: String { get }
    /// The key path used to identify this adapter.
    var keyPath: AnyKeyPath { get }
    /// Encodes the property's current value.
    func encode(_ model: Model) throws -> StoredValue
    /// Decodes a stored value into the model's property.
    func decode(_ value: StoredValue, into model: Model) throws
    /// Type-erased encoding entry point.
    func encoded(_ model: Model) throws -> StoredValue
    /// Type-erased decoding entry point.
    func decoded(_ value: StoredValue) throws -> Any
    /// Assigns a decoded value through persistent backing storage.
}

/// A typed adapter generated for a persisted property.
public struct TypedPropertyAdapter<Model: PersistentModel, Value>: PersistencePropertyAdapter {
    /// The persisted property name.
    public let name: String
    /// The statically known property key path.
    public let keyPath: AnyKeyPath
    private let readValue: (Model) throws -> StoredValue
    private let writeValue: (StoredValue, Model) throws -> Void
    private let decodeValue: (StoredValue) throws -> Any

    /// Creates a typed property adapter from generated closures.
    public init(
        _ name: String,
        keyPath: AnyKeyPath,
        encode: @escaping (Model) throws -> StoredValue,
        decode: @escaping (StoredValue, Model) throws -> Void,
        decodeValue: @escaping (StoredValue) throws -> Any
    ) {
        self.name = name
        self.keyPath = keyPath
        readValue = encode
        writeValue = decode
        self.decodeValue = decodeValue
    }

    /// Encodes the property's current value.
    public func encode(_ model: Model) throws -> StoredValue { try readValue(model) }
    /// Decodes a value into the property's concrete storage.
    public func decode(_ value: StoredValue, into model: Model) throws { try writeValue(value, model) }
    /// Encodes through the erased adapter interface.
    public func encoded(_ model: Model) throws -> StoredValue { try encode(model) }
    /// Decodes through the erased adapter interface.
    public func decoded(_ value: StoredValue) throws -> Any { try decodeValue(value) }
}
