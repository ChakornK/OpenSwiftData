import Foundation
import CryptoKit
import ParityContracts

// Data models for the API-surface coverage validator. All public types are
// Sendable so they can cross the (potential) actor boundaries between the
// orchestrator and the runtime components.

/// The kind of a public SwiftData API symbol, matching the `kind` strings
/// required by Requirement 3.4. `associatedtype`, `macro`, and `case` are
/// Swift keywords and must be backticked.
public enum SymbolKind: String, Codable, Sendable, Equatable, Hashable {
    case structKind = "struct"
    case classKind = "class"
    case enumKind = "enum"
    case protocolKind = "protocol"
    case actorKind = "actor"
    case typealiasKind = "typealias"
    case function
    case initializer
    case variable
    case subscriptKind = "subscript"
    case `associatedtype` = "associatedtype"
    case `macro` = "macro"
    case `case` = "case"
}

/// A single public declaration in the SwiftData API surface.
public struct API_Symbol: Codable, Equatable, Sendable {
    public let kind: SymbolKind
    public let displayName: String
    public let fullyQualifiedName: String
    public let sourceSignature: String
    public let platformAvailability: PlatformAvailability
    public let arity: Int
    public var mangledName: String
    public let deprecated: Bool

    public init(
        kind: SymbolKind,
        displayName: String,
        fullyQualifiedName: String,
        sourceSignature: String,
        platformAvailability: PlatformAvailability,
        arity: Int,
        mangledName: String = "",
        deprecated: Bool
    ) {
        self.kind = kind
        self.displayName = displayName
        self.fullyQualifiedName = fullyQualifiedName
        self.sourceSignature = sourceSignature
        self.platformAvailability = platformAvailability
        self.arity = arity
        self.mangledName = mangledName
        self.deprecated = deprecated
    }
}

/// Parsed `@available(...)` record. Version strings, when present, match
/// `^\d+(\.\d+)?$`. The extractor normalizes bare majors to `major.0`.
public struct PlatformAvailability: Codable, Equatable, Sendable {
    public let macOS: String?
    public let iOS: String?
    public let tvOS: String?
    public let watchOS: String?
    public let visionOS: String?
    public let unavailable: Bool
    public let deprecated: Bool

    public init(
        macOS: String? = nil,
        iOS: String? = nil,
        tvOS: String? = nil,
        watchOS: String? = nil,
        visionOS: String? = nil,
        unavailable: Bool = false,
        deprecated: Bool = false
    ) {
        self.macOS = macOS
        self.iOS = iOS
        self.tvOS = tvOS
        self.watchOS = watchOS
        self.visionOS = visionOS
        self.unavailable = unavailable
        self.deprecated = deprecated
    }

    /// The set of platforms that have an explicit version or unavailability.
    public var mentionedPlatforms: [String] {
        var result: [String] = []
        if macOS != nil { result.append("macOS") }
        if iOS != nil { result.append("iOS") }
        if tvOS != nil { result.append("tvOS") }
        if watchOS != nil { result.append("watchOS") }
        if visionOS != nil { result.append("visionOS") }
        return result
    }
}

/// A syntactic occurrence in a scanned source file that names an `API_Symbol`.
/// The custom `Codable` omits `displayName` from the report JSON per
/// Requirement 3.4; `displayName` is kept in memory for matching.
public struct Reference: Codable, Equatable, Sendable {
    public let file: String
    public let line: Int
    public let column: Int
    public let displayName: String
    public var matchQuality: MatchQuality

    public enum MatchQuality: String, Codable, Sendable, Equatable {
        case name
        case nameContext = "name-context"
        case signature
        case signatureAmbiguous = "signature-ambiguous"
    }

    public init(file: String, line: Int, column: Int, displayName: String, matchQuality: MatchQuality) {
        self.file = file
        self.line = line
        self.column = column
        self.displayName = displayName
        self.matchQuality = matchQuality
    }

    private enum ReportCodingKeys: String, CodingKey {
        case file, line, column, matchQuality
    }

