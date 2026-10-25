import Foundation
import OSDCore

package enum SQLColumnType: String, Sendable {
    case integer = "INTEGER"
    case float = "FLOAT"
    case timestamp = "TIMESTAMP"
    case varchar = "VARCHAR"
    case blob = "BLOB"

    package static func resolve(
        _ typeName: String,
        property: String,
        options: Set<Schema.Attribute.Option> = []
    ) throws -> SQLColumnType {
        if options.contains(where: { if case .transformable = $0 { true } else { false } }) {
            return .blob
        }
        let trimmed = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: Substring
        if trimmed.hasSuffix("?") {
            let rawBase = trimmed.dropLast()
            let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.hasSuffix("?"), !base.isEmpty else {
                throw SwiftDataError.unsupportedSchemaProperty(
                    "Property '\(property)' has unsupported SQL column type '\(typeName)'."
                )
            }
            normalized = Substring(base)
        } else {
            normalized = Substring(trimmed)
        }
        switch normalized {
        case "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool":
            return .integer
        case "Float", "Double":
            return .float
        case "Date":
            return .timestamp
        case "String":
            return .varchar
        case "UUID", "Data":
            return .blob
        default:
            throw SwiftDataError.unsupportedSchemaProperty(
                "Property '\(property)' has unsupported SQL column type '\(typeName)'."
            )
        }
    }
}
