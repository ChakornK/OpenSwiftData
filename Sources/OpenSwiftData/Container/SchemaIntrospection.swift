import Foundation
import OSDCore

extension Schema {
    /// Entities whose superentity is the given entity.
    public func subentities(of entity: Entity) -> [Entity] {
        entities.filter { $0.superentityName == entity.name }
    }

    /// The parent entity of the given entity in an inheritance hierarchy.
    public func superentity(of entity: Entity) -> Entity? {
        entity.superentityName.flatMap(self.entity(forName:))
    }

    /// Writes the schema's entities and version to a file that `load(from:)` reads back.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads a schema previously written by `save(to:)`.
    ///
    /// The loaded schema describes entities only; it isn't linked to model types.
    public static func load(from url: URL) throws -> Schema {
        try JSONDecoder().decode(Schema.self, from: Data(contentsOf: url))
    }
}
