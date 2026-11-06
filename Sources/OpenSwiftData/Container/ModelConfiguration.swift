import Foundation

/// Describes where and how a model container stores data.
///
/// Configurations compare equal when their names, URLs, schemas, save permission, and in-memory flag match;
/// the app-group and CloudKit selections do not affect equality.
public struct ModelConfiguration: Identifiable, Hashable, Sendable, CustomDebugStringConvertible {
    /// The location of the store file; `/dev/null` for in-memory stores.
    public let url: URL
    /// The configuration name, which also names the default store file.
    public let name: String
    /// The app-group identifier selected by `groupContainer`, if any.
    public let groupAppContainerIdentifier: String?
    /// The CloudKit container identifier selected by `cloudKitDatabase`, if any.
    public let cloudKitContainerIdentifier: String?
    /// The app-group container selection.
    public let groupContainer: GroupContainer
    /// The CloudKit database selection.
    public let cloudKitDatabase: CloudKitDatabase
    /// The models stored by this configuration, or `nil` to store every model in the container's schema.
    public var schema: Schema?
    /// Whether contexts may save changes to the store.
    public let allowsSave: Bool
    /// Whether the store lives only in memory.
    public let isStoredInMemoryOnly: Bool
    package let storeFactory: RuntimeStoreFactory?
    package let schemaVersionReader: RuntimeSchemaVersionReader?
    package let schemaCompatibilityReader: RuntimeSchemaCompatibilityReader?
    package let dataStoreConfiguration: (any DataStoreConfiguration)?

    /// The store URL, which identifies the configuration.
    public var id: URL { url }

    /// Selects a CloudKit database for syncing.
    public struct CloudKitDatabase: Hashable, Sendable {
        package let isAutomatic: Bool
        package let isNone: Bool
        package let privateDatabaseName: String?

        /// Uses the app's default CloudKit container when the app has one.
        public static var automatic: CloudKitDatabase {
            CloudKitDatabase(isAutomatic: true, isNone: false, privateDatabaseName: nil)
        }
        /// Disables CloudKit syncing.
        public static var none: CloudKitDatabase {
            CloudKitDatabase(isAutomatic: false, isNone: true, privateDatabaseName: nil)
        }
        /// Syncs with the named private CloudKit database.
        public static func `private`(_ privateDBName: String) -> CloudKitDatabase {
            CloudKitDatabase(isAutomatic: false, isNone: false, privateDatabaseName: privateDBName)
        }
    }

    /// Selects an app-group container for the store file.
    public struct GroupContainer: Hashable, Sendable {
        package let isAutomatic: Bool
        package let isNone: Bool
        package let identifier: String?

        /// Uses the app's first app-group container when the app has one.
        public static var automatic: GroupContainer {
            GroupContainer(isAutomatic: true, isNone: false, identifier: nil)
        }
        /// Stores the file outside any app-group container.
        public static var none: GroupContainer { GroupContainer(isAutomatic: false, isNone: true, identifier: nil) }
        /// Stores the file in the named app-group container.
        public static func identifier(_ groupName: String) -> GroupContainer {
            GroupContainer(isAutomatic: false, isNone: false, identifier: groupName)
        }
    }

    /// Creates the default configuration, optionally held in memory.
    public init(isStoredInMemoryOnly: Bool = false) {
        self.init(nil, isStoredInMemoryOnly: isStoredInMemoryOnly)
    }

    /// Creates a default-named configuration that stores the given model types.
    public init(for forTypes: any PersistentModel.Type..., isStoredInMemoryOnly: Bool = false) {
        self.init(nil, schema: Schema(forTypes), isStoredInMemoryOnly: isStoredInMemoryOnly)
    }

    /// Creates a configuration whose store file is `<name>.store` in Application Support.
    ///
    /// A `nil` name means `"default"`. In-memory configurations use `/dev/null` as their URL.
    public init(
        _ name: String? = nil,
        schema: Schema? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .automatic,
        cloudKitDatabase: CloudKitDatabase = .automatic
    ) {
        self.init(
            name, schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly, allowsSave: allowsSave,
            groupContainer: groupContainer, cloudKitDatabase: cloudKitDatabase,
            storeFactory: SQLiteStoreProvider.factory,
            schemaVersionReader: SQLiteStoreProvider.versionReader,
            schemaCompatibilityReader: SQLiteStoreProvider.schemaCompatibilityReader)
    }

