import ParityContracts

// Fixed vocabularies for the API-surface coverage validator.

/// The `Name_Stoplist`: display names too generic for unqualified `name-match`
/// coverage. A reference to a stoplisted name is recorded only when the file
/// imports a SwiftData-family module or the reference is a member access whose
/// receiver is named like a known SwiftData type (see `ReferenceScanner`).
public enum NameStoplist {
    public static let entries: Set<String> = [
        "init", "deinit", "id", "hashValue", "description", "debugDescription",
        "rawValue", "encode", "decode", "hash", "save", "fetch", "delete",
        "name", "url", "count", "insert", "rollback", "erase",
    ]
}

/// The `Permitted_Reason_Categories`: the fixed set of strings allowed as
/// `reasonCategory` in the API coverage allowlist. The first six are reused
/// from `CoverageMatrixValidator.permittedReasons`; the last two cover
/// SwiftUI-only bindings and platform-specific integration points that
/// OpenSwiftData does not target.
public enum PermittedReasonCategories {
    public static let all: Set<String> = CoverageMatrixValidator.permittedReasons.union([
        "swiftui-only-api", "platform-integration-api",
    ])
}
