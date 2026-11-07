# OpenSwiftData

**SwiftData-style persistence for apps built with Xcode or xtool.** OpenSwiftData uses the open-source GRDB and SQLite stack, so your app can work with models and contexts without depending on Apple’s proprietary SwiftData framework.

> OpenSwiftData is under active development. Follow the `main` branch for current changes.

## What you get

- Familiar `@Model`, `ModelContainer`, and `ModelContext` APIs
- SQLite file-backed and in-memory stores
- GRDB setup handled by the package

## How OpenSwiftData differs from SwiftData

OpenSwiftData follows SwiftData's API and behavior where the project has implemented and tested them. It is a separate persistence library: it does not use Apple's SwiftData stores, and compatibility is not complete.

### Behavior differences

- `rollback()` clears pending-change tracking but keeps edited values in memory. A later fetch can refresh those values from the store.
- Deleting a model that has not been saved keeps it attached and marked deleted until save or rollback.
- Deleting a model through a context does not enforce the `.deny` relationship rule. Related models are nullified. Batch deletes reject entities with `.deny` relationships.
- `fetchCount` supports descriptors with an offset. The project also aims to preserve pending renames during batch deletes.
- Predicate evaluation follows Swift semantics where SwiftData has returned inconsistent results, such as comparing `String.count`.
- OpenSwiftData does not match nondeterministic result ordering or duplicate-selection behavior.

### Platform and storage limits

- The default backend is SQLite through GRDB. CloudKit is unsupported.
- The package builds on Linux as well as Apple platforms. Some behavior differs across platforms; for example, save notifications filtered with `object: context` are not delivered on Linux.
- The custom `DataStore` protocol API and SwiftData's class-based `Schema` API are not implemented. OpenSwiftData's schema uses value types and arrays for attributes and relationships.

Check the source and tests for the current compatibility surface. OpenSwiftData is under active development, so support and known differences can change.

## Add OpenSwiftData to your app

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/ChakornK/OpenSwiftData", branch: "main")
```

Add both products to your app target:

```swift
.product(name: "OpenSwiftData", package: "OpenSwiftData"),
.product(name: "OpenSwiftDataSQLite", package: "OpenSwiftData"),
```

Import both modules in the file that configures persistence:

```swift
import OpenSwiftData
import OpenSwiftDataSQLite
```

## Quick start

### 1. Define a model

```swift
@Model
final class Note {
    var text: String

    init(text: String) {
        self.text = text
    }
}
```

### 2. Choose a store

Use a file-backed store for data you want to keep, or an in-memory store for temporary data:

```swift
import Foundation

let storeURL = URL.applicationSupportDirectory
    .appending(path: "Notes.sqlite")
let configuration = ModelConfiguration.sqliteFile("notes", url: storeURL)

// For temporary data, use this instead:
// let configuration = ModelConfiguration.sqliteMemory("notes")
```

### 3. Create, save, and fetch

```swift
let container = try ModelContainer(
    for: Note.self,
    configurations: configuration
)

let context = container.mainContext
context.insert(Note(text: "First note"))
try context.save()

let notes = try context.fetch(FetchDescriptor<Note>())
```

## Requirements

- Xcode or xtool

## License

OpenSwiftData is available under the [Apache License 2.0](LICENSE).
