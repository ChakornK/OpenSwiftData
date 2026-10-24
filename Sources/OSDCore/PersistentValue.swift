import Foundation

/// Encodes Swift values into SQLite-compatible storage values.
///
/// Unsupported representations and values that cannot fit SQLite's signed 64-bit integer
/// storage throw an error rather than trapping or silently coercing the value.
public enum PersistentValue {
    /// Encodes a value using the codec for its Swift type.
    ///
    /// - Throws: `CodecError.integerOutOfRange` when an unsigned integer exceeds `Int64.max`,
    ///   or an encoder error if a Codable value cannot be encoded.
    public static func encode<T: RawRepresentable & Encodable>(_ value: T) throws -> StoredValue
    where T.RawValue: Encodable {
        try Codec.encode(value.rawValue)
    }

    /// Encodes a value using the codec for its Swift type.
    ///
    /// - Throws: `CodecError.integerOutOfRange` when an unsigned integer exceeds `Int64.max`,
    ///   or an encoder error if a Codable value cannot be encoded.
    public static func encode<T: Encodable>(_ value: T) throws -> StoredValue {
        try Codec.encode(value)
    }

    /// Decodes a storage value using the codec for the requested Swift type.
    ///
    /// - Throws: `CodecError.invalidRepresentation` when the stored value does not match the
    ///   requested type, `CodecError.integerOutOfRange` when an integer cannot fit the requested
    ///   integer type, or a decoder error if a Codable payload cannot be decoded.
    public static func decode<T: RawRepresentable & Decodable>(
        _ type: T.Type,
        from storedValue: StoredValue
    ) throws -> T where T.RawValue: Decodable {
        let rawValue = try Codec.decode(T.RawValue.self, from: storedValue)
        guard let value = T(rawValue: rawValue) else { throw CodecError.invalidRepresentation }
        return value
    }

    /// Decodes a storage value using the codec for the requested Swift type.
    ///
    /// - Throws: `CodecError.invalidRepresentation` when the stored value does not match the
    ///   requested type, `CodecError.integerOutOfRange` when an integer cannot fit the requested
    ///   integer type, or a decoder error if a Codable payload cannot be decoded.
    public static func decode<T: Decodable>(_ type: T.Type, from storedValue: StoredValue) throws -> T {
        try Codec.decode(type, from: storedValue)
    }
}
