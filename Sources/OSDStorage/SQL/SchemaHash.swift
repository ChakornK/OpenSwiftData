import Foundation
import OSDCore

package enum SchemaHash {
    package static func digest(_ schema: Schema) -> [UInt8] {
        SHA256.hash(canonicalEncoding(of: schema))
    }

    package static func digest(_ bytes: [UInt8]) -> [UInt8] {
        SHA256.hash(bytes)
    }

    package static func hexDigest(_ schema: Schema) -> String {
        digest(schema).map { String(format: "%02x", $0) }.joined()
    }

    package static func canonicalEncoding(of schema: Schema) -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.append("OpenSwiftData.LayoutA.Schema.v1")
        encoder.append(
            schema.entities.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) },
            element: {
                encoder, entity in
                encoder.append(entity.name)
                if let superentityName = entity.superentityName {
                    encoder.append(superentityName)
                }
                encoder.append(
                    entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) },
                    element: {
                        encoder, attribute in
                        encoder.append(attribute.name)
                        encoder.append(attribute.type)
                        encoder.append(attribute.isOptional)
                        encoder.append(attribute.defaultValue)
                        encoder.append(attribute.originalName)
                        encoder.append(
                            attribute.components,
                            element: { encoder, component in
                                encoder.append(component.name)
                                encoder.append(component.columnName)
                                encoder.append(component.type)
                            })
                        encoder.append(
                            attribute.options.map(\.canonicalName).sorted(),
                            element: { encoder, option in
                                encoder.append(option)
                            })
                    })
                encoder.append(
                    entity.relationships.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) },
                    element: {
                        encoder, relationship in
                        encoder.append(relationship.name)
                        encoder.append(relationship.destination)
                        encoder.append(relationship.isToMany)
                        encoder.append(relationship.deleteRule.rawValue)
                        encoder.append(relationship.inverse)
                        encoder.append(relationship.minimumModelCount)
                        encoder.append(relationship.maximumModelCount)
                        encoder.append(relationship.originalName)
                        if let declaringEntityName = relationship.declaringEntityName {
                            encoder.append("declaringEntityName")
                            encoder.append(declaringEntityName)
                        }
                    })
                encoder.append(
                    entity.indexes.sorted(by: indexLess),
                    element: { encoder, index in
                        encoder.append(index.isUnique)
                        encoder.append(index.properties, element: { encoder, property in encoder.append(property) })
                    })
            })
        return encoder.bytes
    }

    private static func indexLess(_ lhs: Schema.Index, _ rhs: Schema.Index) -> Bool {
        if lhs.isUnique != rhs.isUnique { return lhs.isUnique && !rhs.isUnique }
        return lhs.properties.lexicographicallyPrecedes(rhs.properties) {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }

    private struct CanonicalEncoder {
        private(set) var bytes: [UInt8] = []

        mutating func append(_ value: String) {
            append(UInt64(value.utf8.count))
            bytes.append(contentsOf: value.utf8)
        }

        mutating func append(_ value: Bool) {
            bytes.append(value ? 1 : 0)
        }

        mutating func append(_ value: Int?) {
            guard let value else {
                bytes.append(0)
                return
            }
            bytes.append(1)
            append(Int64(value))
        }

        mutating func append(_ value: Int64) {
            append(UInt64(bitPattern: value))
        }

        mutating func append(_ value: UInt64) {
            var value = value
            for _ in 0..<8 {
                bytes.append(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }

        mutating func append(_ value: String?) {
            guard let value else {
                bytes.append(0)
                return
            }
            bytes.append(1)
            append(value)
        }

        mutating func append<Element>(_ values: [Element], element: (inout Self, Element) -> Void) {
            append(UInt64(values.count))
            for value in values { element(&self, value) }
        }

    }

    /// Identifies the persisted schema description format; decoding rejects any other value.
    private static let descriptionFormat = "OpenSwiftData.SchemaDescription.v1"

    /// Encodes `schema` as sorted-key JSON so equal schemas always produce identical bytes.
    ///
    /// Entities, attributes, relationships, indexes, and options use the same ordering as `canonicalEncoding(of:)`.
    /// Optional fields are omitted when nil, so nil and empty strings remain distinct after decoding.
    package static func canonicalDescription(of schema: Schema) -> String {
        let document = DescriptionDocument(
            format: descriptionFormat,
            entities: schema.entities.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                .map(DescriptionEntity.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return String(decoding: try encoder.encode(document), as: UTF8.self)
        } catch {
            preconditionFailure("Schema description encoding cannot fail: \(error)")
        }
    }

    /// Decodes a description produced by `canonicalDescription(of:)`.
    ///
    /// Throws `SwiftDataError.migrationUnsupported` for malformed JSON, unknown formats, unknown options or delete
    /// rules, and duplicate entity names.
    package static func decodeCanonicalDescription(_ description: String) throws -> Schema {
        let document: DescriptionDocument
        do {
            document = try JSONDecoder().decode(DescriptionDocument.self, from: Data(description.utf8))
        } catch {
            throw SwiftDataError.migrationUnsupported("Invalid stored schema description.")
        }
        guard document.format == descriptionFormat else {
            throw SwiftDataError.migrationUnsupported("Unsupported stored schema description format.")
        }
        var seen = Set<String>()
        let entities = try document.entities.map { entity in
            guard seen.insert(entity.name).inserted else {
                throw SwiftDataError.migrationUnsupported("Duplicate stored schema entity.")
            }
            return try entity.schemaEntity()
        }
        return Schema(entities)
    }

    private struct DescriptionDocument: Codable {
        var format: String
        var entities: [DescriptionEntity]
    }

    private struct DescriptionEntity: Codable {
        var name: String
        var superentityName: String?
        var attributes: [DescriptionAttribute]
        var relationships: [DescriptionRelationship]
        var indexes: [DescriptionIndex]

        private enum CodingKeys: String, CodingKey {
            case name, superentityName, attributes, relationships, indexes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            superentityName = try container.decodeIfPresent(String.self, forKey: .superentityName)
            attributes = try container.decode([DescriptionAttribute].self, forKey: .attributes)
            relationships = try container.decode([DescriptionRelationship].self, forKey: .relationships)
            indexes = try container.decode([DescriptionIndex].self, forKey: .indexes)
        }

        init(_ entity: Schema.Entity) {
            name = entity.name
            superentityName = entity.superentityName
            attributes = entity.attributes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                .map(DescriptionAttribute.init)
            relationships = entity.relationships.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                .map(DescriptionRelationship.init)
            indexes = entity.indexes.sorted(by: SchemaHash.indexLess).map(DescriptionIndex.init)
        }

        func schemaEntity() throws -> Schema.Entity {
            Schema.Entity(
                name: name, attributes: try attributes.map { try $0.schemaAttribute() },
                relationships: try relationships.map { try $0.schemaRelationship() },
                indexes: indexes.map { Schema.Index(properties: $0.properties, isUnique: $0.isUnique) },
                superentityName: superentityName)
        }
    }

    private struct DescriptionAttribute: Codable {
        var name: String
        var type: String
        var isOptional: Bool
        var defaultValue: String?
        var originalName: String?
        var options: [DescriptionOption]
        var components: [Schema.Attribute.Component]

        private enum CodingKeys: String, CodingKey {
            case name, type, isOptional, defaultValue, originalName, options, components
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(String.self, forKey: .type)
            isOptional = try container.decode(Bool.self, forKey: .isOptional)
            defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
            originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
            options = try container.decode([DescriptionOption].self, forKey: .options)
            components = try container.decodeIfPresent([Schema.Attribute.Component].self, forKey: .components) ?? []
        }

        init(_ attribute: Schema.Attribute) {
            name = attribute.name
            type = attribute.type
            isOptional = attribute.isOptional
            defaultValue = attribute.defaultValue
            originalName = attribute.originalName
            components = attribute.components
            options = attribute.options.map(DescriptionOption.init)
                .sorted { ($0.kind, $0.transformer ?? "") < ($1.kind, $1.transformer ?? "") }
        }

        func schemaAttribute() throws -> Schema.Attribute {
            Schema.Attribute(
                name: name, type: type, isOptional: isOptional, defaultValue: defaultValue,
                options: Set(try options.map { try $0.schemaOption() }), originalName: originalName,
                components: components)
        }
    }

    /// Stores an option as a kind plus the transformer name, which only `transformable` options carry.
    private struct DescriptionOption: Codable {
        var kind: String
        var transformer: String?

        init(_ option: Schema.Attribute.Option) {
            switch option {
            case .unique: kind = "unique"
            case .externalStorage: kind = "externalStorage"
            case .encrypt: kind = "encrypt"
            case .preserveValueOnDeletion: kind = "preserveValueOnDeletion"
            case .spotlight: kind = "spotlight"
            case let .transformable(by):
                kind = "transformable"
                transformer = by
            case .allowsCloudEncryption: kind = "allowsCloudEncryption"
            case .ephemeral: kind = "ephemeral"
            case .codable: kind = "codable"
            case .flattened: kind = "flattened"
            }
        }

        func schemaOption() throws -> Schema.Attribute.Option {
            if kind == "transformable" {
                guard let transformer else {
                    throw SwiftDataError.migrationUnsupported("Stored transformable option lacks a transformer.")
                }
                return .transformable(by: transformer)
            }
            guard transformer == nil else {
                throw SwiftDataError.migrationUnsupported("Unexpected transformer on stored schema option.")
            }
            switch kind {
            case "unique": return .unique
            case "externalStorage": return .externalStorage
            case "encrypt": return .encrypt
            case "preserveValueOnDeletion": return .preserveValueOnDeletion
            case "spotlight": return .spotlight
            case "allowsCloudEncryption": return .allowsCloudEncryption
            case "ephemeral": return .ephemeral
            case "codable": return .codable
            case "flattened": return .flattened
            default: throw SwiftDataError.migrationUnsupported("Unknown schema option.")
            }
        }
    }

    private struct DescriptionRelationship: Codable {
        var name: String
        var destination: String
        var isToMany: Bool
        var deleteRule: String
        var inverse: String?
        var minimumModelCount: Int?
        var maximumModelCount: Int?
        var originalName: String?
        var declaringEntityName: String?

        init(_ relationship: Schema.Relationship) {
            name = relationship.name
            destination = relationship.destination
            isToMany = relationship.isToMany
            deleteRule = relationship.deleteRule.rawValue
            inverse = relationship.inverse
            minimumModelCount = relationship.minimumModelCount
            maximumModelCount = relationship.maximumModelCount
            originalName = relationship.originalName
            declaringEntityName = relationship.declaringEntityName
        }

        func schemaRelationship() throws -> Schema.Relationship {
            guard let rule = Schema.Relationship.DeleteRule(canonicalName: deleteRule) else {
                throw SwiftDataError.migrationUnsupported("Invalid stored relationship delete rule.")
            }
            return Schema.Relationship(
                name: name, destination: destination, isToMany: isToMany, inverse: inverse, deleteRule: rule,
                minimumModelCount: minimumModelCount, maximumModelCount: maximumModelCount,
                originalName: originalName, declaringEntityName: declaringEntityName)
        }
    }

    private struct DescriptionIndex: Codable {
        var isUnique: Bool
        var properties: [String]

        init(_ index: Schema.Index) {
            isUnique = index.isUnique
            properties = index.properties
        }
    }
}

private extension Schema.Attribute.Option {
    var canonicalName: String {
        switch self {
        case .unique: "unique"
        case .externalStorage: "externalStorage"
        case .encrypt: "encrypt"
        case .preserveValueOnDeletion: "preserveValueOnDeletion"
        case .spotlight: "spotlight"
        case let .transformable(by): "transformable:\(by)"
        case .allowsCloudEncryption: "allowsCloudEncryption"
        case .ephemeral: "ephemeral"
        case .codable: "codable"
        case .flattened: "flattened"
        }
    }
}

private extension Schema.Relationship.DeleteRule {
    var rawValue: String {
        switch self {
        case .nullify: "nullify"
        case .cascade: "cascade"
        case .deny: "deny"
        case .noAction: "noAction"
        }
    }
}

private extension Schema.Relationship.DeleteRule {
    init?(canonicalName: String) {
        switch canonicalName {
        case "nullify": self = .nullify
        case "cascade": self = .cascade
        case "deny": self = .deny
        case "noAction": self = .noAction
        default: return nil
        }
    }
}

package enum SHA256 {
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    package static func hash(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var state = initial
        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] =
                    (UInt32(message[start]) << 24) | (UInt32(message[start + 1]) << 16)
                    | (UInt32(message[start + 2]) << 8) | UInt32(message[start + 3])
            }
            for index in 16..<64 {
                let x = words[index - 15]
                let y = words[index - 2]
                let sigma0 = rotateRight(x, by: 7) ^ rotateRight(x, by: 18) ^ (x >> 3)
                let sigma1 = rotateRight(y, by: 17) ^ rotateRight(y, by: 19) ^ (y >> 10)
                words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]
            for index in 0..<64 {
                let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
                let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            state[0] &+= a
            state[1] &+= b
            state[2] &+= c
            state[3] &+= d
            state[4] &+= e
            state[5] &+= f
            state[6] &+= g
            state[7] &+= h
        }
        return state.flatMap { word in
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) }
        }
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
