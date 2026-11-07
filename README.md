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

- Apple bugs that lose data or crash are not replicated. Examples include losing a pending rename after a batch delete, crashing when fetching after `erase()`, and crashing in `fetchCount` when a descriptor has an offset.
- Deleting an unsaved model keeps it attached and marked deleted until save or rollback.
- Context deletes do not enforce the `.deny` relationship rule and nullify related models. Batch deletes reject entities with `.deny` relationships.
- Batch deletes leave pending changes and registered model instances intact.
- Predicate evaluation follows Swift semantics in cases where SwiftData has returned inconsistent results, such as comparisons involving `String.count`.
- When SwiftData returns nondeterministic result order or duplicate selection, OpenSwiftData may return a different result.
- Rollback restores changed models to their most recently committed values, as documented by Apple SwiftData.

### Platform and storage limits

- SQLite through GRDB is the default backend. CloudKit is unsupported.
- The package builds on Linux and Apple platforms. On Linux, `NotificationCenter` observers filtered with `object: context` do not receive save notifications.
- The custom `DataStore` protocol API and SwiftData's class-based `Schema` API are not implemented. OpenSwiftData schemas use value types and arrays for attributes and relationships.

## License

[Apache License 2.0](LICENSE)
