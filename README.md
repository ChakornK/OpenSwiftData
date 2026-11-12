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

The parity suite tracks behavior and API differences. Expand the list for details:

<details>
<summary>Show all</summary>

1. Erase, `lastCompletedStep`: Apple's probe checkpoints step 2 before its post-erase save traps; OpenSwiftData completes step 4.
2. Erase, `pendingFetchReturned`: the Apple probe does not complete the fetch after its save trap; OpenSwiftData completes it.
3. Erase, `pendingNamesAfterSave`: the Apple probe has no fetched names after its save trap; OpenSwiftData fetches `[\"pending\"]`.
4. Erase, `pendingSaveReturned`: the Apple probe does not complete the save after `erase()`; OpenSwiftData completes it.
5. Saved optional `flatMap`, `nick.empty.false`: OpenSwiftData matches `délta`; Apple returns no matches.
6. Saved optional `flatMap`, `nick.isEmpty.direct`: OpenSwiftData matches `délta`; Apple returns no matches.
7. Saved `String.count`, `length.4`: OpenSwiftData matches `beta`; Apple returns no matches.
8. Saved `String.count`, `length.5`: OpenSwiftData matches `Alpha`, `Gamma`, and `délta`; Apple returns no matches.
9. Saved `String.count`, `length.gt5`: OpenSwiftData matches `Épsilon`; Apple matches every row.
10. Duplicate inserts in one save, `survivorsObserved`: OpenSwiftData deterministically keeps the last insert as the survivor; Apple's survivor is non-deterministic (Set iteration order), so either insert may win.

</details>

### Known custom-store differences

- Stores that do not conform to `DataStoreBatching` reject `delete(model:where:includeSubclasses:)`.
- History reported by custom stores lives in an in-memory ledger and is not durable across launches.
- `HistoryProviding` (fetching history from the store object itself) is not implemented; use
  `ModelContext.fetchHistory(_:)`.
- CloudKit-backed configurations reject custom stores.

</details>

### Platform and storage limits

- SQLite through GRDB is the default backend. CloudKit is unsupported.
- The package builds on Linux and Apple platforms. On Linux, `NotificationCenter` observers filtered with `object: context` do not receive save notifications.

## License

[Apache License 2.0](LICENSE)