    /// Creates a configuration that stores data at an explicit file URL.
    public init(
        _ name: String? = nil,
        schema: Schema? = nil,
        url: URL,
        allowsSave: Bool = true,
        cloudKitDatabase: CloudKitDatabase = .automatic
    ) {
        self.init(
            name, schema: schema, url: url, allowsSave: allowsSave, cloudKitDatabase: cloudKitDatabase,
            storeFactory: SQLiteStoreProvider.factory,
            schemaVersionReader: SQLiteStoreProvider.versionReader,
            schemaCompatibilityReader: SQLiteStoreProvider.schemaCompatibilityReader)
    }

    package init(
        _ name: String? = nil,
        schema: Schema? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .automatic,
        cloudKitDatabase: CloudKitDatabase = .automatic,
        storeFactory: RuntimeStoreFactory?,
        schemaVersionReader: RuntimeSchemaVersionReader? = nil,
        schemaCompatibilityReader: RuntimeSchemaCompatibilityReader? = nil,
        dataStoreConfiguration: (any DataStoreConfiguration)? = nil
    ) {
        let name = name ?? Self.defaultStoreName
        let url =
            isStoredInMemoryOnly
            ? URL(fileURLWithPath: "/dev/null")
            : Self.defaultStoreDirectory(groupContainer: groupContainer).appendingPathComponent("\(name).store")
        self.init(
            name: name, url: url, schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly, allowsSave: allowsSave,
            groupContainer: groupContainer, cloudKitDatabase: cloudKitDatabase, storeFactory: storeFactory,
            schemaVersionReader: schemaVersionReader, schemaCompatibilityReader: schemaCompatibilityReader,
            dataStoreConfiguration: dataStoreConfiguration)
    }

    package init(
        _ name: String? = nil,
        schema: Schema? = nil,
        url: URL,
        allowsSave: Bool = true,
        cloudKitDatabase: CloudKitDatabase = .automatic,
        storeFactory: RuntimeStoreFactory?,
        schemaVersionReader: RuntimeSchemaVersionReader? = nil,
        schemaCompatibilityReader: RuntimeSchemaCompatibilityReader? = nil,
        dataStoreConfiguration: (any DataStoreConfiguration)? = nil
    ) {
        self.init(
            name: name ?? Self.defaultStoreName, url: url, schema: schema, isStoredInMemoryOnly: false,
            allowsSave: allowsSave, groupContainer: .automatic, cloudKitDatabase: cloudKitDatabase,
            storeFactory: storeFactory, schemaVersionReader: schemaVersionReader,
            schemaCompatibilityReader: schemaCompatibilityReader, dataStoreConfiguration: dataStoreConfiguration)
    }

    /// Creates a configuration backed by a custom value-oriented data store.
    public init(
        _ name: String = "custom",
        schema: Schema? = nil,
        allowsSave: Bool = true,
        dataStoreConfiguration: any DataStoreConfiguration
    ) {
        self.init(
            name: name, url: URL(fileURLWithPath: "/dev/null"), schema: schema, isStoredInMemoryOnly: false,
            allowsSave: allowsSave, groupContainer: .none, cloudKitDatabase: .none, storeFactory: nil,
            schemaVersionReader: nil, schemaCompatibilityReader: nil, dataStoreConfiguration: dataStoreConfiguration)
    }

