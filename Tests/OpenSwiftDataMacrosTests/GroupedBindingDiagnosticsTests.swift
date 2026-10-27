@testable import OpenSwiftDataMacros
import SwiftDiagnostics
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class GroupedBindingDiagnosticsTests: XCTestCase {
    func testModelAccessorMarkerSeparatesScalarAndRelationshipProperties() {
        assertMacroExpansion(
            #"""
            @Model final class Example {
                var title: String
                @Relationship var pets: [Pet]
            }
            """#,
            expandedSource: #"""
                final class Example {
                    var title: String {
                        @storageRestrictions(accesses: _$backingData, initializes: _title)
                        init(initialValue) {
                            _$backingData.setValue(forKey: \.title, to: initialValue)
                            _title = _SwiftDataNoType()
                        }
                        get {
                            access(keyPath: \.title)
                            return self.getValue(forKey: \.title)
                        }
                        set {
                            withMutation(keyPath: \.title) {
                                self.setValue(forKey: \.title, to: newValue)
                            }
                        }
                    }

                    @Transient
                    private var _title: _SwiftDataNoType = _SwiftDataNoType()
                    @Relationship
                    var pets: [Pet] {
                        @storageRestrictions(accesses: _$backingData, initializes: _pets)
                        init(initialValue) {
                            _$backingData.setValue(forKey: \.pets, to: initialValue)
                            _pets = _SwiftDataNoType()
                        }
                        get {
                            access(keyPath: \.pets)
                            return self.getValue(forKey: \.pets)
                        }
                        set {
                            withMutation(keyPath: \.pets) {
                                self.setRelationshipValue(forKey: \.pets, to: newValue)
                            }
                        }
                    }

                    @Transient
                    private var _pets: _SwiftDataNoType = _SwiftDataNoType()

                    @Transient
                    private var _$backingData: any BackingData<Example> = Example.createBackingData()

                    public var persistentBackingData: any BackingData<Example> {
                        get {
                            _$backingData
                        }
                        set {
                            _$backingData = newValue
                        }
                    }

                    public static func schemaMetadata() -> [Schema.PropertyMetadata] {
                        return [
                            Schema.PropertyMetadata(name: "title", keypath: \Example.title, defaultValue: nil, metadata: nil, isExplicitRelationship: false),
                            Schema.PropertyMetadata(name: "pets", keypath: \Example.pets, defaultValue: nil, metadata: nil, isExplicitRelationship: true)
                        ]
                    }

                    public static func persistenceAdapters() -> [any PersistencePropertyAdapter<Example>] {
                        [
                            TypedPropertyAdapter<Example, String>("title", keyPath: \Example.title, encode: { model in
                                    try PersistentValue.encode(model.title)
                                }, decode: { value, model in
                                    model.title = try PersistentValue.decode(String.self, from: value)
                                }, decodeValue: { value in
                                    (try PersistentValue.decode(String.self, from: value)) as Any
                                })
                        ]
                    }

                    public static func relationshipAdapterCandidates() -> [any AnyRelationshipAdapterBox] {
                        [
                            RelationshipAdapterBox<Example>(TypedRelationshipPropertyAdapter<Example, [Pet], Pet>("pets", keyPath: \Example.pets, read: { model in
                                        model.pets
                                    }, endpoints: { value in
                                        value
                                    }, build: { endpoints in
                                        [Pet](endpoints)
                                    }, inverseBuild: { endpoints in
                                        endpoints
                                    }, isToMany: true))
                        ]
                    }

                    public static func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox] {
                        relationshipAdapterCandidates() + inferredRelationshipAdapterCandidates()
                    }

                    public init(backingData: any BackingData<Example>) {
                        _$backingData = backingData
                    }

                    @Transient
                    private let _$observationRegistrar = Observation.ObservationRegistrar()

                    internal nonisolated func access<_M>(keyPath: KeyPath<Example, _M>) {
                        _$observationRegistrar.access(self, keyPath: keyPath)
                    }

                    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<Example, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {
                        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
                    }

                    struct _SwiftDataNoType {
                    }
                }

                extension Example: PersistentModel {
                }

                extension Example: RelationshipModel {
                }

                extension Example: Observation.Observable {
                }

                extension Example: @unchecked Sendable {
                }
                """#,
            macros: ["Model": ModelMacro.self, "_PersistedProperty": PersistedPropertyMacro.self]
        )
    }

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

                    public static func relationshipAdapterCandidatesForMutation() -> [any AnyRelationshipAdapterBox] {
                        relationshipAdapterCandidates() + inferredRelationshipAdapterCandidates()
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
