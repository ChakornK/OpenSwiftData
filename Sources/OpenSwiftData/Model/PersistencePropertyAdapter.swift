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

/// Type-erased encoder and decoder for one persisted model property.
public protocol AnyPersistencePropertyAdapter {
    /// The persisted property name.
    var name: String { get }
    /// The key path used to identify this property.
    var keyPath: AnyKeyPath { get }
    /// Encodes a model instance when its runtime type matches the adapter.
    func encoded(_ model: any PersistentModel) throws -> StoredValue
    /// Decodes a value into a model instance when its runtime type matches the adapter.
    func decode(_ value: StoredValue, into model: any PersistentModel) throws
    /// Decodes a stored value without a model instance.
    func decoded(_ value: StoredValue) throws -> Any
}

/// Adapts an existing typed property adapter to heterogeneous model registrations.
public struct ErasedPersistencePropertyAdapter<Model: PersistentModel>: AnyPersistencePropertyAdapter {
    private let adapter: any PersistencePropertyAdapter<Model>

    /// Creates an erased adapter around a typed property adapter.
    public init(_ adapter: any PersistencePropertyAdapter<Model>) {
        self.adapter = adapter
    }

    /// The persisted property name.
    public var name: String { adapter.name }
    /// The key path used to identify this property.
    public var keyPath: AnyKeyPath { adapter.keyPath }

    /// Encodes a model instance whose runtime type matches the wrapped adapter.
    public func encoded(_ model: any PersistentModel) throws -> StoredValue {
        guard let model = model as? Model else {
            throw SwiftDataError.unsupportedStore("Persistence adapter model type mismatch for '\(name)'.")
        }
        return try adapter.encoded(model)
    }

    /// Decodes a stored value into a model instance whose runtime type matches the wrapped adapter.
    public func decode(_ value: StoredValue, into model: any PersistentModel) throws {
        guard let model = model as? Model else {
            throw SwiftDataError.unsupportedStore("Persistence adapter model type mismatch for '\(name)'.")
        }
        try adapter.decode(value, into: model)
    }

    /// Decodes a stored value without requiring a model instance.
    public func decoded(_ value: StoredValue) throws -> Any { try adapter.decoded(value) }
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
