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
- `Schema` now exposes a class-based, Apple-shaped facade with `Set`-typed entities, attributes, and relationships, runtime attribute `valueType`, model-type initialization, and container/configuration routing. Storage and migration continue to use the internal `SchemaDescriptor`; exact Apple metadata parity, including composite attribute/value conversion and complete custom-store snapshot conversion, remains tracked in [issue #8](https://github.com/ChakornK/OpenSwiftData/issues/8). The custom-store API still uses prefixed Apple-shaped protocols and requires an explicit `AppleDataStoreBackendProviding` adapter. `AppleDefaultSnapshot`'s deprecated nonthrowing backing-data initializer captures identity only because backing data cannot safely expose model property values.

### Platform and storage limits

- SQLite through GRDB is the default backend. CloudKit is unsupported.
- The package builds on Linux and Apple platforms. On Linux, `NotificationCenter` observers filtered with `object: context` do not receive save notifications.

## License

[Apache License 2.0](LICENSE)
