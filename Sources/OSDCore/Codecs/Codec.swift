import Foundation

private protocol OptionalCodable {
    static func encodeOptional(_ value: Any) throws -> StoredValue
    static func decodeOptional(from storedValue: StoredValue) throws -> Any
}

extension Optional: OptionalCodable where Wrapped: Codable {
    static func encodeOptional(_ value: Any) throws -> StoredValue {
        guard let optional = value as? Self else { throw CodecError.invalidRepresentation }
        guard let wrapped = optional else { return .null }
        return try Codec.encode(wrapped)
    }

    static func decodeOptional(from storedValue: StoredValue) throws -> Any {
        guard case .null = storedValue else {
            return (try Codec.decode(Wrapped.self, from: storedValue) as Wrapped?) as Any
        }
        return Optional<Wrapped>.none as Any
    }
}

internal enum Codec {
    static func encode<T: Encodable>(_ value: T) throws -> StoredValue {
        if let optionalType = T.self as? any OptionalCodable.Type {
            return try optionalType.encodeOptional(value)
        }
        if let value = value as? Bool { return .int(value ? 1 : 0) }
        if let value = value as? UUID {
            return .blob(withUnsafeBytes(of: value.uuid) { Array($0) })
        }
        if let value = value as? Date { return .double(value.timeIntervalSinceReferenceDate) }
        if let value = value as? Float { return .double(Double(value)) }
        if let value = value as? Double { return .double(value) }
        if let value = value as? URL { return .text(value.absoluteString) }
        if let value = value as? Decimal { return .text(value.description) }
        if let value = value as? String { return .text(value) }
        if let value = value as? Data { return .blob(Array(value)) }
        if let value = value as? Int { return .int(Int64(value)) }
        if let value = value as? Int8 { return .int(Int64(value)) }
        if let value = value as? Int16 { return .int(Int64(value)) }
        if let value = value as? Int32 { return .int(Int64(value)) }
        if let value = value as? Int64 { return .int(value) }
        if let value = value as? UInt { return .int(try signedInteger(value)) }
        if let value = value as? UInt8 { return .int(Int64(value)) }
        if let value = value as? UInt16 { return .int(Int64(value)) }
        if let value = value as? UInt32 { return .int(Int64(value)) }
        if let value = value as? UInt64 { return .int(try signedInteger(value)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .blob(Array(try encoder.encode(value)))
    }

    static func decode<T: Decodable>(_ type: T.Type, from storedValue: StoredValue) throws -> T {
        if let optionalType = type as? any OptionalCodable.Type {
            guard let value = try optionalType.decodeOptional(from: storedValue) as? T else {
                throw CodecError.invalidRepresentation
            }
            return value
        }
        if type == Bool.self { return try cast(decodeBool(from: storedValue)) }
        if type == UUID.self { return try cast(decodeUUID(from: storedValue)) }
        if type == Date.self { return try cast(decodeDate(from: storedValue)) }
        if type == Float.self { return try cast(decodeFloat(from: storedValue)) }
        if type == Double.self { return try cast(decodeDouble(from: storedValue)) }
        if type == URL.self { return try cast(decodeURL(from: storedValue)) }
        if type == Decimal.self { return try cast(decodeDecimal(from: storedValue)) }
        if type == String.self { return try cast(decodeString(from: storedValue)) }
        if type == Data.self { return try cast(decodeData(from: storedValue)) }
        if isIntegerType(type) { return try decodeInteger(type, from: storedValue) }
        guard case let .blob(bytes) = storedValue else { throw CodecError.invalidRepresentation }
        return try JSONDecoder().decode(type, from: Data(bytes))
    }

    private static func cast<T>(_ value: Any) throws -> T {
        guard let value = value as? T else { throw CodecError.invalidRepresentation }
        return value
    }

    private static func decodeBool(from value: StoredValue) throws -> Bool {
        guard case let .int(integer) = value else { throw CodecError.invalidRepresentation }
        return integer != 0
    }

    private static func decodeUUID(from value: StoredValue) throws -> UUID {
        guard case let .blob(bytes) = value, bytes.count == 16 else { throw CodecError.invalidRepresentation }
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private static func decodeDate(from value: StoredValue) throws -> Date {
        switch value {
        case let .double(interval): Date(timeIntervalSinceReferenceDate: interval)
        case let .int(interval): Date(timeIntervalSinceReferenceDate: Double(interval))
        default: throw CodecError.invalidRepresentation
        }
    }

    private static func decodeFloat(from value: StoredValue) throws -> Float {
        guard case let .double(number) = value else { throw CodecError.invalidRepresentation }
        return Float(number)
    }

    private static func decodeDouble(from value: StoredValue) throws -> Double {
        guard case let .double(number) = value else { throw CodecError.invalidRepresentation }
        return number
    }

    private static func decodeURL(from value: StoredValue) throws -> URL {
        guard case let .text(string) = value, let url = URL(string: string) else {
            throw CodecError.invalidRepresentation
        }
        return url
    }

    private static func decodeDecimal(from value: StoredValue) throws -> Decimal {
        guard case let .text(string) = value,
            let decimal = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
        else {
            throw CodecError.invalidRepresentation
        }
        return decimal
    }

    private static func decodeString(from value: StoredValue) throws -> String {
        guard case let .text(string) = value else { throw CodecError.invalidRepresentation }
        return string
    }

    private static func decodeData(from value: StoredValue) throws -> Data {
        guard case let .blob(bytes) = value else { throw CodecError.invalidRepresentation }
        return Data(bytes)
    }

    private static func isIntegerType<T>(_ type: T.Type) -> Bool {
        type == Int.self || type == Int8.self || type == Int16.self || type == Int32.self || type == Int64.self
            || type == UInt.self || type == UInt8.self || type == UInt16.self || type == UInt32.self
            || type == UInt64.self
    }

    private static func decodeInteger<T: Decodable>(_ type: T.Type, from value: StoredValue) throws -> T {
        guard case let .int(integer) = value else { throw CodecError.invalidRepresentation }
        if type == Int.self, let result = Int(exactly: integer) { return try cast(result) }
        if type == Int8.self, let result = Int8(exactly: integer) { return try cast(result) }
        if type == Int16.self, let result = Int16(exactly: integer) { return try cast(result) }
        if type == Int32.self, let result = Int32(exactly: integer) { return try cast(result) }
        if type == Int64.self { return try cast(integer) }
        if type == UInt.self, let result = UInt(exactly: integer) { return try cast(result) }
        if type == UInt8.self, let result = UInt8(exactly: integer) { return try cast(result) }
        if type == UInt16.self, let result = UInt16(exactly: integer) { return try cast(result) }
        if type == UInt32.self, let result = UInt32(exactly: integer) { return try cast(result) }
        if type == UInt64.self, let result = UInt64(exactly: integer) { return try cast(result) }
        throw CodecError.integerOutOfRange
    }

    private static func signedInteger<T: BinaryInteger>(_ value: T) throws -> Int64 {
        guard let result = Int64(exactly: value) else { throw CodecError.integerOutOfRange }
        return result
    }
}

internal enum CodecError: Error {
    case invalidRepresentation
    case integerOutOfRange
}
