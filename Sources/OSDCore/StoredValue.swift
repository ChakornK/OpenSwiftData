/// A SQLite-compatible value used by the persistence core.
public enum StoredValue: Sendable, Equatable, Codable {
    /// Represents SQL NULL.
    case null
    /// Represents a signed 64-bit integer.
    case int(Int64)
    /// Represents a floating-point number.
    case double(Double)
    /// Represents text.
    case text(String)
    /// Represents binary data as bytes.
    case blob([UInt8])

    /// Encodes a value using the scalar representation used by persisted model properties.
    public init<T: Encodable>(predicateScalar value: T) throws {
        guard let encoded = try Codec.encodePredicateScalar(value) else {
            throw PredicateScalarEncodingError.unsupportedType(String(reflecting: T.self))
        }
        self = encoded
    }

    /// Encodes an erased scalar capture while preserving optional type metadata.
    public init(predicateScalar value: Any, type: Any.Type) throws {
        guard let encoded = try Codec.encodePredicateScalar(value, type: type) else {
            throw PredicateScalarEncodingError.unsupportedType(String(reflecting: type))
        }
        self = encoded
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum PayloadKeys: String, CodingKey {
        case int
        case double
        case text
        case blob
        case value
    }

    private struct IntPayload: Decodable {
        let value: Int64

        private enum CodingKeys: String, CodingKey {
            case value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(Int64.self, forKey: .value)
        }
    }

    private struct DoublePayload: Decodable {
        let value: Double

        private enum CodingKeys: String, CodingKey {
            case value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(Double.self, forKey: .value)
        }
    }

    private struct TextPayload: Decodable {
        let value: String

        private enum CodingKeys: String, CodingKey {
            case value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(String.self, forKey: .value)
        }
    }

    private struct BlobPayload: Decodable {
        let value: [UInt8]

        private enum CodingKeys: String, CodingKey {
            case value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode([UInt8].self, forKey: .value)
        }
    }

    private enum Kind: String, Codable {
        case null
        case int
        case double
        case text
        case blob
    }

    /// Decodes the tagged representation of a storage value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .null:
            self = .null
        case .int:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .int(try payload.decode(IntPayload.self, forKey: .int).value)
        case .double:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .double(try payload.decode(DoublePayload.self, forKey: .double).value)
        case .text:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .text(try payload.decode(TextPayload.self, forKey: .text).value)
        case .blob:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .blob(try payload.decode(BlobPayload.self, forKey: .blob).value)
        }
    }

    /// Encodes the value with a stable case tag and payload.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case let .int(value):
            try container.encode(Kind.int, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            var intPayload = payload.nestedContainer(keyedBy: PayloadKeys.self, forKey: .int)
            try intPayload.encode(value, forKey: .value)
        case let .double(value):
            try container.encode(Kind.double, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            var doublePayload = payload.nestedContainer(keyedBy: PayloadKeys.self, forKey: .double)
            try doublePayload.encode(value, forKey: .value)
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            var textPayload = payload.nestedContainer(keyedBy: PayloadKeys.self, forKey: .text)
            try textPayload.encode(value, forKey: .value)
        case let .blob(value):
            try container.encode(Kind.blob, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            var blobPayload = payload.nestedContainer(keyedBy: PayloadKeys.self, forKey: .blob)
            try blobPayload.encode(value, forKey: .value)
        }
    }
}

/// An unsupported type passed as a scalar predicate capture.
public enum PredicateScalarEncodingError: Error, Sendable, Equatable {
    /// The value is not encoded as a supported scalar by the persistence codec.
    case unsupportedType(String)
}