    private init(
        name: String,
        url: URL,
        schema: Schema?,
        isStoredInMemoryOnly: Bool,
        allowsSave: Bool,
        groupContainer: GroupContainer,
        cloudKitDatabase: CloudKitDatabase,
        storeFactory: RuntimeStoreFactory?,
        schemaVersionReader: RuntimeSchemaVersionReader?,
        schemaCompatibilityReader: RuntimeSchemaCompatibilityReader?,
        dataStoreConfiguration: (any DataStoreConfiguration)?
    ) {
        self.name = name
        self.url = url
        self.schema = schema
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        groupAppContainerIdentifier = groupContainer.identifier
        cloudKitContainerIdentifier = cloudKitDatabase.privateDatabaseName
        self.storeFactory = storeFactory
        self.schemaVersionReader = schemaVersionReader
        self.schemaCompatibilityReader = schemaCompatibilityReader
        self.dataStoreConfiguration = dataStoreConfiguration
    }

    /// Throws when the name cannot form a store file name.
    ///
    /// Names longer than 255 characters throw `configurationFileNameTooLong`; names containing
    /// `/ : \ * ? " < > |` throw `configurationFileNameContainsInvalidCharacters`.
    public func validate() throws {
        guard name.count <= 255 else { throw SwiftDataError.configurationFileNameTooLong }
        guard !name.contains(where: { Self.invalidNameCharacters.contains($0) }) else {
            throw SwiftDataError.configurationFileNameContainsInvalidCharacters
        }
    }

    private static let invalidNameCharacters: Set<Character> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"]

    public static func == (lhs: ModelConfiguration, rhs: ModelConfiguration) -> Bool {
        lhs.name == rhs.name && lhs.url == rhs.url && lhs.schema == rhs.schema && lhs.allowsSave == rhs.allowsSave
            && lhs.isStoredInMemoryOnly == rhs.isStoredInMemoryOnly
    }

    /// Hashes the name, URL, save permission, and in-memory flag; the schema is not hashed.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(url)
        hasher.combine(allowsSave)
        hasher.combine(isStoredInMemoryOnly)
    }

    public var debugDescription: String {
        """
        ModelConfiguration
        name: \(name)
        url: \(url.absoluteString)
        allowsSave: \(allowsSave)
        isStoredInMemoryOnly: \(isStoredInMemoryOnly)
        cloudKitDatabase: CloudKitDatabase(_automatic: \(cloudKitDatabase.isAutomatic), \
        _none: \(cloudKitDatabase.isNone), _privateDBName: \(Self.describe(cloudKitDatabase.privateDatabaseName)))
        cloudKitContainerIdentifier: \(Self.describe(cloudKitContainerIdentifier))
        groupContainer: GroupContainer(_automatic: \(groupContainer.isAutomatic), \
        _none: \(groupContainer.isNone), _identifier: \(Self.describe(groupContainer.identifier)))
        groupAppContainerIdentifier: \(Self.describe(groupAppContainerIdentifier))
        """
    }

    private static func describe(_ value: String?) -> String {
        value.map { "Optional(\($0.debugDescription))" } ?? "nil"
    }
}

extension ModelConfiguration {
    /// The configuration name and file name stem used when no name is given.
    package static let defaultStoreName = "default"

    /// Overrides the directory that holds default-located store files for the current task.
    ///
    /// When `nil`, default-located stores live in the user-domain Application Support directory.
    @TaskLocal package static var defaultStoreDirectoryOverride: URL?

    /// Returns the directory for default-located store files.
    ///
    /// Uses ``defaultStoreDirectoryOverride`` when set. App-group identifiers resolve to the group container's
    /// `Library/Application Support` directory on Apple platforms. Otherwise uses the user-domain Application
    /// Support directory, falling back to the temporary directory when that cannot be resolved.
    private static func defaultStoreDirectory(groupContainer: GroupContainer) -> URL {
        if let override = defaultStoreDirectoryOverride { return override }
        #if canImport(Darwin)
            if let identifier = groupContainer.identifier,
                let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            {
                return container.appendingPathComponent("Library/Application Support", isDirectory: true)
            }
        #endif
        return (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
    }

    /// Returns the configuration used when a container is created without configurations.
    ///
    /// Equals `ModelConfiguration()`: a SQLite file named `default.store` in the default store directory.
    package static func implicitDefault() throws -> ModelConfiguration {
        ModelConfiguration()
    }
}