    private enum FullCodingKeys: String, CodingKey {
        case file, line, column, displayName, matchQuality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FullCodingKeys.self)
        self.file = try c.decode(String.self, forKey: .file)
        self.line = try c.decode(Int.self, forKey: .line)
        self.column = try c.decode(Int.self, forKey: .column)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.matchQuality = try c.decode(MatchQuality.self, forKey: .matchQuality)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ReportCodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encode(line, forKey: .line)
        try c.encode(column, forKey: .column)
        try c.encode(matchQuality, forKey: .matchQuality)
    }
}

/// A single entry in the API coverage allowlist. `issueURL` is a `String` to
/// preserve placeholder bytes for the human editor; validation parses it with
/// `URL(string:)` and checks `scheme == "https"`.
public struct AllowlistEntry: Codable, Equatable, Sendable {
    public let fullyQualifiedName: String
    public let kind: String?
    public let reasonCategory: String
    public let rationale: String
    public let issueURL: String
    public let expiration: String

    public init(
        fullyQualifiedName: String,
        kind: String?,
        reasonCategory: String,
        rationale: String,
        issueURL: String,
        expiration: String
    ) {
        self.fullyQualifiedName = fullyQualifiedName
        self.kind = kind
        self.reasonCategory = reasonCategory
        self.rationale = rationale
        self.issueURL = issueURL
        self.expiration = expiration
    }
}

/// Fingerprint of the macOS SDK the report was produced against.
public struct SDKFingerprint: Codable, Equatable, Sendable {
    public let sdkPath: String
    public let swiftInterfaceSHA256: String
    public let swiftInterfaceByteCount: Int

    public init(sdkPath: String, swiftInterfaceSHA256: String, swiftInterfaceByteCount: Int) {
        self.sdkPath = sdkPath
        self.swiftInterfaceSHA256 = swiftInterfaceSHA256
        self.swiftInterfaceByteCount = swiftInterfaceByteCount
    }
}

/// A symbol's coverage record in the report. `kind` is the `SymbolKind.rawValue`
/// string per Requirement 3.4. Allowlist fields are populated by
/// `AllowlistValidator`; `CoverageEngine` emits them as `false`/`nil`.
public struct SymbolRecord: Codable, Equatable, Sendable {
    public let kind: String
    public let displayName: String
    public let fullyQualifiedName: String
    public let sourceSignature: String
    public let platformAvailability: PlatformAvailability
    public let covered: Bool
    public let referenceCount: Int
    public let references: [Reference]
    public let allowlisted: Bool
    public let allowlistReasonCategory: String?
    public let allowlistRationale: String?
    public let allowlistIssueURL: String?
    public let mangledName: String

    public init(
        kind: String,
        displayName: String,
        fullyQualifiedName: String,
        sourceSignature: String,
        platformAvailability: PlatformAvailability,
        covered: Bool,
        referenceCount: Int,
        references: [Reference],
        allowlisted: Bool = false,
        allowlistReasonCategory: String? = nil,
        allowlistRationale: String? = nil,
        allowlistIssueURL: String? = nil,
        mangledName: String
    ) {
        self.kind = kind
        self.displayName = displayName
        self.fullyQualifiedName = fullyQualifiedName
        self.sourceSignature = sourceSignature
        self.platformAvailability = platformAvailability
        self.covered = covered
        self.referenceCount = referenceCount
        self.references = references
        self.allowlisted = allowlisted
        self.allowlistReasonCategory = allowlistReasonCategory
        self.allowlistRationale = allowlistRationale
        self.allowlistIssueURL = allowlistIssueURL
        self.mangledName = mangledName
    }
}

