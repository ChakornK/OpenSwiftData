/// Encodes Data values using the current store write's file transaction.
public struct ExternalDataWriteSession {
    private let externalizeBody: ([UInt8]) throws -> StoredValue

    /// Creates a write-scoped external Data encoder.
    public init(externalize: @escaping ([UInt8]) throws -> StoredValue) {
        externalizeBody = externalize
    }

    /// Returns an inline value or a store-managed sidecar reference.
    public func externalizedValue(_ bytes: [UInt8]) throws -> StoredValue {
        try externalizeBody(bytes)
    }
}
