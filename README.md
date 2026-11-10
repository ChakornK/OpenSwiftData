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

1. Batch delete, `delete.state`: the saved model remains registered and not deleted in Apple; OpenSwiftData marks it deleted and unregisters it.
2. Deleted insertion rollback, `hasChanges`: Apple reports changes; OpenSwiftData reports none.
3. Fetch descriptor defaults, `fetchOffsetAbsent`: Apple's offset is present; OpenSwiftData's is absent.
4. Fetch descriptor equality, `samePredicateAndSortEqual`: Apple reports unequal; OpenSwiftData reports equal.
5. Container configurations, `configurationSetMatches`: OpenSwiftData's configurations form the expected set; Apple's do not.
6. Erase, `lastCompletedStep`: Apple's probe checkpoints step 2 before its post-erase save traps; OpenSwiftData completes step 4.
7. Erase, `pendingFetchReturned`: the Apple probe does not complete the fetch after its save trap; OpenSwiftData completes it.
8. Erase, `pendingNamesAfterSave`: the Apple probe has no fetched names after its save trap; OpenSwiftData fetches `[\"pending\"]`.
9. Erase, `pendingSaveReturned`: the Apple probe does not complete the save after `erase()`; OpenSwiftData completes it.
10. Rollback detaching related insertions, `itemOwnerAbsent`: Apple keeps the inverse relationship; OpenSwiftData clears it.
11. Rollback detaching related insertions, `ownerItemCount`: Apple retains one related item; OpenSwiftData retains none.
12. Rollback of committed relationship edits, `itemOwnerAbsent`: Apple keeps the inverse relationship; OpenSwiftData clears it.
13. Rollback of committed relationship edits, `ownerItemCount`: Apple retains one related item; OpenSwiftData retains none.
14. Repeated-edit rollback, `ageAfterFirstRollback`: Apple reports 3; OpenSwiftData reports 1.
15. Repeated-edit rollback, `ageAfterSecondRollback`: Apple reports 4; OpenSwiftData reports 1.
16. Rollback after editing then deleting, `age`: Apple reports 2; OpenSwiftData reports 1.
17. Schema indices, `book.indices`: OpenSwiftData reports `title`; Apple reports `binary` and `title` for the index.
18. Schema relationship flags, `author.books.flags`: OpenSwiftData marks `books` as a relationship; Apple's flag is false.
19. Schema Codable round-trip, `roundTrip.book.indices`: OpenSwiftData preserves the `title` index; Apple returns no indices.
20. Store reopen, `reopened.identifierEqual`: OpenSwiftData's fetched model has the original identifier; Apple's fetched model does not.
21. Store reopen, `reopened.registeredName`: OpenSwiftData resolves the registered model as `a`; Apple returns `missing`.
22. Saved optional `flatMap`, `nick.empty.false`: OpenSwiftData matches `délta`; Apple returns no matches.
23. Saved optional `flatMap`, `nick.isEmpty.direct`: OpenSwiftData matches `délta`; Apple returns no matches.
24. Saved `String.count`, `length.4`: OpenSwiftData matches `beta`; Apple returns no matches.
25. Saved `String.count`, `length.5`: OpenSwiftData matches `Alpha`, `Gamma`, and `délta`; Apple returns no matches.
26. Saved `String.count`, `length.gt5`: OpenSwiftData matches `Épsilon`; Apple matches every row.
27. Duplicate inserts in one save, `survivorsObserved`: OpenSwiftData fetches only `z/2/nil`; Apple fetches `z/1/nil` and `z/2/nil`.

28. Custom `DataStore` parity is implemented for the core protocol: `DataStoreConfiguration` with `Store`, typed `DataStoreSaveChangesRequest` deletions with editing state, generic `DataStoreSaveChangesResult` with `snapshotsToReregister`, `DataStoreSnapshot` requiring only Apple's members, `DefaultSnapshot` values, direct `ModelContainer` configuration, and `Schema.CompositeAttribute` as a `Schema.Attribute` subclass with `properties`. Batch deletes route through `DataStoreBatching.delete(_:)` when the store conforms, and custom stores that return a history token from `save(_:)` record it for `fetchHistory`.

</details>

### Platform and storage limits

- SQLite through GRDB is the default backend. CloudKit is unsupported.
- The package builds on Linux and Apple platforms. On Linux, `NotificationCenter` observers filtered with `object: context` do not receive save notifications.

## License

[Apache License 2.0](LICENSE)
