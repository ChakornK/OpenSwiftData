import Foundation
import OpenSwiftData
import OpenSwiftDataSQLite

@Model
final class ExternalClientModel {
    var title: String = ""
}

func openExternalClientMemoryContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration.sqliteMemory("external-memory")
    return try ModelContainer(for: ExternalClientModel.self, configurations: configuration)
}

func openExternalClientFileContainer(at url: URL) throws -> ModelContainer {
    let configuration = ModelConfiguration.sqliteFile("external-file", url: url)
    return try ModelContainer(for: ExternalClientModel.self, configurations: configuration)
}
