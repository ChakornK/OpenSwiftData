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

extension TypedPropertyAdapter {
    /// Creates an adapter for a property whose type the `@Model` macro can't classify syntactically.
    ///
    /// The macro emits this for property types that might be models or Codable values. It returns
    /// `nil` when `Value` isn't Codable, or when it is a model (possibly wrapped in an `Optional`,
    /// `Array`, or `Set`), because those properties are persisted as relationships.
    public static func codableIfPossible(
        _ name: String, keyPath: AnyKeyPath, get: @escaping (Model) -> Value, set: @escaping (Model, Value) -> Void
    ) -> Self? {
        guard Value.self is any Codable.Type, !containsModelType(Value.self) else { return nil }
        let decodeValue: (StoredValue) throws -> Any = { value in
            // `Value` was checked to be Codable above, so these casts can't fail.
            let decodable = Value.self as! any Decodable.Type
            return try decodeOpened(decodable, from: value)
        }
        return Self(
            name, keyPath: keyPath,
            encode: { model in
                let encodable = get(model) as! any Encodable
                return try encodeOpened(encodable)
            },
            decode: { value, model in set(model, try decodeValue(value) as! Value) },
            decodeValue: decodeValue)
    }
}

private protocol ModelValueWrapper {
    static var wrappedValueType: Any.Type { get }
}

extension Optional: ModelValueWrapper {
    fileprivate static var wrappedValueType: Any.Type { Wrapped.self }
}

extension Array: ModelValueWrapper {
    fileprivate static var wrappedValueType: Any.Type { Element.self }
}

extension Set: ModelValueWrapper {
    fileprivate static var wrappedValueType: Any.Type { Element.self }
}

private func containsModelType(_ type: Any.Type) -> Bool {
    if type is any PersistentModel.Type { return true }
    guard let wrapper = type as? any ModelValueWrapper.Type else { return false }
    return containsModelType(wrapper.wrappedValueType)
}

private func encodeOpened<T: Encodable>(_ value: T) throws -> StoredValue {
    try PersistentValue.encode(value)
}

private func decodeOpened<T: Decodable>(_ type: T.Type, from value: StoredValue) throws -> Any {
    try PersistentValue.decode(type, from: value)
}
