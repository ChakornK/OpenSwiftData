import Foundation

/// Describes a model container's store configuration.
public struct ModelConfiguration: Sendable {
    /// The configuration name.
    public let name: String
    /// The location of the store, if file-backed.
    public let url: URL?
    /// Whether the store is held only in memory.
    public let isStoredInMemoryOnly: Bool
    /// Whether the container permits saving.
    public let allowsSave: Bool
    /// The app-group container selection.
    public let groupContainer: GroupContainer
    /// The CloudKit database selection, retained for API compatibility.
    public let cloudKitDatabase: CloudKitDatabase
    package let storeFactory: RuntimeStoreFactory?
    package let schemaVersionReader: RuntimeSchemaVersionReader?
    package let schemaCompatibilityReader: RuntimeSchemaCompatibilityReader?
    package let dataStoreConfiguration: (any DataStoreConfiguration)?

    /// Creates a store configuration.
    public init(
        _ name: String = "default",
        schema: Schema? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none
    ) {
        self.name = name
        url = nil
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        storeFactory = nil
        schemaVersionReader = nil
        schemaCompatibilityReader = nil
        dataStoreConfiguration = nil
        _ = schema
    }

    package init(
        _ name: String = "default",
        schema: Schema? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none,
        storeFactory: RuntimeStoreFactory?,
        schemaVersionReader: RuntimeSchemaVersionReader? = nil,
        schemaCompatibilityReader: RuntimeSchemaCompatibilityReader? = nil,
        dataStoreConfiguration: (any DataStoreConfiguration)? = nil
    ) {
        self.name = name
        url = nil
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        self.storeFactory = storeFactory
        self.schemaVersionReader = schemaVersionReader
        self.schemaCompatibilityReader = schemaCompatibilityReader
        self.dataStoreConfiguration = dataStoreConfiguration
        _ = schema
    }

    /// Creates a store configuration with an explicit URL.
    public init(
        _ name: String = "default",
        schema: Schema? = nil,
        url: URL,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none
    ) {
        self.name = name
        self.url = url
        isStoredInMemoryOnly = false
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        storeFactory = nil
        schemaVersionReader = nil
        schemaCompatibilityReader = nil
        dataStoreConfiguration = nil
        _ = schema
    }

    package init(
        _ name: String = "default",
        schema: Schema? = nil,
        url: URL,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none,
        storeFactory: RuntimeStoreFactory?,
        schemaVersionReader: RuntimeSchemaVersionReader? = nil,
        schemaCompatibilityReader: RuntimeSchemaCompatibilityReader? = nil,
        dataStoreConfiguration: (any DataStoreConfiguration)? = nil
    ) {
        self.name = name
        self.url = url
        isStoredInMemoryOnly = false
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        self.storeFactory = storeFactory
        self.schemaVersionReader = schemaVersionReader
        self.schemaCompatibilityReader = schemaCompatibilityReader
        self.dataStoreConfiguration = dataStoreConfiguration
        _ = schema
    }

    /// Creates a configuration backed by a custom value-oriented data store.
    public init(
        _ name: String = "custom",
        schema: Schema? = nil,
        allowsSave: Bool = true,
        dataStoreConfiguration: any DataStoreConfiguration
    ) {
        self.name = name
        url = nil
        isStoredInMemoryOnly = false
        self.allowsSave = allowsSave
        groupContainer = .none
        cloudKitDatabase = .none
        storeFactory = nil
        schemaVersionReader = nil
        schemaCompatibilityReader = nil
        self.dataStoreConfiguration = dataStoreConfiguration
        _ = schema
    }

    /// Selects an app-group container.
    public enum GroupContainer: Sendable {
        /// Uses no app-group container.
        case none
        /// Uses the named app-group container.
        case identifier(String)
    }

    /// Selects a CloudKit database.
    public enum CloudKitDatabase: Sendable {
        /// Does not use CloudKit.
        case none
        /// Uses the private CloudKit database.
        case `private`
        /// Uses the public CloudKit database.
        case `public`
        /// Uses the named CloudKit database.
        case automatic
    }
}

extension ModelConfiguration {
    /// The configuration name and file name stem of the implicit default store.
    package static let defaultStoreName = "default"

    /// Overrides the directory that holds the implicit default store for the current task.
    ///
    /// When `nil`, the default store lives in the user-domain Application Support directory.
    @TaskLocal package static var defaultStoreDirectoryOverride: URL?

    /// Returns the SQLite file configuration used when a container is created without configurations.
    ///
    /// The store is `default.store` inside the user-domain Application Support directory, or inside
    /// ``defaultStoreDirectoryOverride`` when one is set. Creates the directory when it is missing
    /// and throws when the directory cannot be resolved or created.
    package static func implicitDefault() throws -> ModelConfiguration {
        let fileManager = FileManager.default
        let directory: URL
        if let override = defaultStoreDirectoryOverride {
            try fileManager.createDirectory(at: override, withIntermediateDirectories: true)
            directory = override
        } else {
            directory = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        return ModelConfiguration(
            defaultStoreName,
            url: directory.appendingPathComponent("\(defaultStoreName).store"),
            storeFactory: SQLiteStoreProvider.factory,
            schemaVersionReader: SQLiteStoreProvider.versionReader,
            schemaCompatibilityReader: SQLiteStoreProvider.schemaCompatibilityReader)
    }
}