/// The top-level API coverage report emitted by the validator.
public struct APICoverageReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let strategy: String
    public let sdkFingerprint: SDKFingerprint
    public let evaluationDate: String
    public let generatedAt: String
    public let totalSymbolCount: Int
    public let coveredSymbolCount: Int
    public let uncoveredSymbolCount: Int
    public let excludedSymbolCount: Int
    public let coverageValid: Bool
    public let allowlistSHA256: String
    public let validationIssues: [String]
    public let symbols: [SymbolRecord]

    public init(
        schemaVersion: Int,
        strategy: String,
        sdkFingerprint: SDKFingerprint,
        evaluationDate: String,
        generatedAt: String,
        totalSymbolCount: Int,
        coveredSymbolCount: Int,
        uncoveredSymbolCount: Int,
        excludedSymbolCount: Int,
        coverageValid: Bool,
        allowlistSHA256: String,
        validationIssues: [String],
        symbols: [SymbolRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.strategy = strategy
        self.sdkFingerprint = sdkFingerprint
        self.evaluationDate = evaluationDate
        self.generatedAt = generatedAt
        self.totalSymbolCount = totalSymbolCount
        self.coveredSymbolCount = coveredSymbolCount
        self.uncoveredSymbolCount = uncoveredSymbolCount
        self.excludedSymbolCount = excludedSymbolCount
        self.coverageValid = coverageValid
        self.allowlistSHA256 = allowlistSHA256
        self.validationIssues = validationIssues
        self.symbols = symbols
    }
}

/// Identity key for an `API_Symbol`, used to deduplicate by signature.
public struct API_SymbolIdentity: Hashable, Sendable {
    public let fullyQualifiedName: String
    public let kind: SymbolKind
    public let sourceSignature: String

    public init(fullyQualifiedName: String, kind: SymbolKind, sourceSignature: String) {
        self.fullyQualifiedName = fullyQualifiedName
        self.kind = kind
        self.sourceSignature = sourceSignature
    }
}

/// The extracted SwiftData API surface: non-excluded symbols plus precomputed
/// lookup indexes. Indexes are computed eagerly in `init` so they stay in sync
/// with `symbols`. `symbolsByMangledName` starts empty and is populated by
/// `APISurfaceExtractor.joinSymbolGraph`.
public struct ExtractedSurface: Sendable {
    public let symbols: [API_Symbol]
    public let excludedCount: Int
    public let displayNames: Set<String>
    public let symbolsByDisplayName: [String: [API_Symbol]]
    public let symbolsByIdentity: [API_SymbolIdentity: API_Symbol]
    public var symbolsByMangledName: [String: API_Symbol]

    public init(symbols: [API_Symbol], excludedCount: Int) {
        self.symbols = symbols
        self.excludedCount = excludedCount
        self.displayNames = Set(symbols.map(\.displayName))
        self.symbolsByDisplayName = Dictionary(grouping: symbols, by: \.displayName)
        self.symbolsByIdentity = Dictionary(uniqueKeysWithValues: symbols.map {
            (API_SymbolIdentity(fullyQualifiedName: $0.fullyQualifiedName, kind: $0.kind, sourceSignature: $0.sourceSignature), $0)
        })
        self.symbolsByMangledName = [:]
    }
}

/// The symbol-match strategy, selectable via `--strategy`.
public enum Strategy: String, Sendable, Equatable {
    case nameMatch = "name-match"
    case signaturePrecise = "signature-precise"
}

/// The UTC calendar date against which allowlist expirations are compared.
/// Carries both the `gregorianDay` string and the `foundationDate` (GMT
/// start-of-day) used for inclusive `>=` comparisons.
public struct EvaluationDate: Sendable, Equatable {
    public let gregorianDay: String
    public let foundationDate: Date

    /// Parses and validates a `YYYY-MM-DD` string. Throws on regex mismatch or
    /// an invalid calendar date (e.g. `2026-02-31`). Uses `isLenient = false`
    /// so the formatter rejects nonexistent days.
    public init(gregorianDay: String) throws {
        let dayRegex = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        guard dayRegex.firstMatch(in: gregorianDay, range: NSRange(gregorianDay.startIndex..., in: gregorianDay)) != nil else {
            throw EvaluationDateError.invalidFormat(gregorianDay)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: gregorianDay) else {
            throw EvaluationDateError.invalidCalendarDate(gregorianDay)
        }
        self.gregorianDay = gregorianDay
        self.foundationDate = date
    }

    /// Derives the GMT start-of-day for the given `Date`.
    public init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startOfDay = calendar.startOfDay(for: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        self.gregorianDay = formatter.string(from: startOfDay)
        self.foundationDate = startOfDay
    }
}

