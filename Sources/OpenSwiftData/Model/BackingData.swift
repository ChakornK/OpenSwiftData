import Foundation

/// Stores the values and lifecycle state backing a persistent model.
public protocol BackingData<Model>: AnyObject {
    /// The concrete model type stored by this backing data.
    associatedtype Model: AnyObject
    /// The model's persistent identifier.
    var persistentModelID: PersistentIdentifier { get }
    /// The context managing the model, if any.
    var modelContext: ModelContext? { get }
    /// Whether the model has been deleted.
    var isDeleted: Bool { get }
    /// Whether the model has unsaved changes.
    var hasChanges: Bool { get }
    /// Reads a property value from backing storage.
    func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value
    /// Writes a property value to backing storage.
    func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value)
}

/// Creates and owns the initial values for a model that is not in a context.
public final class DetachedBackingData<Model: AnyObject>: BackingData, @unchecked Sendable {
    private var values: [AnyKeyPath: Any] = [:]
    private let lock = NSLock()
    private let identifier: PersistentIdentifier
    private let metadata: [Schema.PropertyMetadata]

    /// Creates detached storage initialized from schema defaults.
    public init(metadata: [Schema.PropertyMetadata]) {
        self.metadata = metadata
        identifier = PersistentIdentifier(
            storeIdentifier: "OSD.Detached",
            entityName: String(describing: Model.self),
            temporaryIdentifier: UUID()
        )
        for property in metadata {
            guard let keyPath = property.keypath else { continue }
            guard let defaultValue = property.packageRuntimeDefaultValue else { continue }
            values[keyPath] = defaultValue
        }
    }

    /// The temporary identifier for this detached model.
    public var persistentModelID: PersistentIdentifier { identifier }
    /// The context managing this model, if any.
    public var modelContext: ModelContext? { nil }
    /// Whether this model has been deleted.
    public var isDeleted: Bool { false }
    /// Whether this model has unsaved changes.
    public var hasChanges: Bool { false }

    /// Reads a stored value for the given property key path.
    public func getValue<Value>(forKey keyPath: KeyPath<Model, Value>) -> Value {
        lock.lock()
        let storedValue = values[keyPath]
        lock.unlock()
        if let value = storedValue as? Value { return value }
        return unassignedValue(for: keyPath)
    }

    /// Stores a value for the given property key path.
    public func setValue<Value>(forKey keyPath: KeyPath<Model, Value>, to value: Value) {
        lock.lock()
        values[keyPath] = value
        lock.unlock()
    }

    private func unassignedValue<Value>(for keyPath: KeyPath<Model, Value>) -> Value {
        if let optionalType = Value.self as? any _OptionalType.Type,
            let nilValue = optionalType.nilValue as? Value
        {
            return nilValue
        }
        let propertyName = metadata.first { $0.keypath == keyPath }?.name ?? "unknown"
        fatalError("OSD: property '\(propertyName)' of \(Model.self) was read before assignment")
    }
}

private protocol _OptionalType { static var nilValue: Any { get } }
extension Optional: _OptionalType { static var nilValue: Any { Self.none as Any } }

public extension PersistentModel {
    /// Creates detached backing data initialized from schema defaults.
    static func createBackingData() -> DetachedBackingData<Self> {
        DetachedBackingData(metadata: schemaMetadata())
    }
}
