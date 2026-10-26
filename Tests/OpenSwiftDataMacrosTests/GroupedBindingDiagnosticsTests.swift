@testable import OpenSwiftDataMacros
import SwiftDiagnostics
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class GroupedBindingDiagnosticsTests: XCTestCase {
    func testGroupedBindingsProduceOneErrorAtDeclarationLocation() {
        assertMacroExpansion(
            """
            @Model final class Grouped { var first, second: Int = 0 }
            """,
            expandedSource: """
                final class Grouped { var first, second: Int = 0\( " " )

                    @Transient
                    private var _$backingData: any BackingData<Grouped> = Grouped.createBackingData()

                    public var persistentBackingData: any BackingData<Grouped> {
                        get {
                            _$backingData
                        }
                        set {
                            _$backingData = newValue
                        }
                    }

                    public static func schemaMetadata() -> [Schema.PropertyMetadata] {
                        return []
                    }

                    public init(backingData: any BackingData<Grouped>) {
                        _$backingData = backingData
                    }

                    @Transient
                    private let _$observationRegistrar = Observation.ObservationRegistrar()

                    internal nonisolated func access<_M>(keyPath: KeyPath<Grouped, _M>) {
                        _$observationRegistrar.access(self, keyPath: keyPath)
                    }

                    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<Grouped, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {
                        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
                    }

                    struct _SwiftDataNoType {
                    }
                }

                extension Grouped: PersistentModel {
                }

                extension Grouped: RelationshipModel {
                }

                extension Grouped: Observation.Observable {
                }

                extension Grouped: @unchecked Sendable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Model does not support variable declarations with multiple bindings; split each property into its own declaration",
                    line: 1,
                    column: 30,
                    severity: .error
                )
            ],
            macros: ["Model": ModelMacro.self]
        )
    }
}
