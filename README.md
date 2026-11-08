# OpenSwiftData

OpenSwiftData is an open-source, cross-platform implementation of SwiftData’s persistence APIs that lets SwiftData apps build with xtool on Linux, where Apple’s SwiftData framework is unavailable. It uses GRDB and SQLite for storage.

OpenSwiftData is under active development. See [Compatibility](#compatibility) for behavior that differs from Apple’s SwiftData implementation.

## Requirements

- Swift 6.0 or later
- iOS 17, macOS 14, tvOS 17, or watchOS 10
- Xcode or xtool to build Apple platform apps

## Add the package

Add the package dependency and products to your app target in `Package.swift`:

```swift
.package(url: "https://github.com/ChakornK/OpenSwiftData", branch: "main")
```

```swift
.product(name: "OpenSwiftData", package: "OpenSwiftData"),
.product(name: "OpenSwiftDataSQLite", package: "OpenSwiftData"),
```

## Quick start

Create a model and a file-backed store. Insert a note, save it, then fetch it:

```swift
import Foundation
import OpenSwiftData
import OpenSwiftDataSQLite

@Model
final class Note {
    var text: String

    init(text: String) {
        self.text = text
    }
}

let storeURL = URL.applicationSupportDirectory
    .appending(path: "Notes.sqlite")
let configuration = ModelConfiguration.sqliteFile("notes", url: storeURL)
let container = try ModelContainer(
    for: Note.self,
    configurations: configuration
)

let context = container.mainContext
context.insert(Note(text: "First note"))
try context.save()

let notes = try context.fetch(FetchDescriptor<Note>())
```

For temporary data, replace the file configuration with:

```swift
let configuration = ModelConfiguration.sqliteMemory("notes")
```

## Build iOS apps from Linux

When you build an iOS app from Linux, Swift's `#Predicate` macro may refer to `FoundationEssentials` types that Apple's SDK normally exposes through `Foundation`. Add the [FoundationEssentials shim](https://github.com/ChakornK/FoundationEssentialsShim) package to your app's `Package.swift`, then add its `FoundationEssentials` product to the iOS app target:

```swift
.package(url: "https://github.com/ChakornK/FoundationEssentialsShim", branch: "main")
```

```swift
.product(name: "FoundationEssentials", package: "FoundationEssentialsShim"),
```

Import `FoundationEssentials` in files that need its declarations. The shim re-exports `Foundation`:

```swift
import FoundationEssentials
```

For builds on macOS, use Apple's `Foundation` directly.

## Compatibility

OpenSwiftData uses its own SQLite store and cannot open Apple's SwiftData stores. It implements selected SwiftData APIs and behaviors. The source and tests show the supported surface.

### Behavior differences

- Apple bugs that lose data or crash are not replicated. Examples include a pending rename lost after a batch delete, crashes on fetch after `erase()`, and crashes on `fetchCount` with an offset.
- Where Apple returns results that contradict Swift semantics, OpenSwiftData follows Swift semantics. For example, Apple's `name.count == 4` doesn't match `"beta"`.
- Nondeterministic Apple behavior, such as unsorted order with pending changes or which duplicate survives when two are inserted in one save, is not matched.
- Replicated Apple quirks: `.deny` is not enforced, and context deletes nullify related models.
- Deleting an unsaved model keeps it attached and marked deleted until save or rollback. Batch deletes reject entities with `.deny` relationships and leave pending changes and registered model instances intact.
- `Schema` exposes class-based entities and attributes, `Set`-typed metadata, runtime `valueType`, and `Schema.CompositeAttribute` for flattened composite properties. The ordered `SchemaDescriptor` remains the storage/migration representation. Custom stores use canonical `DataStoreConfiguration` and `DataStore` names. The previous engine contract is renamed `OpenSwiftDataDataStore`; this is a major-version source migration. The snapshot API also exposes Apple's `DataStoreSnapshotValue` alias and `DataStoreSnapshotCodingKey`. Custom coders can key fields with `DataStoreSnapshotCodingKey.modeledProperty`; a macOS-tested third-party SwiftData store sample confirms that modeled values are materialized by property name and that renamed keys fail. The built-in context accepts that property-name keyspace when fields match the schema. It also accepts the strict Codable fallback: an exact keyed object containing `persistentIdentifier`, `entityName`, `relationships`, and either top-level schema attribute/component keys or one nested `values` object. Custom snapshots may instead conform to `DataStoreSnapshotValueProviding`. Built-in scalar JSON representations and nested JSON objects/arrays are supported; reserved-key collisions, renamed/opaque keys, extra keys, and custom primitive encodings are rejected. Arbitrary opaque layouts remain unsupported because the public snapshot protocol has no reverse materialization operation. `AppleDefaultSnapshot` uses the value-provider capability. `AppleDefaultSnapshot.capture(from:in:)` captures scalar, flattened, and reachable relationship values; its deprecated backing-only initializer remains identity-only because backing data is type-erased.
- `AppleSDKProbe/` is a standalone macOS test package that runs against the system SwiftData framework via `.github/workflows/apple-sdk-probe.yml`. On macOS 15, the probe confirms `.modeledProperty("title").stringValue == "title"` and that a custom snapshot can materialize a to-one relationship and its inverse to-many collection. This validates the modeled-property convention, not arbitrary opaque snapshot layouts.

### Platform and storage limits

- SQLite through GRDB is the default backend. CloudKit is unsupported.
- The package builds on Linux and Apple platforms. On Linux, `NotificationCenter` observers filtered with `object: context` do not receive save notifications.

## License

[Apache License 2.0](LICENSE)
