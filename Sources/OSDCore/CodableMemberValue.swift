import Foundation

/// Reads a member of a JSON-encoded Codable attribute as a predicate-comparable storage value.
package enum CodableMemberValue {
    /// Returns the value at `members` inside the JSON payload.
    ///
    /// Booleans become `0`/`1` integers, integral numbers become integers, and other numbers become
    /// doubles, which matches how scalar attributes are stored. Missing members, JSON `null`, and
    /// nested arrays or objects yield `.null`.
    package static func extract(from payload: [UInt8], members: [String]) -> StoredValue {
        guard var value = try? JSONDecoder().decode(JSONValue.self, from: Data(payload)) else { return .null }
        for member in members {
            guard case let .object(object) = value, let next = object[member] else { return .null }
            value = next
        }
        switch value {
        case let .bool(bool): return .int(bool ? 1 : 0)
        case let .integer(integer): return .int(integer)
        case let .double(double): return .double(double)
        case let .string(string): return .text(string)
        case .null, .array, .object: return .null
        }
    }

    private enum JSONValue: Decodable {
        case null
        case bool(Bool)
        case integer(Int64)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            // JSONDecoder refuses to read numbers as Bool and booleans as numbers, so this order is unambiguous.
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let integer = try? container.decode(Int64.self) {
                self = .integer(integer)
            } else if let double = try? container.decode(Double.self) {
                self = .double(double)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([JSONValue].self) {
                self = .array(array)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }
    }
}