public enum EvaluationDateError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidFormat(String)
    case invalidCalendarDate(String)

    public var description: String {
        switch self {
        case let .invalidFormat(value): "invalid evaluation date format: \(value)"
        case let .invalidCalendarDate(value): "invalid calendar date: \(value)"
        }
    }
}

/// Resolved filesystem locations and fingerprints for a validator run.
public struct ResolvedPaths: Sendable {
    public let repositoryRoot: URL
    public let paritySourceDirectory: URL
    public let implementationDirectories: [URL]
    public let allowlistURL: URL
    public let reportURL: URL
    public let swiftInterfaceURL: URL
    public let sdkRoot: URL
    public let sdkFingerprint: SDKFingerprint
    public let evaluationDate: EvaluationDate
    public let strategy: Strategy

    public init(
        repositoryRoot: URL,
        paritySourceDirectory: URL,
        implementationDirectories: [URL],
        allowlistURL: URL,
        reportURL: URL,
        swiftInterfaceURL: URL,
        sdkRoot: URL,
        sdkFingerprint: SDKFingerprint,
        evaluationDate: EvaluationDate,
        strategy: Strategy
    ) {
        self.repositoryRoot = repositoryRoot
        self.paritySourceDirectory = paritySourceDirectory
        self.implementationDirectories = implementationDirectories
        self.allowlistURL = allowlistURL
        self.reportURL = reportURL
        self.swiftInterfaceURL = swiftInterfaceURL
        self.sdkRoot = sdkRoot
        self.sdkFingerprint = sdkFingerprint
        self.evaluationDate = evaluationDate
        self.strategy = strategy
    }
}

/// Context for a containing type while walking the `.swiftinterface`. The
/// visitor merges availability across the stack to compute each symbol's
/// effective `PlatformAvailability`.
public struct TypeContext: Sendable, Equatable {
    public let fullyQualifiedName: String
    public let kind: SymbolKind
    public let availability: PlatformAvailability

    public init(fullyQualifiedName: String, kind: SymbolKind, availability: PlatformAvailability) {
        self.fullyQualifiedName = fullyQualifiedName
        self.kind = kind
        self.availability = availability
    }
}

/// The coverage computation result. `symbols` carries `SymbolRecord`s with
/// allowlist fields all `false`/`nil`; `AllowlistValidator` rebuilds them with
/// allowlist fields populated. `surface` is retained for stale-entry checks.
public struct CoverageResult: Sendable {
    public let symbols: [SymbolRecord]
    public let coveredSymbolCount: Int
    public let uncoveredSymbolCount: Int
    public let excludedCount: Int
    public let surface: ExtractedSurface

    public init(
        symbols: [SymbolRecord],
        coveredSymbolCount: Int,
        uncoveredSymbolCount: Int,
        excludedCount: Int,
        surface: ExtractedSurface
    ) {
        self.symbols = symbols
        self.coveredSymbolCount = coveredSymbolCount
        self.uncoveredSymbolCount = uncoveredSymbolCount
        self.excludedCount = excludedCount
        self.surface = surface
    }
}

/// The allowlist validation result. `annotatedSymbols` are rebuilt with
/// allowlist fields populated for matching uncovered symbols.
public struct AllowlistValidation: Sendable {
    public let annotatedSymbols: [SymbolRecord]
    public let validationIssues: [String]
    public let valid: Bool

    public init(annotatedSymbols: [SymbolRecord], validationIssues: [String], valid: Bool) {
        self.annotatedSymbols = annotatedSymbols
        self.validationIssues = validationIssues
        self.valid = valid
    }
}

/// Allowlist annotation applied to a matching uncovered symbol.
public struct AllowlistAnnotation: Sendable, Equatable {
    public let reasonCategory: String
    public let rationale: String
    public let issueURL: String

    public init(reasonCategory: String, rationale: String, issueURL: String) {
        self.reasonCategory = reasonCategory
        self.rationale = rationale
        self.issueURL = issueURL
    }
}

/// SHA-256 hashing helper. Lowercase hex digest, accessible from any target
/// that imports this module.
public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
