import Foundation
import Observation
import XCTest
@testable import OpenSwiftData
import OSDTestSupport

private protocol MacroProtocolOnlyFixture: AnyObject {}
private protocol SecondMacroProtocolFixture: AnyObject {}

@Model(protocolConformancesOnly: true)
final class CodableMacroProtocolConformanceFixture: Codable {
    var value: Int

    init(value: Int) {
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case value
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Int.self, forKey: .value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

@Model(protocolConformancesOnly: true)
final class SingleMacroProtocolConformanceFixture: MacroProtocolOnlyFixture {
    var value: Int

    init(value: Int) {
        self.value = value
    }
}

@Model(protocolConformancesOnly: true)
final class MacroProtocolConformanceFixture: MacroProtocolOnlyFixture, SecondMacroProtocolFixture {
    var value: Int

    init(value: Int) {
        self.value = value
    }
}

@Model
final class MacroBackedFixture {
    var title: String
    var count: Int = 3
    var note: String?
    var defaultedNote: String? = "default"
    var explicitlyNil: String? = nil

    init(title: String) {
        self.title = title
    }
}

@Model
final class GroupedBindingFixture {
    var first: Int = 0
    var second: Int = 0

    init() {
        self.first = 0
        self.second = 0
    }
}

@Model
final class UnassignedPropertyFixture {
    var title: String

    init() {}
}

@Model
final class BackingDataDefaultsFixture {
    var count: Int = 5
    var optionalDefault: String? = "default"
    var explicitlyNil: String? = nil

}

@Model
class InheritanceMacroBaseFixture {
    var name: String
    init(name: String) { self.name = name }

}

@Model
class InheritanceMacroChildFixture: InheritanceMacroBaseFixture {
    var age: Int
    init(name: String, age: Int) {
        self.age = age
        super.init(name: name)
    }
}

@Model
final class InheritanceMacroGrandchildFixture: InheritanceMacroChildFixture {
    var rank: Int
    init(name: String, age: Int, rank: Int) {
        self.rank = rank
        super.init(name: name, age: age)
    }
}

@Model
final class InheritanceMacroAardvarkFixture: InheritanceMacroBaseFixture {
    var color: String?

    init(name: String, color: String?) {
        self.color = color
        super.init(name: name)
    }
}

@Model
final class InheritanceMacroPuppyFixture: InheritanceMacroChildFixture {
    var collar: String?

    init(name: String, age: Int, collar: String?) {
        self.collar = collar
        super.init(name: name, age: age)
    }
}

@Model
final class InheritanceMacroKittenFixture: InheritanceMacroBaseFixture {
    var rank: Int = 7

    override init(name: String) {
        super.init(name: name)
    }
}

@Model
final class InheritanceIdentifierOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var favorite: InheritanceMacroBaseFixture?

    init(name: String) { self.name = name }
}

@Model
final class IndependentRelationshipRootFixture {
    var name: String
    @Relationship(inverse: nil) var target: InheritedToOneMigrationTargetFixture?

    init(name: String, target: InheritedToOneMigrationTargetFixture?) {
        self.name = name
        self.target = target
    }
}

@Model
final class IndependentToManyRootFixture {
    var name: String
    @Relationship(inverse: nil) var items: [ToManyHierarchyTargetChildFixture]

    init(name: String, items: [ToManyHierarchyTargetChildFixture]) {
        self.name = name
        self.items = items
    }
}

@Model
class MigratedTreeRootFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class MigratedTreeLeafFixture: MigratedTreeRootFixture {
    var label: String?
    @Relationship(inverse: nil) var target: InheritedToOneMigrationTargetFixture?

    init(name: String, label: String?, target: InheritedToOneMigrationTargetFixture?) {
        self.label = label
        self.target = target
        super.init(name: name)
    }
}

@Model
class InheritedToOneMigrationBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InheritedToOneMigrationTargetFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
final class InheritedToOneMigrationChildFixture: InheritedToOneMigrationBaseFixture {
    @Relationship(inverse: nil) var target: InheritedToOneMigrationTargetFixture?

    init(name: String, target: InheritedToOneMigrationTargetFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
final class InheritedToManyMigrationItemFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
final class InheritedToManyMigrationChildFixture: InheritanceMacroBaseFixture {
    @Relationship(inverse: nil) var items: [InheritedToManyMigrationItemFixture]

    init(name: String, items: [InheritedToManyMigrationItemFixture]) {
        self.items = items
        super.init(name: name)
    }
}

@Model
final class InverseMigrationOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var target: InverseMigrationTargetBaseFixture?

    init(name: String, target: InverseMigrationTargetBaseFixture?) {
        self.name = name
        self.target = target
    }
}

@Model
class InverseMigrationTargetBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InverseMigrationTargetChildFixture: InverseMigrationTargetBaseFixture {
    @Relationship(inverse: \InverseMigrationOwnerFixture.target) var owners: [InverseMigrationOwnerFixture]

    init(name: String, owners: [InverseMigrationOwnerFixture] = []) {
        self.owners = owners
        super.init(name: name)
    }
}

@Model
class InheritanceRelationshipBaseFixture {
    @Relationship(inverse: nil) var items: [InheritanceRelationshipItemFixture]
    init(items: [InheritanceRelationshipItemFixture]) { self.items = items }
}

@Model
final class InheritanceRelationshipChildFixture: InheritanceRelationshipBaseFixture {
    var age: Int
    init(items: [InheritanceRelationshipItemFixture], age: Int) {
        self.age = age
        super.init(items: items)
    }
}

@Model
final class InheritanceRelationshipItemFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
final class InferredToOneLeftFixture {
    var title: String
    @Relationship(inverse: \InferredToOneRightFixture.left)
    var right: InferredToOneRightFixture?

    init(title: String, right: InferredToOneRightFixture? = nil) {
        self.title = title
        self.right = right
    }
}

@Model
final class InferredToOneRightFixture {
    var name: String
    var left: InferredToOneLeftFixture?

    init(name: String, left: InferredToOneLeftFixture? = nil) {
        self.name = name
        self.left = left
    }
}

struct CodableRelationshipFallbackValue: Codable, Equatable, Hashable {
    var value: String
}

@Model
final class InferredRelationshipCodableFallbackFixture {
    var values: Set<CodableRelationshipFallbackValue>
    var optionalValues: [CodableRelationshipFallbackValue]?

    init(values: Set<CodableRelationshipFallbackValue>, optionalValues: [CodableRelationshipFallbackValue]?) {
        self.values = values
        self.optionalValues = optionalValues
    }
}

@Model
final class InferredOptionalCollectionOwnerFixture {
    var targets: [InferredOptionalCollectionTargetFixture]?

    init(targets: [InferredOptionalCollectionTargetFixture]?) {
        self.targets = targets
    }
}

@Model
final class InferredOptionalSetOwnerFixture {
    var targets: Set<InferredOptionalCollectionTargetFixture>?

    init(targets: Set<InferredOptionalCollectionTargetFixture>?) {
        self.targets = targets
    }
}

@Model
final class InferredSetOwnerFixture {
    var targets: Set<InferredOptionalCollectionTargetFixture>

    init(targets: Set<InferredOptionalCollectionTargetFixture>) {
        self.targets = targets
    }
}

@Model
final class InferredOptionalCollectionTargetFixture {
    var name: String

    init(name: String) {
        self.name = name
    }
}

extension InferredOptionalCollectionTargetFixture: Hashable {
    static func == (lhs: InferredOptionalCollectionTargetFixture, rhs: InferredOptionalCollectionTargetFixture) -> Bool
    {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

@Model
final class QualifiedOptionalScalarFixture {
    var id: Foundation.UUID?
    var link: Foundation.URL?
    var amount: Foundation.Decimal?

    init(id: Foundation.UUID?, link: Foundation.URL?, amount: Foundation.Decimal?) {
        self.id = id
        self.link = link
        self.amount = amount
    }
}

@Model
final class CodableStringCollectionFixture {
    var name: String
    var tags: [String]
    var optionalTags: [String]?
    var numbers: [Int]
    var flags: [Bool]
    var optionalNumbers: Set<Int>?

    init(
        name: String,
        tags: [String],
        optionalTags: [String]? = nil,
        numbers: [Int] = [],
        flags: [Bool] = [],
        optionalNumbers: Set<Int>? = nil
    ) {
        self.name = name
        self.tags = tags
        self.optionalTags = optionalTags
        self.numbers = numbers
        self.flags = flags
        self.optionalNumbers = optionalNumbers
    }
}

@Model
final class OptionalScalarElementsFixture {
    var name: String
    var requiredStrings: [String]
    @Attribute(.codable)
    var optionalStrings: [String?]
    @Attribute(.codable)
    var optionalNumbers: Set<Int?>
    @Attribute(.codable)
    var optionalFlags: [Bool?]
    @Attribute(.codable)
    var optionalStringCollection: [String?]?

    init(
        name: String,
        requiredStrings: [String] = [],
        optionalStrings: [String?],
        optionalNumbers: Set<Int?>,
        optionalFlags: [Bool?],
        optionalStringCollection: [String?]? = nil
    ) {
        self.name = name
        self.requiredStrings = requiredStrings
        self.optionalStrings = optionalStrings
        self.optionalNumbers = optionalNumbers
        self.optionalFlags = optionalFlags
        self.optionalStringCollection = optionalStringCollection
    }
}

@Model
final class QuantifierOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var children: [QuantifierChildFixture]

    init(name: String, children: [QuantifierChildFixture]) {
        self.name = name
        self.children = children
    }
}

@Model
final class QuantifierChildFixture {
    var name: String
    @Relationship(inverse: nil) var items: [QuantifierItemFixture]

    init(name: String, items: [QuantifierItemFixture]) {
        self.name = name
        self.items = items
    }
}

@Model
final class QuantifierItemFixture {
    var value: String

    init(value: String) {
        self.value = value
    }
}

@Model
final class InverseCollectionLifecycleOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var items: [InverseCollectionLifecycleItemFixture] = []
    init(name: String, items: [InverseCollectionLifecycleItemFixture] = []) {
        self.name = name
        self.items = items
    }
}

@Model
final class InverseCollectionLifecycleItemFixture {
    var value: String
    @Relationship(inverse: \InverseCollectionLifecycleOwnerFixture.items)
    var owner: InverseCollectionLifecycleOwnerFixture?

    init(value: String, owner: InverseCollectionLifecycleOwnerFixture?) {
        self.value = value
        self.owner = owner
    }
}

@Model
final class DetachedManyToManyLeftFixture {
    var name: String
    @Relationship(inverse: \DetachedManyToManyRightFixture.lefts)
    var rights: [DetachedManyToManyRightFixture] = []
    init(name: String, rights: [DetachedManyToManyRightFixture] = []) {
        self.name = name
        self.rights = rights
    }
}

@Model
final class DetachedManyToManyRightFixture {
    var name: String
    var lefts: [DetachedManyToManyLeftFixture] = []
    init(name: String) {
        self.name = name
        self.lefts = []
    }
}

@Model
final class DetachedInverseAmbiguityOwnerFixture {
    var name: String
    @Relationship(inverse: \DetachedInverseAmbiguityTargetFixture.primaryOwner)
    var targets: [DetachedInverseAmbiguityTargetFixture] = []
    init(name: String) { self.name = name }
}

@Model
final class DetachedInverseAmbiguityTargetFixture {
    var name: String
    var primaryOwner: DetachedInverseAmbiguityOwnerFixture?
    var secondaryOwner: DetachedInverseAmbiguityOwnerFixture?

    init(
        name: String, primaryOwner: DetachedInverseAmbiguityOwnerFixture? = nil,
        secondaryOwner: DetachedInverseAmbiguityOwnerFixture? = nil
    ) {
        self.name = name
        self.primaryOwner = primaryOwner
        self.secondaryOwner = secondaryOwner
    }
}

@Model
final class MultiHopAllSatisfyRootFixture {
    var name: String
    @Relationship(inverse: nil) var middle: MultiHopAllSatisfyMiddleFixture?

    init(name: String, middle: MultiHopAllSatisfyMiddleFixture?) {
        self.name = name
        self.middle = middle
    }
}

@Model
final class MultiHopAllSatisfyMiddleFixture {
    var name: String
    @Relationship(inverse: nil) var branch: MultiHopAllSatisfyBranchFixture?

    init(name: String, branch: MultiHopAllSatisfyBranchFixture?) {
        self.name = name
        self.branch = branch
    }
}

@Model
final class MultiHopAllSatisfyBranchFixture {
    var name: String
    @Relationship(inverse: nil) var items: [MultiHopAllSatisfyItemFixture]

    init(name: String, items: [MultiHopAllSatisfyItemFixture]) {
        self.name = name
        self.items = items
    }
}

@Model
final class MultiHopAllSatisfyItemFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
final class ThreeLevelQuantifierOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var groups: [ThreeLevelQuantifierGroupFixture]
    init(name: String, groups: [ThreeLevelQuantifierGroupFixture]) {
        self.name = name
        self.groups = groups
    }
}

@Model
final class ThreeLevelQuantifierGroupFixture {
    var name: String
    @Relationship(inverse: nil) var children: [ThreeLevelQuantifierChildFixture]
    init(name: String, children: [ThreeLevelQuantifierChildFixture]) {
        self.name = name
        self.children = children
    }
}

@Model
final class ThreeLevelQuantifierChildFixture {
    var name: String
    @Relationship(inverse: nil) var items: [ThreeLevelQuantifierItemFixture]
    init(name: String, items: [ThreeLevelQuantifierItemFixture]) {
        self.name = name
        self.items = items
    }
}

@Model
final class ThreeLevelQuantifierItemFixture {
    var value: String
    init(value: String) { self.value = value }
}

@Model
final class ThreeLevelHierarchyQuantifierOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var groups: [ThreeLevelHierarchyQuantifierGroupFixture]
    init(name: String, groups: [ThreeLevelHierarchyQuantifierGroupFixture]) {
        self.name = name
        self.groups = groups
    }
}

@Model
final class ThreeLevelHierarchyQuantifierGroupFixture {
    @Relationship(inverse: nil) var children: [ThreeLevelHierarchyQuantifierChildFixture]
    init(children: [ThreeLevelHierarchyQuantifierChildFixture]) { self.children = children }
}

@Model
final class ThreeLevelHierarchyQuantifierChildFixture {
    @Relationship(inverse: nil) var items: [ThreeLevelHierarchyQuantifierItemBaseFixture]
    init(items: [ThreeLevelHierarchyQuantifierItemBaseFixture]) { self.items = items }
}

@Model
class ThreeLevelHierarchyQuantifierItemBaseFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
final class ThreeLevelHierarchyQuantifierItemLeafFixture: ThreeLevelHierarchyQuantifierItemBaseFixture {
    var code: String
    init(title: String, code: String) {
        self.code = code
        super.init(title: title)
    }
}

@Model
final class ThreeLevelHierarchyQuantifierItemSiblingFixture: ThreeLevelHierarchyQuantifierItemBaseFixture {
    var label: String
    init(title: String, label: String) {
        self.label = label
        super.init(title: title)
    }
}

@Model
final class FourLevelQuantifierRootFixture {
    @Relationship(inverse: nil) var groups: [FourLevelQuantifierGroupFixture]
    init(groups: [FourLevelQuantifierGroupFixture]) { self.groups = groups }
}

@Model
final class FourLevelQuantifierGroupFixture {
    @Relationship(inverse: nil) var children: [FourLevelQuantifierChildFixture]
    init(children: [FourLevelQuantifierChildFixture]) { self.children = children }
}

@Model
final class FourLevelQuantifierChildFixture {
    @Relationship(inverse: nil) var items: [FourLevelQuantifierItemFixture]
    init(items: [FourLevelQuantifierItemFixture]) { self.items = items }
}

@Model
final class FourLevelQuantifierItemFixture {
    var value: String
    @Relationship(inverse: nil) var leaves: [FourLevelQuantifierLeafFixture]
    init(value: String, leaves: [FourLevelQuantifierLeafFixture]) {
        self.value = value
        self.leaves = leaves
    }
}

@Model
final class FourLevelQuantifierLeafFixture {
    var value: String
    @Relationship(inverse: nil) var descendants: [FourLevelQuantifierLeafFixture]
    init(value: String, descendants: [FourLevelQuantifierLeafFixture] = []) {
        self.value = value
        self.descendants = descendants
    }
}

@Model
final class MixedSetQuantifierRootFixture {
    var name: String
    var groups: Set<MixedSetQuantifierGroupFixture>
    init(name: String, groups: Set<MixedSetQuantifierGroupFixture>) {
        self.name = name
        self.groups = groups
    }
}

@Model
final class MixedSetQuantifierGroupFixture {
    var children: [MixedSetQuantifierChildFixture]
    init(children: [MixedSetQuantifierChildFixture]) { self.children = children }
}

@Model
final class MixedSetQuantifierChildFixture {
    var items: Set<MixedSetQuantifierItemFixture>
    init(items: Set<MixedSetQuantifierItemFixture>) { self.items = items }
}

@Model
final class MixedSetQuantifierItemFixture {
    var leaves: [MixedSetQuantifierLeafFixture]
    init(leaves: [MixedSetQuantifierLeafFixture]) { self.leaves = leaves }
}

@Model
final class MixedSetQuantifierLeafFixture {
    var value: String
    init(value: String) { self.value = value }
}

extension MixedSetQuantifierGroupFixture: Hashable {
    static func == (lhs: MixedSetQuantifierGroupFixture, rhs: MixedSetQuantifierGroupFixture) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension MixedSetQuantifierItemFixture: Hashable {
    static func == (lhs: MixedSetQuantifierItemFixture, rhs: MixedSetQuantifierItemFixture) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

@Model
final class InverseNestedQuantifierOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var children: [InverseNestedQuantifierChildFixture] = []
    init(name: String, children: [InverseNestedQuantifierChildFixture] = []) {
        self.name = name
        self.children = children
    }
}

@Model
final class InverseNestedQuantifierChildFixture {
    var name: String
    var items: [InverseNestedQuantifierItemFixture] = []
    init(name: String, items: [InverseNestedQuantifierItemFixture] = []) {
        self.name = name
        self.items = items
    }
}

@Model
final class InverseNestedQuantifierItemFixture {
    var title: String
    @Relationship(inverse: \InverseNestedQuantifierChildFixture.items)
    var child: InverseNestedQuantifierChildFixture?
    init(title: String, child: InverseNestedQuantifierChildFixture? = nil) {
        self.title = title
        self.child = child
    }
}

@Model
final class DeepInverseQuantifierOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var groups: [DeepInverseQuantifierGroupFixture] = []
    init(name: String, groups: [DeepInverseQuantifierGroupFixture] = []) {
        self.name = name
        self.groups = groups
    }
}

@Model
final class DeepInverseQuantifierGroupFixture {
    var name: String
    var children: [DeepInverseQuantifierChildFixture] = []
    init(name: String) { self.name = name }
}

@Model
final class DeepInverseQuantifierChildFixture {
    var name: String
    @Relationship(inverse: \DeepInverseQuantifierGroupFixture.children)
    var group: DeepInverseQuantifierGroupFixture?
    var items: [DeepInverseQuantifierItemFixture] = []
    init(name: String, group: DeepInverseQuantifierGroupFixture? = nil) {
        self.name = name
        self.group = group
    }
}

@Model
final class DeepInverseQuantifierItemFixture {
    var title: String
    @Relationship(inverse: \DeepInverseQuantifierChildFixture.items)
    var child: DeepInverseQuantifierChildFixture?
    init(title: String, child: DeepInverseQuantifierChildFixture? = nil) {
        self.title = title
        self.child = child
    }
}

@Model
final class NestedInverseManyToManyRootFixture {
    var name: String
    @Relationship(inverse: nil) var groups: [NestedInverseManyToManyGroupFixture] = []
    init(name: String, groups: [NestedInverseManyToManyGroupFixture] = []) {
        self.name = name
        self.groups = groups
    }
}

@Model
final class NestedInverseManyToManyGroupFixture {
    var name: String
    @Relationship(inverse: nil) var tags: [InheritedManyToManyTagFixture] = []
    init(name: String, tags: [InheritedManyToManyTagFixture] = []) {
        self.name = name
        self.tags = tags
    }
}

@Model
final class ExplicitCodableStringCollectionFixture {
    @Attribute(.codable) var tags: [String]
    @Attribute(.codable) var optionalTags: [String]?

    init(tags: [String], optionalTags: [String]? = nil) {
        self.tags = tags
        self.optionalTags = optionalTags
    }
}

@Model
final class OptionalIntegerSetFixture {
    var name: String
    var values: Set<Int>?

    init(name: String, values: Set<Int>?) {
        self.name = name
        self.values = values
    }
}

@Model
final class UInt64CollectionFixture {
    @Attribute(.codable) var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }
}

@Model
final class UIntCollectionFixture {
    @Attribute(.codable) var values: [UInt]
    init(values: [UInt]) { self.values = values }
}

@Model
final class OptionalCodableStringCollectionFixture {
    var name: String
    @Attribute(.codable) var tags: [String]?

    init(name: String, tags: [String]?) {
        self.name = name
        self.tags = tags
    }
}

@Model
final class NestedToOneRootFixture {
    var name: String
    @Relationship(inverse: nil) var middle: NestedToOneMiddleFixture?

    init(name: String, middle: NestedToOneMiddleFixture?) {
        self.name = name
        self.middle = middle
    }
}

@Model
final class NestedToOneMiddleFixture {
    var name: String
    @Relationship(inverse: nil) var branch: NestedToOneBranchFixture?

    init(name: String, branch: NestedToOneBranchFixture?) {
        self.name = name
        self.branch = branch
    }
}

@Model
final class NestedToOneBranchFixture {
    var name: String
    @Relationship(inverse: nil) var leaf: NestedToOneLeafFixture?

    init(name: String, leaf: NestedToOneLeafFixture?) {
        self.name = name
        self.leaf = leaf
    }
}

@Model
final class NestedToOneLeafFixture {
    var title: String

    init(title: String) {
        self.title = title
    }
}

@Model
class NestedHierarchyMiddleBaseFixture {
    var name: String

    init(name: String) {
        self.name = name
    }
}

@Model
class NestedHierarchyMiddleChildFixture: NestedHierarchyMiddleBaseFixture {
    @Relationship(inverse: nil) var leaf: NestedToOneLeafFixture?

    init(name: String, leaf: NestedToOneLeafFixture?) {
        super.init(name: name)
        self.leaf = leaf
    }
}

@Model
final class NestedHierarchyMiddleGrandchildFixture: NestedHierarchyMiddleChildFixture {
    var rank: Int

    init(name: String, leaf: NestedToOneLeafFixture?, rank: Int) {
        self.rank = rank
        super.init(name: name, leaf: leaf)
    }
}

@Model
final class NestedHierarchyRootFixture {
    var name: String
    @Relationship(inverse: nil) var middle: NestedHierarchyMiddleChildFixture?

    init(name: String, middle: NestedHierarchyMiddleChildFixture?) {
        self.name = name
        self.middle = middle
    }
}

@Model
final class NestedHierarchyPathRootFixture {
    var name: String
    @Relationship(inverse: nil) var middle: NestedHierarchyPathMiddleFixture?

    init(name: String, middle: NestedHierarchyPathMiddleFixture?) {
        self.name = name
        self.middle = middle
    }
}

@Model
final class NestedHierarchyPathMiddleFixture {
    var name: String
    @Relationship(inverse: nil) var target: NestedHierarchyMiddleChildFixture?

    init(name: String, target: NestedHierarchyMiddleChildFixture?) {
        self.name = name
        self.target = target
    }
}

@Model
final class NestedInverseRootFixture {
    var name: String
    @Relationship(inverse: nil) var middle: NestedInverseMiddleFixture?

    init(name: String, middle: NestedInverseMiddleFixture?) {
        self.name = name
        self.middle = middle
    }
}

@Model
final class NestedInverseMiddleFixture {
    var name: String
    @Relationship(inverse: \NestedInverseBranchFixture.middle) var branch: NestedInverseBranchFixture?

    init(name: String, branch: NestedInverseBranchFixture?) {
        self.name = name
        self.branch = branch
    }
}

@Model
final class NestedInverseBranchFixture {
    var name: String
    var middle: NestedInverseMiddleFixture?
    @Relationship(inverse: nil) var leaf: NestedInverseLeafFixture?
    @Relationship(inverse: nil) var items: [NestedInverseItemFixture]

    init(
        name: String,
        middle: NestedInverseMiddleFixture?,
        leaf: NestedInverseLeafFixture?,
        items: [NestedInverseItemFixture] = []
    ) {
        self.name = name
        self.middle = middle
        self.leaf = leaf
        self.items = items
    }
}

@Model
final class NestedInverseItemFixture {
    var title: String

    init(title: String) {
        self.title = title
    }
}

@Model
final class NestedInverseLeafFixture {
    var title: String

    init(title: String) {
        self.title = title
    }
}

@Model
final class NestedToManyRootFixture {
    var name: String
    @Relationship(inverse: nil) var middle: NestedToManyMiddleFixture?

    init(name: String, middle: NestedToManyMiddleFixture?) {
        self.name = name
        self.middle = middle
    }
}

@Model
final class NestedToManyMiddleFixture {
    var name: String
    @Relationship(inverse: nil) var items: [NestedToManyItemFixture]

    init(name: String, items: [NestedToManyItemFixture]) {
        self.name = name
        self.items = items
    }
}

@Model
final class NestedToManyItemFixture {
    var title: String

    init(title: String) {
        self.title = title
    }
}

@Model
final class ToManyHierarchyOwnerFixture {
    @Relationship(inverse: nil) var targets: [ToManyHierarchyTargetChildFixture]
    init(targets: [ToManyHierarchyTargetChildFixture]) { self.targets = targets }
}

@Model
class ToManyHierarchyTargetBaseFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
class ToManyHierarchyTargetChildFixture: ToManyHierarchyTargetBaseFixture {
    var code: String
    init(title: String, code: String) {
        self.code = code
        super.init(title: title)
    }
}

@Model
final class ToManyHierarchyTargetGrandchildFixture: ToManyHierarchyTargetChildFixture {
    var rank: Int
    init(title: String, code: String, rank: Int) {
        self.rank = rank
        super.init(title: title, code: code)
    }
}

@Model
final class ToManyHierarchyTargetSiblingFixture: ToManyHierarchyTargetBaseFixture {
    var label: String
    init(title: String, label: String) {
        self.label = label
        super.init(title: title)
    }
}

@Model
class DualHierarchyOwnerBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class DualHierarchyOwnerLeafAFixture: DualHierarchyOwnerBaseFixture {
    @Relationship(inverse: nil) var items: [DualHierarchyTargetLeafFixture]
    init(name: String, items: [DualHierarchyTargetLeafFixture]) {
        self.items = items
        super.init(name: name)
    }
}

@Model
final class DualHierarchyOwnerLeafBFixture: DualHierarchyOwnerBaseFixture {
    @Relationship(inverse: nil) var items: [DualHierarchyTargetLeafFixture]
    init(name: String, items: [DualHierarchyTargetLeafFixture]) {
        self.items = items
        super.init(name: name)
    }
}

@Model
class DualHierarchyTargetBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class DualHierarchyTargetLeafFixture: DualHierarchyTargetBaseFixture {
    var code: String
    init(name: String, code: String) {
        self.code = code
        super.init(name: name)
    }
}

@Model
final class DualHierarchyTargetSiblingFixture: DualHierarchyTargetBaseFixture {
    var label: String
    init(name: String, label: String) {
        self.label = label
        super.init(name: name)
    }
}

@Model
final class InheritedToOneTargetFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
class InheritedToOneBaseFixture {
    @Relationship(inverse: nil) var target: InheritedToOneTargetFixture?
    init(target: InheritedToOneTargetFixture?) { self.target = target }
}

// Verify that explicitly selecting the default preserves model-subclass generation.
@Model(protocolConformancesOnly: false)
final class InheritedToOneChildFixture: InheritedToOneBaseFixture {
    @Relationship(inverse: nil) var childTarget: InheritedToOneTargetFixture?
    var age: Int

    init(target: InheritedToOneTargetFixture?, childTarget: InheritedToOneTargetFixture?, age: Int) {
        self.childTarget = childTarget
        self.age = age
        super.init(target: target)
    }
}

@Model
final class InheritedToOneSiblingFixture: InheritedToOneBaseFixture {
    @Relationship(inverse: nil) var siblingTarget: InheritedToOneTargetFixture?

    init(target: InheritedToOneTargetFixture?, siblingTarget: InheritedToOneTargetFixture?) {
        self.siblingTarget = siblingTarget
        super.init(target: target)
    }
}

@Model
class RequiredInheritedToOneBaseFixture {
    @Relationship(inverse: nil) var target: InheritedToOneTargetFixture
    init(target: InheritedToOneTargetFixture) { self.target = target }
}

@Model
final class RequiredInheritedToOneChildFixture: RequiredInheritedToOneBaseFixture {
    var rank: Int
    init(target: InheritedToOneTargetFixture, rank: Int) {
        self.rank = rank
        super.init(target: target)
    }
}

@Model
final class InheritedOneToManyTargetFixture {
    var title: String
    @Relationship(inverse: nil) var children: [InheritedOneToManyChildFixture] = []
    init(title: String) { self.title = title }
}

@Model
class InheritedOneToManyBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class InheritedOneToManyChildFixture: InheritedOneToManyBaseFixture {
    @Relationship(inverse: \InheritedOneToManyTargetFixture.children)
    var target: InheritedOneToManyTargetFixture?
    init(name: String, target: InheritedOneToManyTargetFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
final class InheritedOneToManyGrandchildFixture: InheritedOneToManyChildFixture {
    var rank: Int

    init(name: String, target: InheritedOneToManyTargetFixture?, rank: Int) {
        self.rank = rank
        super.init(name: name, target: target)
    }
}

@Model
final class InheritedOneToManySiblingFixture: InheritedOneToManyBaseFixture {
    var label: String
    init(name: String, label: String) {
        self.label = label
        super.init(name: name)
    }
}

@Model
class InheritedToManyBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class InheritedToManyChildFixture: InheritedToManyBaseFixture {
    @Relationship(inverse: nil) var targets: [InheritedToOneTargetFixture] = []
    init(name: String, targets: [InheritedToOneTargetFixture]) {
        self.targets = targets
        super.init(name: name)
    }
}

@Model
final class InheritedToManyGrandchildFixture: InheritedToManyChildFixture {
    var rank: Int
    init(name: String, targets: [InheritedToOneTargetFixture], rank: Int) {
        self.rank = rank
        super.init(name: name, targets: targets)
    }
}

@Model
final class InheritedToManySiblingFixture: InheritedToManyBaseFixture {
    @Relationship(inverse: nil) var targets: [InheritedToOneTargetFixture] = []
    init(name: String, targets: [InheritedToOneTargetFixture]) {
        self.targets = targets
        super.init(name: name)
    }
}

@Model
class HierarchyTargetBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class HierarchyTargetChildFixture: HierarchyTargetBaseFixture {
    var detail: String
    @Relationship(inverse: nil) var owners: [HierarchyOwnerChildFixture] = []
    init(name: String, detail: String) {
        self.detail = detail
        super.init(name: name)
    }
}

@Model
final class HierarchyTargetGrandchildFixture: HierarchyTargetChildFixture {
    var rank: Int
    init(name: String, detail: String, rank: Int) {
        self.rank = rank
        super.init(name: name, detail: detail)
    }
}

@Model
final class HierarchyTargetSiblingFixture: HierarchyTargetBaseFixture {
    var label: String
    init(name: String, label: String) {
        self.label = label
        super.init(name: name)
    }
}

@Model
class UniqueHierarchyBaseFixture {
    @Attribute(.unique) var code: String
    init(code: String) { self.code = code }
}

@Model
final class UniqueHierarchyChildFixture: UniqueHierarchyBaseFixture {
    var value: Int
    init(code: String, value: Int) {
        self.value = value
        super.init(code: code)
    }
}

@Model
final class UniqueHierarchySiblingFixture: UniqueHierarchyBaseFixture {
    var label: String
    init(code: String, label: String) {
        self.label = label
        super.init(code: code)
    }
}

@Model
class SubtypeUniqueBaseFixture {
    var token: String
    init(token: String) { self.token = token }
}

@Model
class SubtypeUniqueChildFixture: SubtypeUniqueBaseFixture {
    @Attribute(.unique) var scopedKey: String
    var tenant: String
    var score: Int

    init(token: String, scopedKey: String, tenant: String, score: Int) {
        self.scopedKey = scopedKey
        self.tenant = tenant
        self.score = score
        super.init(token: token)
    }

    #Unique(\SubtypeUniqueChildFixture.tenant, \SubtypeUniqueChildFixture.score)
    #Index(\SubtypeUniqueChildFixture.score)
}

@Model
final class SubtypeUniqueGrandchildFixture: SubtypeUniqueChildFixture {
    var rank: Int

    init(token: String, scopedKey: String, tenant: String, score: Int, rank: Int) {
        self.rank = rank
        super.init(token: token, scopedKey: scopedKey, tenant: tenant, score: score)
    }
}

@Model
final class SubtypeUniqueSiblingFixture: SubtypeUniqueBaseFixture {
    @Attribute(.unique) var scopedKey: String
    var label: String
    init(token: String, scopedKey: String, label: String) {
        self.scopedKey = scopedKey
        self.label = label
        super.init(token: token)
    }
}

@Model
class PlainHierarchyTargetBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class PlainHierarchyTargetChildFixture: PlainHierarchyTargetBaseFixture {
    var detail: String
    init(name: String, detail: String) {
        self.detail = detail
        super.init(name: name)
    }
}

@Model
final class PlainHierarchyTargetGrandchildFixture: PlainHierarchyTargetChildFixture {
    var rank: Int
    init(name: String, detail: String, rank: Int) {
        self.rank = rank
        super.init(name: name, detail: detail)
    }
}

@Model
final class PlainHierarchyChildTargetOwnerFixture {
    var name: String
    var detail: String
    @Relationship(inverse: nil) var target: PlainHierarchyTargetChildFixture?
    init(name: String, detail: String, target: PlainHierarchyTargetChildFixture?) {
        self.name = name
        self.detail = detail
        self.target = target
    }
}

@Model
final class OptionalToOneIntegerTargetFixture {
    var rank: Int
    init(rank: Int) { self.rank = rank }
}

@Model
final class OptionalToOneIntegerOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var target: OptionalToOneIntegerTargetFixture?
    init(name: String, target: OptionalToOneIntegerTargetFixture?) {
        self.name = name
        self.target = target
    }
}

@Model
final class OptionalToOneDateTargetFixture {
    var timestamp: Date
    init(timestamp: Date) { self.timestamp = timestamp }
}

@Model
final class OptionalToOneDateOwnerFixture {
    var name: String
    @Relationship(inverse: nil) var target: OptionalToOneDateTargetFixture?
    init(name: String, target: OptionalToOneDateTargetFixture?) {
        self.name = name
        self.target = target
    }
}

@Model
final class OptionalToOneDecimalTargetFixture {
    var amount: Decimal
    init(amount: Decimal) { self.amount = amount }
}

@Model
final class OptionalToOneDecimalOwnerFixture {
    @Relationship(inverse: nil) var target: OptionalToOneDecimalTargetFixture?
    init(target: OptionalToOneDecimalTargetFixture?) { self.target = target }
}

@Model
final class CollectionRangeElementFixture {
    var rank: Int
    init(rank: Int) { self.rank = rank }
}

@Model
final class CollectionRangeOwnerFixture {
    @Relationship(inverse: nil) var elements: [CollectionRangeElementFixture]
    init(elements: [CollectionRangeElementFixture]) { self.elements = elements }
}

@Model
final class PlainHierarchyTargetSiblingFixture: PlainHierarchyTargetBaseFixture {
    var label: String
    init(name: String, label: String) {
        self.label = label
        super.init(name: name)
    }
}

@Model
class HierarchyOwnerBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class HierarchyOwnerChildFixture: HierarchyOwnerBaseFixture {
    @Relationship(inverse: \HierarchyTargetChildFixture.owners)
    var target: HierarchyTargetBaseFixture?
    init(name: String, target: HierarchyTargetBaseFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
class DeniedHierarchyTargetBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class DeniedHierarchyTargetChildFixture: DeniedHierarchyTargetBaseFixture {
    @Relationship(deleteRule: .deny, inverse: nil) var owners: [HierarchySubtypeOwnerChildFixture] = []
    var detail: String
    init(name: String, detail: String) {
        self.detail = detail
        super.init(name: name)
    }
}

@Model
class CascadeHierarchyTargetBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class CascadeHierarchyTargetChildFixture: CascadeHierarchyTargetBaseFixture {
    @Relationship(deleteRule: .cascade, inverse: nil) var owners: [CascadeHierarchyInverseOwnerChildFixture] = []
    var detail: String
    init(name: String, detail: String) {
        self.detail = detail
        super.init(name: name)
    }
}

@Model
class CascadeHierarchySourceBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class CascadeHierarchyInverseOwnerChildFixture: CascadeHierarchySourceBaseFixture {
    @Relationship(inverse: \CascadeHierarchyTargetChildFixture.owners)
    var target: CascadeHierarchyTargetBaseFixture?
    init(name: String, target: CascadeHierarchyTargetBaseFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
class MatrixLeftBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class MatrixLeftChildFixture: MatrixLeftBaseFixture {
    @Relationship(inverse: \MatrixRightChildFixture.leftMembers)
    var rightMembers: [MatrixRightBaseFixture] = []
    init(name: String, rightMembers: [MatrixRightBaseFixture]) {
        self.rightMembers = rightMembers
        super.init(name: name)
    }
}

@Model
final class MatrixLeftGrandchildFixture: MatrixLeftChildFixture {
    var rank: Int
    init(name: String, rightMembers: [MatrixRightBaseFixture], rank: Int) {
        self.rank = rank
        super.init(name: name, rightMembers: rightMembers)
    }
}

@Model
final class MatrixLeftSiblingFixture: MatrixLeftBaseFixture {
    var label: String
    init(name: String, label: String) {
        self.label = label
        super.init(name: name)
    }
}

@Model
class MatrixRightBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class MatrixRightChildFixture: MatrixRightBaseFixture {
    @Relationship(inverse: nil) var leftMembers: [MatrixLeftBaseFixture] = []
    override init(name: String) { super.init(name: name) }
}

@Model
final class MatrixRightGrandchildFixture: MatrixRightChildFixture {
    var rank: Int
    init(name: String, rank: Int) {
        self.rank = rank
        super.init(name: name)
    }
}

@Model
final class MatrixRightSiblingFixture: MatrixRightBaseFixture {
    var label: String
    init(name: String, label: String) {
        self.label = label
        super.init(name: name)
    }
}

@Model
class SelfLinkBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class SelfLinkChildFixture: SelfLinkBaseFixture {
    @Relationship(inverse: \SelfLinkChildFixture.children) var parents: [SelfLinkBaseFixture] = []
    @Relationship(inverse: nil) var children: [SelfLinkBaseFixture] = []
    init(name: String, parents: [SelfLinkBaseFixture] = []) {
        self.parents = parents
        super.init(name: name)
    }
}

@Model
final class SelfLinkGrandchildFixture: SelfLinkChildFixture {
    var rank: Int
    init(name: String, parents: [SelfLinkBaseFixture] = [], rank: Int) {
        self.rank = rank
        super.init(name: name, parents: parents)
    }
}

@Model
class HierarchySubtypeOwnerBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class HierarchySubtypeOwnerChildFixture: HierarchySubtypeOwnerBaseFixture {
    @Relationship(inverse: \DeniedHierarchyTargetChildFixture.owners)
    var target: DeniedHierarchyTargetBaseFixture?
    init(name: String, target: DeniedHierarchyTargetBaseFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
final class FlatHierarchyTargetOwnerFixture {
    @Relationship(inverse: nil) var target: PlainHierarchyTargetBaseFixture?
    var title: String
    init(title: String, target: PlainHierarchyTargetBaseFixture?) {
        self.title = title
        self.target = target
    }
}

@Model
class HierarchyToHierarchyOwnerBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class HierarchyToHierarchyOwnerChildFixture: HierarchyToHierarchyOwnerBaseFixture {
    @Relationship(inverse: nil) var target: PlainHierarchyTargetBaseFixture?
    var rank: Int
    init(name: String, target: PlainHierarchyTargetBaseFixture?, rank: Int) {
        self.target = target
        self.rank = rank
        super.init(name: name)
    }
}

@Model
class CascadeHierarchyOwnerBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class CascadeHierarchyOwnerChildFixture: CascadeHierarchyOwnerBaseFixture {
    @Relationship(deleteRule: .cascade, inverse: nil) var target: PlainHierarchyTargetBaseFixture?
    init(name: String, target: PlainHierarchyTargetBaseFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
class DenyHierarchyOwnerBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class DenyHierarchyOwnerChildFixture: DenyHierarchyOwnerBaseFixture {
    @Relationship(deleteRule: .deny, inverse: nil) var target: PlainHierarchyTargetBaseFixture?
    init(name: String, target: PlainHierarchyTargetBaseFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
final class InheritedManyToManyTagFixture {
    @Relationship(inverse: nil) var owners: [InheritedManyToManyChildFixture] = []
    var title: String
    init(title: String) { self.title = title }
}

@Model
class InheritedManyToManyBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
class InheritedManyToManyChildFixture: InheritedManyToManyBaseFixture {
    @Relationship(inverse: \InheritedManyToManyTagFixture.owners)
    var tags: [InheritedManyToManyTagFixture] = []
    init(name: String, tags: [InheritedManyToManyTagFixture]) {
        self.tags = tags
        super.init(name: name)
    }
}

@Model
final class InheritedManyToManyGrandchildFixture: InheritedManyToManyChildFixture {
    var rank: Int
    init(name: String, tags: [InheritedManyToManyTagFixture], rank: Int) {
        self.rank = rank
        super.init(name: name, tags: tags)
    }
}

@Model
class InheritedCascadeJoinBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InheritedCascadeJoinChildFixture: InheritedCascadeJoinBaseFixture {
    @Relationship(deleteRule: .cascade, inverse: nil) var targets: [InheritedToOneTargetFixture] = []
    init(name: String, targets: [InheritedToOneTargetFixture]) {
        self.targets = targets
        super.init(name: name)
    }
}

@Model
class InheritedDenyJoinBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InheritedDenyJoinChildFixture: InheritedDenyJoinBaseFixture {
    @Relationship(deleteRule: .deny, inverse: nil) var targets: [InheritedToOneTargetFixture] = []
    init(name: String, targets: [InheritedToOneTargetFixture]) {
        self.targets = targets
        super.init(name: name)
    }
}

@Model
final class InheritedCascadeTargetFixture {
    @Relationship(deleteRule: .cascade, inverse: nil) var children: [InheritedCascadeChildFixture] = []
    var title: String
    init(title: String) { self.title = title }
}

@Model
class InheritedCascadeBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InheritedCascadeChildFixture: InheritedCascadeBaseFixture {
    @Relationship(inverse: \InheritedCascadeTargetFixture.children)
    var target: InheritedCascadeTargetFixture?
    init(name: String, target: InheritedCascadeTargetFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
final class InheritedDenyTargetFixture {
    @Relationship(deleteRule: .deny, inverse: nil) var children: [InheritedDenyChildFixture] = []
    var title: String
    init(title: String) { self.title = title }
}

@Model
class InheritedDenyBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InheritedDenyChildFixture: InheritedDenyBaseFixture {
    @Relationship(inverse: \InheritedDenyTargetFixture.children)
    var target: InheritedDenyTargetFixture?
    init(name: String, target: InheritedDenyTargetFixture?) {
        self.target = target
        super.init(name: name)
    }
}

@Model
class InheritanceLookupBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InheritanceLookupChildFixture: InheritanceLookupBaseFixture {
    var requiredValue: String
    init(name: String, requiredValue: String) {
        self.requiredValue = requiredValue
        super.init(name: name)
    }
}

/// A model subclass that exercises inheritance across target boundaries.
@Model
public final class CrossModuleInheritanceChildFixture: CrossModuleInheritanceBase {
    /// A persisted value declared by the external subclass.
    public var age: Int

    /// Creates a child model using inherited and locally declared values.
    public init(name: String, age: Int) {
        self.age = age
        super.init(name: name)
    }
}

/// An open model subclass that remains available for further inheritance.
@Model
open class CrossModuleOpenInheritanceChildFixture: CrossModuleInheritanceBase {
    /// A persisted value declared by the open child.
    public var age: Int

    /// Creates an open child model.
    public init(name: String, age: Int) {
        self.age = age
        super.init(name: name)
    }
}

@Model
final class CrossModuleOpenInheritanceGrandchildFixture: CrossModuleOpenInheritanceChildFixture {
    var rank: Int

    init(name: String, age: Int, rank: Int) {
        self.rank = rank
        super.init(name: name, age: age)
    }
}

class InheritanceBaseFixture: PersistentModel {
    typealias Model = InheritanceBaseFixture

    var persistentBackingData: any BackingData<InheritanceBaseFixture>
    var baseValue: String {
        get { getValue(forKey: \.baseValue) }
        set { setValue(forKey: \.baseValue, to: newValue) }
    }

    required init(backingData: any BackingData<InheritanceBaseFixture>) {
        persistentBackingData = backingData
    }

    class func schemaMetadata() -> [Schema.PropertyMetadata] { [] }
}

final class InheritanceChildFixture: InheritanceBaseFixture {
    var childValue: Int {
        get {
            getInheritedValue(
                at: 1, keyPath: \InheritanceChildFixture.childValue, property: "childValue", as: Int.self)
        }
        set { setInheritedValue(at: 1, keyPath: \InheritanceChildFixture.childValue, to: newValue) }
    }

    required init(backingData: any BackingData<InheritanceBaseFixture>) {
        super.init(backingData: backingData)
    }
}

final class PersistentModelTests: XCTestCase {
    @MainActor
    func testModelWithManualCodableConformanceCanBeDecodedAndPersisted() throws {
        let model = CodableMacroProtocolConformanceFixture(value: 17)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(model)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"value":17}"#)
        let decoded = try JSONDecoder().decode(CodableMacroProtocolConformanceFixture.self, from: encoded)
        XCTAssertEqual(decoded.value, 17)
        XCTAssertNil(decoded.modelContext)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CodableMacroProtocolConformanceFixture.self, from: Data("{}".utf8))
        ) { error in
            guard case DecodingError.keyNotFound(CodableMacroProtocolConformanceFixture.CodingKeys.value, _) = error
            else {
                return XCTFail("Expected missing-value keyNotFound, got \(error)")
            }
        }

        let container = try ModelContainer(
            for: CodableMacroProtocolConformanceFixture.self,
            configurations: .sqliteMemory("model-manual-codable"))
        let entity = try XCTUnwrap(container.schema.entity(forName: "CodableMacroProtocolConformanceFixture"))
        XCTAssertEqual(entity.attributes.map(\.name), ["value"])
        XCTAssertTrue(entity.relationships.isEmpty)
        let temporaryIdentifier = decoded.persistentModelID
        XCTAssertTrue(temporaryIdentifier.isTemporary)
        container.mainContext.insert(decoded)
        XCTAssertTrue(decoded.modelContext === container.mainContext)
        try container.mainContext.save()
        XCTAssertFalse(decoded.persistentModelID.isTemporary)
        let permanentIdentifier = decoded.persistentModelID
        XCTAssertNotEqual(permanentIdentifier, temporaryIdentifier)

        let freshContext = container.makeContext()
        let fetched = try freshContext.fetch(FetchDescriptor<CodableMacroProtocolConformanceFixture>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.value, 17)
        let refetched = try XCTUnwrap(fetched.first)
        XCTAssertFalse(refetched === decoded)
        XCTAssertTrue(refetched.modelContext === freshContext)
        XCTAssertEqual(refetched.persistentModelID, permanentIdentifier)
        XCTAssertEqual(String(decoding: try encoder.encode(refetched), as: UTF8.self), #"{"value":17}"#)
    }

    @MainActor
    func testModelProtocolConformancesUseRootModelGeneration() throws {
        let container = try ModelContainer(
            for: SingleMacroProtocolConformanceFixture.self,
            MacroProtocolConformanceFixture.self,
            configurations: .sqliteMemory("model-protocol-conformances"))
        let context = container.mainContext
        let singleModel = SingleMacroProtocolConformanceFixture(value: 24)
        let model = MacroProtocolConformanceFixture(value: 42)
        context.insert(singleModel)
        context.insert(model)
        try context.save()

        let fetched = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<MacroProtocolConformanceFixture>()).first)
        XCTAssertEqual(fetched.value, 42)
        let fetchedSingle = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<SingleMacroProtocolConformanceFixture>()).first)
        XCTAssertEqual(fetchedSingle.value, 24)
    }

    func testNonfinalModelBaseStoresOwnProperties() {
        let base = InheritanceMacroBaseFixture(name: "base only")
        XCTAssertEqual(base.name, "base only")
        XCTAssertTrue(base.persistentBackingData is DetachedBackingData<InheritanceMacroBaseFixture>)
    }

    func testInheritedModelUsesBaseBackingForSubclassKeyPaths() {
        let backing = DetachedBackingData<InheritanceBaseFixture>(metadata: [])
        let child = InheritanceChildFixture(backingData: backing)
        child.childValue = 42
        XCTAssertEqual(child.childValue, 42)
        XCTAssertTrue(child.anyBackingData.supportsSubclassKeyPaths)
        XCTAssertTrue(child.persistentBackingData === backing)
    }

    func testModelMacroSubclassUsesInheritedBackingForOwnAndBaseProperties() {
        let child = InheritanceMacroChildFixture(name: "base", age: 8)
        XCTAssertEqual(child.age, 8)
        child.name = "updated base"
        child.age = 9
        XCTAssertEqual(child.name, "updated base")
        XCTAssertEqual(child.age, 9)
        XCTAssertTrue(child.anyBackingData.supportsSubclassKeyPaths)
    }

    func testNestedModelSubclassInitializersAndPropertyStorage() {
        let grandchild = InheritanceMacroGrandchildFixture(name: "nested", age: 12, rank: 3)
        XCTAssertEqual(grandchild.name, "nested")
        XCTAssertEqual(grandchild.age, 12)
        XCTAssertEqual(grandchild.rank, 3)
        grandchild.name = "updated"
        grandchild.age = 13
        grandchild.rank = 4
        XCTAssertEqual(grandchild.name, "updated")
        XCTAssertEqual(grandchild.age, 13)
        XCTAssertEqual(grandchild.rank, 4)
    }

    func testSubclassKeyPathResolverRecognizesInheritedPropertyRoots() {
        XCTAssertEqual(
            InheritanceMacroChildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroChildFixture.name]?.name,
            "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroGrandchildFixture.name]?
                .name,
            "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroGrandchildFixture.age]?
                .name,
            "age")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroGrandchildFixture.rank]?
                .name,
            "rank")
        XCTAssertEqual(
            InheritanceMacroChildFixture.propertyName(forKeyPath: \InheritanceMacroChildFixture.name), "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyName(forKeyPath: \InheritanceMacroGrandchildFixture.name),
            "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyName(forKeyPath: \InheritanceMacroGrandchildFixture.age),
            "age")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyName(forKeyPath: \InheritanceMacroGrandchildFixture.rank),
            "rank")
        XCTAssertEqual(InheritanceMacroBaseFixture.propertySlot(forKeyPath: \InheritanceMacroBaseFixture.name), 0)
        XCTAssertEqual(InheritanceMacroChildFixture.propertySlot(forKeyPath: \InheritanceMacroChildFixture.name), 0)
        XCTAssertEqual(InheritanceMacroChildFixture.propertySlot(forKeyPath: \InheritanceMacroChildFixture.age), 1)
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertySlot(forKeyPath: \InheritanceMacroGrandchildFixture.name), 0)
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertySlot(forKeyPath: \InheritanceMacroGrandchildFixture.age), 1)
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertySlot(forKeyPath: \InheritanceMacroGrandchildFixture.rank), 2)
    }

    func testCrossModuleModelSubclassUsesExportedResolverAndBacking() {
        let child = CrossModuleInheritanceChildFixture(name: "external", age: 5)
        XCTAssertEqual(child.name, "external")
        XCTAssertEqual(child.age, 5)
        XCTAssertEqual(
            CrossModuleInheritanceChildFixture.propertyName(forKeyPath: \CrossModuleInheritanceChildFixture.name),
            "name")
        child.name = "updated"
        XCTAssertEqual(child.name, "updated")

        let observation = ObservationFlag()
        withObservationTracking {
            _ = child.age
        } onChange: {
            observation.set()
        }
        child.age = 6
        XCTAssertTrue(observation.value)
    }

    func testOpenCrossModuleSubclassSupportsFurtherInheritance() {
        let grandchild = CrossModuleOpenInheritanceGrandchildFixture(name: "open", age: 8, rank: 3)

        XCTAssertEqual(grandchild.name, "open")
        XCTAssertEqual(grandchild.age, 8)
        XCTAssertEqual(grandchild.rank, 3)
        XCTAssertEqual(
            CrossModuleOpenInheritanceGrandchildFixture.propertyName(
                forKeyPath: \CrossModuleOpenInheritanceGrandchildFixture.name),
            "name")
    }

    @MainActor
    func testCrossModuleOpenInheritancePersistsAndFetchesPolymorphically() throws {
        let container = try ModelContainer(
            for: CrossModuleInheritanceBase.self,
            CrossModuleOpenInheritanceChildFixture.self,
            CrossModuleOpenInheritanceGrandchildFixture.self,
            configurations: .sqliteMemory("cross-module-open-inheritance-persistence"))
        let writer = container.mainContext
        let inserted = CrossModuleOpenInheritanceGrandchildFixture(name: "persisted", age: 9, rank: 4)
        let baseOnly = CrossModuleInheritanceBase(name: "base only")
        writer.insert(inserted)
        writer.insert(baseOnly)
        try writer.save()
        XCTAssertFalse(inserted.persistentModelID.isTemporary)

        let reader = container.makeContext()
        let baseDescriptor = FetchDescriptor<CrossModuleInheritanceBase>(sortBy: [SortDescriptor(\.name)])
        let baseModels = try reader.fetch(baseDescriptor)
        XCTAssertEqual(baseModels.count, 2)
        let fetchedGrandchild = try XCTUnwrap(
            baseModels.first(where: { $0.name == "persisted" }) as? CrossModuleOpenInheritanceGrandchildFixture)
        XCTAssertEqual(fetchedGrandchild.name, "persisted")
        XCTAssertEqual(fetchedGrandchild.age, 9)
        XCTAssertEqual(fetchedGrandchild.rank, 4)
        let fetchedBaseOnly = try XCTUnwrap(baseModels.first(where: { $0.name == "base only" }))
        XCTAssertTrue(type(of: fetchedBaseOnly) == CrossModuleInheritanceBase.self)

        let concrete = try XCTUnwrap(
            reader.fetch(FetchDescriptor<CrossModuleOpenInheritanceGrandchildFixture>()).first)
        XCTAssertEqual(concrete.persistentModelID.entityName, "CrossModuleOpenInheritanceGrandchildFixture")
        XCTAssertEqual(try reader.fetchCount(baseDescriptor), 2)
        XCTAssertEqual(
            try reader.fetchIdentifiers(baseDescriptor),
            baseModels.map(\.persistentModelID))
    }

    @MainActor
    func testSubclassInitializerRelationshipSurvivesInsertionPreparation() throws {
        let container = try ModelContainer(
            for: InheritanceRelationshipBaseFixture.self,
            InheritanceRelationshipChildFixture.self,
            InheritanceRelationshipItemFixture.self)
        let context = container.mainContext
        let item = InheritanceRelationshipItemFixture(title: "item")
        let child = InheritanceRelationshipChildFixture(items: [item], age: 4)

        context.insert(child)

        XCTAssertEqual(child.items.map(\.title), ["item"])
        child.items = []
        XCTAssertTrue(child.items.isEmpty)
    }

    @MainActor
    func testInheritedRelationshipStorageMappingRetainsLogicalOwner() throws {
        let container = try ModelContainer(
            for: InheritanceRelationshipBaseFixture.self,
            InheritanceRelationshipChildFixture.self,
            InheritanceRelationshipItemFixture.self)

        let mapping = try XCTUnwrap(
            container.schema.relationshipStorageMapping(
                modelEntityName: "InheritanceRelationshipChildFixture", relationshipName: "items"))
        XCTAssertEqual(mapping.modelEntityName, "InheritanceRelationshipChildFixture")
        XCTAssertEqual(mapping.declaringEntityName, "InheritanceRelationshipBaseFixture")
        XCTAssertEqual(mapping.ownerRootEntityName, "InheritanceRelationshipBaseFixture")
        XCTAssertEqual(mapping.destinationEntityName, "InheritanceRelationshipItemFixture")
        XCTAssertEqual(mapping.destinationRootEntityName, "InheritanceRelationshipItemFixture")
    }

    @MainActor
    func testInheritedToOneRelationshipsPersistInRootTableAndMaterialize() throws {
        let container = try ModelContainer(
            for: [
                InheritedToOneChildFixture.self,
                InheritedToOneSiblingFixture.self,
                InheritedToOneTargetFixture.self,
            ],
            configurations: [.sqliteMemory("inherited-to-one-root-table")])
        let writer = container.mainContext
        let baseTarget = InheritedToOneTargetFixture(title: "base")
        let childTarget = InheritedToOneTargetFixture(title: "child")
        let siblingTarget = InheritedToOneTargetFixture(title: "sibling")
        writer.insert(baseTarget)
        writer.insert(childTarget)
        writer.insert(siblingTarget)
        writer.insert(InheritedToOneChildFixture(target: baseTarget, childTarget: childTarget, age: 5))
        writer.insert(InheritedToOneSiblingFixture(target: nil, siblingTarget: siblingTarget))
        try writer.save()

        let rows = try XCTUnwrap(container.store).read {
            try $0.rows(
                "SELECT Z_ENT, ZINHERITEDTOONEBASEFIXTURE_TARGET, "
                    + "ZINHERITEDTOONECHILDFIXTURE_CHILDTARGET, ZINHERITEDTOONESIBLINGFIXTURE_SIBLINGTARGET "
                    + "FROM ZINHERITEDTOONEBASEFIXTURE ORDER BY Z_PK",
                arguments: [])
        }
        XCTAssertEqual(
            rows,
            [
                [.int(2), .int(1), .int(2), .null],
                [.int(3), .null, .null, .int(3)],
            ])

        let reader = container.makeContext()
        let fetched = try reader.fetch(
            FetchDescriptor<InheritedToOneBaseFixture>(
                relationshipKeyPathsForPrefetching: [\InheritedToOneBaseFixture.target]))
        let child = try XCTUnwrap(fetched.compactMap { $0 as? InheritedToOneChildFixture }.first)
        let sibling = try XCTUnwrap(fetched.compactMap { $0 as? InheritedToOneSiblingFixture }.first)
        XCTAssertTrue(
            InheritedToOneChildFixture.relationshipAdapterCandidatesForMutation().contains {
                $0.keyPath == \InheritedToOneChildFixture.childTarget
            })
        XCTAssertEqual(child.target?.title, "base")
        let fetchedChild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<InheritedToOneChildFixture>(
                    relationshipKeyPathsForPrefetching: [
                        \InheritedToOneChildFixture.target,
                        \InheritedToOneChildFixture.childTarget,
                    ])
            ).first)
        XCTAssertTrue(fetchedChild === child)
        XCTAssertEqual(child.childTarget?.title, "child")
        XCTAssertTrue(child.modelContext === reader)
        XCTAssertNil(sibling.target)
        let fetchedSibling = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<InheritedToOneSiblingFixture>(
                    relationshipKeyPathsForPrefetching: [\InheritedToOneSiblingFixture.siblingTarget])
            ).first)
        XCTAssertTrue(fetchedSibling === sibling)
        XCTAssertEqual(sibling.siblingTarget?.title, "sibling")

        let replacementTarget = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritedToOneTargetFixture>()).first { $0.title == "child" })
        child.target = replacementTarget
        XCTAssertTrue(child.hasChanges)
        XCTAssertTrue(child.target === replacementTarget)
        try reader.save()
        let reassigned = try container.store?.read {
            try $0.rows(
                "SELECT ZINHERITEDTOONEBASEFIXTURE_TARGET FROM ZINHERITEDTOONEBASEFIXTURE WHERE Z_PK = 1",
                arguments: [])
        }
        XCTAssertEqual(reassigned, [[.int(2)]])

        let verifier = container.makeContext()
        let verifiedChild = try XCTUnwrap(
            verifier.fetch(FetchDescriptor<InheritedToOneBaseFixture>()).compactMap {
                $0 as? InheritedToOneChildFixture
            }.first)
        let verifiedTarget = try XCTUnwrap(verifiedChild.target)
        XCTAssertEqual(verifiedTarget.title, "child")
        XCTAssertTrue(verifiedTarget.modelContext === verifier)

        child.setRelationshipValue(
            forKey: \InheritedToOneChildFixture.childTarget,
            to: fetchedChild.childTarget)
        reader.state.clearRelationshipMutationEvents()
        child.childTarget = nil
        XCTAssertEqual(reader.state.relationshipMutations.count, 1)
        XCTAssertNil(child.childTarget)
        XCTAssertTrue(child.hasChanges)
        try reader.save()
        let updated = try container.store?.read {
            try $0.rows(
                "SELECT ZINHERITEDTOONECHILDFIXTURE_CHILDTARGET FROM ZINHERITEDTOONEBASEFIXTURE WHERE Z_PK = 1",
                arguments: [])
        }
        XCTAssertEqual(updated, [[.null]])
    }

    @MainActor
    func testFlatToOneRelationshipMaterializesConcreteHierarchyDestination() throws {
        let container = try ModelContainer(
            for: [
                FlatHierarchyTargetOwnerFixture.self,
                PlainHierarchyTargetChildFixture.self,
                PlainHierarchyTargetGrandchildFixture.self,
                PlainHierarchyTargetSiblingFixture.self,
            ],
            configurations: [.sqliteMemory("flat-to-hierarchy-to-one")])
        let writer = container.mainContext
        let target = PlainHierarchyTargetGrandchildFixture(name: "target", detail: "detail", rank: 6)
        writer.insert(target)
        writer.insert(FlatHierarchyTargetOwnerFixture(title: "owner", target: target))
        try writer.save()

        let reader = container.makeContext()
        let owner = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<FlatHierarchyTargetOwnerFixture>(
                    relationshipKeyPathsForPrefetching: [\FlatHierarchyTargetOwnerFixture.target])
            ).first)
        let resolved = try XCTUnwrap(owner.target)
        XCTAssertTrue(resolved is PlainHierarchyTargetGrandchildFixture)
        XCTAssertEqual((resolved as? PlainHierarchyTargetGrandchildFixture)?.rank, 6)

        let lazyReader = container.makeContext()
        let lazyOwner = try XCTUnwrap(
            lazyReader.fetch(FetchDescriptor<FlatHierarchyTargetOwnerFixture>()).first)
        XCTAssertEqual((lazyOwner.target as? PlainHierarchyTargetGrandchildFixture)?.detail, "detail")
    }

    @MainActor
    func testDeletingHierarchyToOneDestinationNullifiesFlatOwnerFK() throws {
        let container = try ModelContainer(
            for: [
                FlatHierarchyTargetOwnerFixture.self,
                PlainHierarchyTargetChildFixture.self,
                PlainHierarchyTargetGrandchildFixture.self,
            ],
            configurations: [.sqliteMemory("flat-to-hierarchy-to-one-delete")])
        let context = container.mainContext
        let target = PlainHierarchyTargetGrandchildFixture(name: "target", detail: "detail", rank: 6)
        let owner = FlatHierarchyTargetOwnerFixture(title: "owner", target: target)
        context.insert(target)
        context.insert(owner)
        try context.save()

        context.delete(target)
        try context.save()

        let values = try container.store?.read {
            try $0.rows("SELECT ZTARGET FROM ZFLATHIERARCHYTARGETOWNERFIXTURE", arguments: [])
        }
        XCTAssertEqual(values, [[.null]])
        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(reader.fetch(FetchDescriptor<FlatHierarchyTargetOwnerFixture>()).first)
        XCTAssertNil(fetchedOwner.target)
    }

    @MainActor
    func testHierarchyToOneCascadeAndDenyDeleteRules() throws {
        let cascadeContainer = try ModelContainer(
            for: [CascadeHierarchyOwnerChildFixture.self, PlainHierarchyTargetGrandchildFixture.self],
            configurations: [.sqliteMemory("hierarchy-to-one-cascade")])
        let cascadeContext = cascadeContainer.mainContext
        let cascadedTarget = PlainHierarchyTargetGrandchildFixture(name: "target", detail: "cascade", rank: 1)
        let cascadeOwner = CascadeHierarchyOwnerChildFixture(name: "owner", target: cascadedTarget)
        cascadeContext.insert(cascadedTarget)
        cascadeContext.insert(cascadeOwner)
        try cascadeContext.save()
        cascadeContext.delete(cascadeOwner)
        try cascadeContext.save()
        XCTAssertTrue(try cascadeContext.fetch(FetchDescriptor<PlainHierarchyTargetBaseFixture>()).isEmpty)

        let denyContainer = try ModelContainer(
            for: [DenyHierarchyOwnerChildFixture.self, PlainHierarchyTargetGrandchildFixture.self],
            configurations: [.sqliteMemory("hierarchy-to-one-deny")])
        let denyContext = denyContainer.mainContext
        let deniedTarget = PlainHierarchyTargetGrandchildFixture(name: "target", detail: "deny", rank: 2)
        let denyOwner = DenyHierarchyOwnerChildFixture(name: "owner", target: deniedTarget)
        denyContext.insert(deniedTarget)
        denyContext.insert(denyOwner)
        try denyContext.save()
        denyContext.delete(denyOwner)
        XCTAssertFalse(denyOwner.isDeleted)
        XCTAssertFalse(denyContext.hasChanges)
        XCTAssertEqual(try denyContext.fetch(FetchDescriptor<DenyHierarchyOwnerBaseFixture>()).count, 1)
    }

    @MainActor
    func testHierarchyToOneRelationshipMaterializesBothConcreteTypes() throws {
        let container = try ModelContainer(
            for: [
                HierarchyToHierarchyOwnerChildFixture.self,
                PlainHierarchyTargetGrandchildFixture.self,
            ],
            configurations: [.sqliteMemory("hierarchy-to-hierarchy-to-one")])
        let context = container.mainContext
        let target = PlainHierarchyTargetGrandchildFixture(name: "target", detail: "detail", rank: 9)
        let owner = HierarchyToHierarchyOwnerChildFixture(name: "owner", target: target, rank: 3)
        context.insert(target)
        context.insert(owner)
        try context.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
                    relationshipKeyPathsForPrefetching: [\HierarchyToHierarchyOwnerChildFixture.target])
            )
            .first)
        XCTAssertTrue(fetched.target is PlainHierarchyTargetGrandchildFixture)
        XCTAssertEqual((fetched.target as? PlainHierarchyTargetGrandchildFixture)?.rank, 9)

        let lazyReader = container.makeContext()
        let lazyOwner = try XCTUnwrap(
            lazyReader.fetch(FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>()).first)
        XCTAssertEqual((lazyOwner.target as? PlainHierarchyTargetGrandchildFixture)?.detail, "detail")
    }

    @MainActor
    func testRootUniqueAttributeAppliesAcrossConcreteHierarchyTypes() throws {
        let container = try ModelContainer(
            for: [UniqueHierarchyChildFixture.self, UniqueHierarchySiblingFixture.self],
            configurations: [.sqliteMemory("hierarchy-root-unique")])
        XCTAssertTrue(
            container.schema.entity(forName: "UniqueHierarchyBaseFixture")?.attributes
                .first(where: { $0.name == "code" })?.options.contains(.unique) == true)
        XCTAssertTrue(
            container.schema.entity(forName: "UniqueHierarchyChildFixture")?.attributes
                .first(where: { $0.name == "code" })?.options.contains(.unique) == true)
        let indexes = try container.store?.read {
            try $0.rows(
                "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND name LIKE '%UNIQUE%'",
                arguments: [])
        }
        XCTAssertEqual(
            indexes,
            [
                [
                    .text("ZUNIQUEHIERARCHYBASEFIXTURE_ZCODE_UNIQUE_INDEX"),
                    .text(
                        "CREATE UNIQUE INDEX ZUNIQUEHIERARCHYBASEFIXTURE_ZCODE_UNIQUE_INDEX ON ZUNIQUEHIERARCHYBASEFIXTURE (ZCODE)"
                    ),
                ]
            ])
        let context = container.mainContext
        let original = UniqueHierarchyChildFixture(code: "shared", value: 1)
        context.insert(original)
        try context.save()
        let originalPK = try XCTUnwrap(original.persistentModelID.primaryKey)
        let beforeDuplicate = try container.store?.read {
            try $0.rows("SELECT ZCODE, Z_ENT FROM ZUNIQUEHIERARCHYBASEFIXTURE", arguments: [])
        }
        XCTAssertEqual(beforeDuplicate, [[.text("shared"), .int(2)]])
        let replacement = UniqueHierarchySiblingFixture(code: "shared", label: "replacement")
        context.insert(replacement)
        try context.save()

        XCTAssertEqual(replacement.persistentModelID.primaryKey, originalPK)
        XCTAssertEqual(replacement.persistentModelID.entityName, "UniqueHierarchySiblingFixture")
        XCTAssertNil(original.modelContext)
        let afterDuplicate = try container.store?.read {
            try $0.rows(
                "SELECT ZCODE, Z_ENT FROM ZUNIQUEHIERARCHYBASEFIXTURE WHERE Z_PK = ?",
                arguments: [.int(try XCTUnwrap(replacement.persistentModelID.primaryKey))])
        }
        XCTAssertEqual(
            afterDuplicate,
            [
                [
                    .text("shared"),
                    .int(Int64(try XCTUnwrap(container.schema.entityIDsByName["UniqueHierarchySiblingFixture"]))),
                ]
            ]
        )
        let records = try context.fetch(FetchDescriptor<UniqueHierarchyBaseFixture>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual((records.first as? UniqueHierarchySiblingFixture)?.label, "replacement")
    }

    @MainActor
    func testSubtypeUniqueScopeExcludesSiblingsAndIncludesDescendants() throws {
        let container = try ModelContainer(
            for: SubtypeUniqueBaseFixture.self,
            SubtypeUniqueChildFixture.self,
            SubtypeUniqueGrandchildFixture.self,
            SubtypeUniqueSiblingFixture.self,
            configurations: .sqliteMemory("subtype-unique-scope"))
        let context = container.mainContext
        let root = SubtypeUniqueBaseFixture(token: "shared")
        let sibling = SubtypeUniqueSiblingFixture(token: "shared", scopedKey: "same", label: "sibling")
        let child = SubtypeUniqueChildFixture(token: "shared", scopedKey: "same", tenant: "acme", score: 5)
        context.insert(root)
        context.insert(sibling)
        context.insert(child)
        try context.save()
        XCTAssertTrue(
            container.schema.entity(forName: "SubtypeUniqueChildFixture")?.attributes
                .first(where: { $0.name == "scopedKey" })?.options.contains(.unique) == true)
        XCTAssertTrue(
            container.schema.entity(forName: "SubtypeUniqueSiblingFixture")?.attributes
                .first(where: { $0.name == "scopedKey" })?.options.contains(.unique) == true)
        let uniqueIndexes: [[RuntimeValue]]? = try container.store?.read {
            try $0.rows(
                "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND name LIKE '%UNIQUE%' ORDER BY name",
                arguments: [])
        }
        XCTAssertTrue(
            uniqueIndexes?.contains(where: { row in
                row == [
                    .text("ZSUBTYPEUNIQUEBASEFIXTURE_SUBTYPEUNIQUECHILDFIXTURE_ZTENANT_ZSCORE_UNIQUE_INDEX"),
                    .text(
                        "CREATE UNIQUE INDEX ZSUBTYPEUNIQUEBASEFIXTURE_SUBTYPEUNIQUECHILDFIXTURE_ZTENANT_ZSCORE_UNIQUE_INDEX ON ZSUBTYPEUNIQUEBASEFIXTURE (ZTENANT, ZSCORE) WHERE Z_ENT IN (2, 3)"
                    ),
                ]
            }) == true)
        XCTAssertTrue(
            uniqueIndexes?.contains(where: { row in
                row == [
                    .text("ZSUBTYPEUNIQUEBASEFIXTURE_SUBTYPEUNIQUECHILDFIXTURE_ZSCOPEDKEY_UNIQUE_INDEX"),
                    .text(
                        "CREATE UNIQUE INDEX ZSUBTYPEUNIQUEBASEFIXTURE_SUBTYPEUNIQUECHILDFIXTURE_ZSCOPEDKEY_UNIQUE_INDEX ON ZSUBTYPEUNIQUEBASEFIXTURE (ZSCOPEDKEY) WHERE Z_ENT IN (2, 3)"
                    ),
                ]
            }) == true)
        let childID = try XCTUnwrap(child.persistentModelID.primaryKey)

        let grandchildDuplicate = SubtypeUniqueGrandchildFixture(
            token: "grandchild", scopedKey: "different", tenant: "acme", score: 5, rank: 1)
        context.insert(grandchildDuplicate)
        try context.save()
        XCTAssertEqual(grandchildDuplicate.persistentModelID.primaryKey, childID)
        let storedUniqueValue: [RuntimeValue]? = try container.store?.read {
            try $0.rows(
                "SELECT Z_PK, Z_ENT, ZSCOPEDKEY FROM ZSUBTYPEUNIQUEBASEFIXTURE WHERE Z_PK = ?",
                arguments: [.int(childID)]
            ).first ?? []
        }
        let grandchildEntityID = Int64(
            try XCTUnwrap(container.schema.entityIDsByName["SubtypeUniqueGrandchildFixture"]))
        XCTAssertEqual(storedUniqueValue, [.int(childID), .int(grandchildEntityID), .text("different")])

        let attributeUniqueMatch = SubtypeUniqueChildFixture(
            token: "different-token", scopedKey: "different", tenant: "other", score: 10)
        context.insert(attributeUniqueMatch)
        try context.save()
        XCTAssertEqual(attributeUniqueMatch.persistentModelID.primaryKey, childID)

        let rows: [[RuntimeValue]]? = try container.store?.read {
            try $0.rows("SELECT Z_ENT, ZSCORE FROM ZSUBTYPEUNIQUEBASEFIXTURE ORDER BY Z_PK", arguments: [])
        }
        let baseID = Int64(try XCTUnwrap(container.schema.entityIDsByName["SubtypeUniqueBaseFixture"]))
        let siblingID = Int64(try XCTUnwrap(container.schema.entityIDsByName["SubtypeUniqueSiblingFixture"]))
        let childEntityID = Int64(try XCTUnwrap(container.schema.entityIDsByName["SubtypeUniqueChildFixture"]))
        XCTAssertEqual(
            rows, [[.int(baseID), .null], [.int(childEntityID), .int(10)], [.int(siblingID), .null]])

        let indexes: [[RuntimeValue]]? = try container.store?.read {
            try $0.rows("SELECT name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name", arguments: [])
        }
        XCTAssertTrue(
            indexes?.contains([
                .text("ZSUBTYPEUNIQUEBASEFIXTURE_SUBTYPEUNIQUECHILDFIXTURE_ZSCORE_INDEX"),
                .text(
                    "CREATE INDEX ZSUBTYPEUNIQUEBASEFIXTURE_SUBTYPEUNIQUECHILDFIXTURE_ZSCORE_INDEX ON ZSUBTYPEUNIQUEBASEFIXTURE (ZSCORE) WHERE Z_ENT IN (2, 3)"
                ),
            ]) == true)
        let plan: [[RuntimeValue]]? = try container.store?.read {
            try $0.rows(
                "EXPLAIN QUERY PLAN SELECT Z_PK FROM ZSUBTYPEUNIQUEBASEFIXTURE WHERE Z_ENT IN (2, 3) AND ZSCORE = ?",
                arguments: [.int(5)])
        }
        XCTAssertTrue(
            plan?.contains(where: {
                $0.contains(
                    where: {
                        if case let .text(value) = $0 {
                            value.contains("ZSUBTYPEUNIQUEBASEFIXTURE_SUBTYPEUNIQUECHILDFIXTURE_ZSCORE_INDEX")
                        } else {
                            false
                        }
                    })
            })
                == true,
            "Unexpected query plan: \(String(describing: plan))")
    }

    @MainActor
    func testHierarchyUniqueConstraintsMatchingDifferentRowsFailAtomically() throws {
        let container = try ModelContainer(
            for: SubtypeUniqueBaseFixture.self,
            SubtypeUniqueChildFixture.self,
            SubtypeUniqueGrandchildFixture.self,
            SubtypeUniqueSiblingFixture.self,
            configurations: .sqliteMemory("hierarchy-conflicting-unique-matches"))
        let context = container.mainContext
        context.insert(
            SubtypeUniqueChildFixture(token: "first", scopedKey: "key-one", tenant: "tenant-one", score: 1))
        context.insert(
            SubtypeUniqueChildFixture(token: "second", scopedKey: "key-two", tenant: "tenant-two", score: 2))
        try context.save()
        let childEntity = try XCTUnwrap(container.schema.entity(forName: "SubtypeUniqueChildFixture"))
        XCTAssertTrue(
            childEntity.attributes.first(where: { $0.name == "scopedKey" })?.options.contains(.unique) == true)
        XCTAssertTrue(childEntity.indexes.contains(Schema.Index(properties: ["scopedKey"], isUnique: true)))
        let before = try container.store?.read {
            try $0.rows(
                "SELECT Z_PK, Z_ENT, ZTOKEN, ZSCOPEDKEY, ZTENANT, ZSCORE FROM ZSUBTYPEUNIQUEBASEFIXTURE",
                arguments: [])
        }

        context.insert(
            SubtypeUniqueChildFixture(token: "new", scopedKey: "key-one", tenant: "tenant-two", score: 2))
        XCTAssertThrowsError(try context.save())

        let after = try container.store?.read {
            try $0.rows(
                "SELECT Z_PK, Z_ENT, ZTOKEN, ZSCOPEDKEY, ZTENANT, ZSCORE FROM ZSUBTYPEUNIQUEBASEFIXTURE",
                arguments: [])
        }
        XCTAssertEqual(after, before)
        XCTAssertTrue(context.hasChanges)
    }

    @MainActor
    func testHierarchyToHierarchyOneToManyInverseRoundTrips() throws {
        let container = try ModelContainer(
            for: [HierarchyOwnerChildFixture.self, HierarchyTargetGrandchildFixture.self],
            configurations: [.sqliteMemory("hierarchy-to-hierarchy-inverse")])
        XCTAssertEqual(
            container.schema.entity(forName: "HierarchyTargetChildFixture")?.relationships
                .first(where: { $0.name == "owners" })?.inverse,
            "target")
        let writer = container.mainContext
        let target = HierarchyTargetGrandchildFixture(name: "target", detail: "detail", rank: 7)
        let owner = HierarchyOwnerChildFixture(name: "owner", target: target)
        writer.insert(target)
        writer.insert(owner)
        try writer.save()

        let reader = container.makeContext()
        let fetchedTarget = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<HierarchyTargetChildFixture>(
                    relationshipKeyPathsForPrefetching: [\HierarchyTargetChildFixture.owners])
            ).first)
        XCTAssertEqual(fetchedTarget.owners.map(\.name), ["owner"])
        XCTAssertTrue(fetchedTarget.owners.first?.target === fetchedTarget)
        XCTAssertTrue(fetchedTarget.owners.first?.target is HierarchyTargetGrandchildFixture)

        let lazyReader = container.makeContext()
        let lazyOwner = try XCTUnwrap(
            lazyReader.fetch(FetchDescriptor<HierarchyOwnerChildFixture>()).first)
        let lazyTarget = try XCTUnwrap(lazyOwner.target)
        let lazyTargetChild = try XCTUnwrap(lazyTarget as? HierarchyTargetChildFixture)
        XCTAssertEqual(lazyTargetChild.owners.map(\.name), ["owner"])

        fetchedTarget.owners = []
        try reader.save()
        let foreignKeys = try container.store?.read {
            try $0.rows(
                "SELECT ZHIERARCHYOWNERCHILDFIXTURE_TARGET FROM ZHIERARCHYOWNERBASEFIXTURE",
                arguments: [])
        }
        XCTAssertEqual(foreignKeys, [[.null]])
    }

    @MainActor
    func testPredicateTraversesOptionalToOneIntoHierarchyDestination() throws {
        let container = try ModelContainer(
            for: HierarchyToHierarchyOwnerChildFixture.self,
            PlainHierarchyTargetGrandchildFixture.self,
            configurations: .sqliteMemory("hierarchy-to-one-predicate"))
        let context = container.mainContext
        let selectedTarget = PlainHierarchyTargetGrandchildFixture(name: "selected", detail: "detail", rank: 4)
        let otherTarget = PlainHierarchyTargetChildFixture(name: "other", detail: "other")
        context.insert(selectedTarget)
        context.insert(otherTarget)
        context.insert(HierarchyToHierarchyOwnerChildFixture(name: "matched", target: selectedTarget, rank: 1))
        context.insert(HierarchyToHierarchyOwnerChildFixture(name: "other", target: otherTarget, rank: 2))
        context.insert(HierarchyToHierarchyOwnerChildFixture(name: "nil", target: nil, rank: 3))
        try context.save()

        let descriptor = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name == "selected" })
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.map(\.name), ["matched"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), fetched.map(\.persistentModelID))
        let storedOnly = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name == "selected" },
            sortBy: [SortDescriptor(\HierarchyToHierarchyOwnerChildFixture.name)],
            fetchLimit: 1,
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(storedOnly).map(\.name), ["matched"])

        let nilTarget = try context.fetch(
            FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(predicate: #Predicate { $0.target?.name == nil }))
        XCTAssertEqual(nilTarget.map(\.name), ["nil"])

        let containsNeedle = "lect"
        let relationshipContains = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name.contains(containsNeedle) == true },
            includePendingChanges: false)
        let containedOwners = try context.fetch(relationshipContains)
        XCTAssertEqual(containedOwners.map(\.name), ["matched"])
        XCTAssertEqual(try context.fetchCount(relationshipContains), 1)
        XCTAssertEqual(try context.fetchIdentifiers(relationshipContains), containedOwners.map(\.persistentModelID))

        let prefix = "sel"
        let relationshipPrefix = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name.starts(with: prefix) == true },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(relationshipPrefix).map(\.name), ["matched"])

        selectedTarget.name = "pending-selected"
        let pendingString = "selected"
        let committedOnlyAfterTargetEdit = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name.contains(pendingString) == true },
            includePendingChanges: false)
        let committedAfterTargetEdit = try context.fetch(committedOnlyAfterTargetEdit)
        XCTAssertEqual(committedAfterTargetEdit.map(\.name), ["matched"])
        XCTAssertEqual(try context.fetchCount(committedOnlyAfterTargetEdit), 1)
        XCTAssertEqual(
            try context.fetchIdentifiers(committedOnlyAfterTargetEdit),
            committedAfterTargetEdit.map(\.persistentModelID))
        let pendingOnlyString = "pending"
        let pendingContains = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name.contains(pendingOnlyString) == true })
        let pendingContainedOwners = try context.fetch(pendingContains)
        XCTAssertEqual(pendingContainedOwners.map(\.name), ["matched"])
        XCTAssertEqual(try context.fetchCount(pendingContains), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingContains), pendingContainedOwners.map(\.persistentModelID))
        let committedOnlyPendingString = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name.contains(pendingOnlyString) == true },
            includePendingChanges: false)
        XCTAssertTrue(try context.fetch(committedOnlyPendingString).isEmpty)
        XCTAssertEqual(try context.fetchCount(committedOnlyPendingString), 0)
        XCTAssertTrue(try context.fetchIdentifiers(committedOnlyPendingString).isEmpty)

        let insertedTarget = PlainHierarchyTargetChildFixture(name: "pending-selected", detail: "pending")
        let insertedOwner = HierarchyToHierarchyOwnerChildFixture(name: "pending", target: insertedTarget, rank: 4)
        context.insert(insertedTarget)
        context.insert(insertedOwner)
        let pendingDescriptor = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name == "pending-selected" })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(pendingMatches.map(\.name), ["matched", "pending"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))
        let pendingPage = try context.fetch(
            FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
                predicate: #Predicate { $0.target?.name == "pending-selected" },
                sortBy: [SortDescriptor(\HierarchyToHierarchyOwnerChildFixture.name)],
                fetchLimit: 1,
                fetchOffset: 1,
                includePendingChanges: true))
        XCTAssertEqual(pendingPage.map(\.name), ["pending"])

        selectedTarget.name = "renamed-pending"
        let renamedDescriptor = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name == "renamed-pending" })
        let renamedOwners = try context.fetch(renamedDescriptor)
        XCTAssertEqual(renamedOwners.map(\.name), ["matched"])
        XCTAssertEqual(try context.fetchCount(renamedDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(renamedDescriptor), renamedOwners.map(\.persistentModelID))
    }

    @MainActor
    func testPredicateUsesSubtypeToOneDestinationDiscriminator() throws {
        let container = try ModelContainer(
            for: PlainHierarchyChildTargetOwnerFixture.self,
            PlainHierarchyTargetGrandchildFixture.self,
            PlainHierarchyTargetSiblingFixture.self,
            configurations: .sqliteMemory("subtype-to-one-predicate"))
        let context = container.mainContext
        let grandchild = PlainHierarchyTargetGrandchildFixture(name: "target", detail: "needle", rank: 7)
        context.insert(grandchild)
        context.insert(
            PlainHierarchyChildTargetOwnerFixture(name: "matched", detail: "owner-mismatch", target: grandchild))
        context.insert(PlainHierarchyChildTargetOwnerFixture(name: "nil", detail: "needle", target: nil))
        try context.save()

        let needle = "needle"
        let descriptor = FetchDescriptor<PlainHierarchyChildTargetOwnerFixture>(
            predicate: #Predicate { $0.target?.detail.contains(needle) == true },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.name), ["matched"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))
    }

    @MainActor
    func testPendingToOneStringPredicateResolvesUnloadedDestination() throws {
        let container = try ModelContainer(
            for: HierarchyToHierarchyOwnerChildFixture.self,
            PlainHierarchyTargetGrandchildFixture.self,
            configurations: .sqliteMemory("pending-to-one-string-fault"))
        let writer = container.mainContext
        let target = PlainHierarchyTargetGrandchildFixture(name: "before", detail: "detail", rank: 1)
        writer.insert(target)
        writer.insert(HierarchyToHierarchyOwnerChildFixture(name: "owner", target: target, rank: 1))
        try writer.save()

        let reader = container.makeContext()
        let owner = try XCTUnwrap(
            reader.fetch(FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>()).first)
        let targetID = target.persistentModelID
        let readerTargetValue: PlainHierarchyTargetGrandchildFixture? = try reader.model(for: targetID)
        let readerTarget = try XCTUnwrap(readerTargetValue)
        readerTarget.name = "pending-match"
        let needle = "match"
        let descriptor = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name.contains(needle) == true })
        XCTAssertEqual(owner.name, "owner")
        XCTAssertEqual(try reader.fetch(descriptor).map(\.name), ["owner"])
    }

    @MainActor
    func testOneSidedInverseInfersReciprocalOptionalToOneAdapter() throws {
        let container = try ModelContainer(
            for: InferredToOneLeftFixture.self,
            InferredToOneRightFixture.self,
            configurations: .sqliteMemory("inferred-reciprocal-to-one"))
        let context = container.mainContext
        let left = InferredToOneLeftFixture(title: "left")
        let right = InferredToOneRightFixture(name: "right")
        context.insert(left)
        context.insert(right)
        left.right = right
        try context.save()

        let rightRelationship = try XCTUnwrap(
            container.schema.entity(forName: "InferredToOneRightFixture")?.relationships
                .first(where: { $0.name == "left" }))
        XCTAssertEqual(rightRelationship.inverse, "right")
        let rightAdapters = container.relationshipAdapters(for: InferredToOneRightFixture.self)
        let leftAdapters = container.relationshipAdapters(for: InferredToOneLeftFixture.self)
        XCTAssertEqual(rightAdapters.map(\.name), ["left"])
        XCTAssertEqual(leftAdapters.map(\.name), ["right"])
        XCTAssertEqual(rightAdapters.first?.keyPath, \InferredToOneRightFixture.left)
        XCTAssertEqual(rightAdapters.first?.metadata?.inverse, "right")
        XCTAssertEqual(right.left?.persistentModelID, left.persistentModelID)

        let selectedTitle = "left"
        let descriptor = FetchDescriptor<InferredToOneRightFixture>(
            predicate: #Predicate { $0.left?.title == selectedTitle },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.name), ["right"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        let secondLeft = InferredToOneLeftFixture(title: "second")
        context.insert(secondLeft)
        try context.save()
        try XCTUnwrap(container.store).write { connection in
            try connection.execute(
                "UPDATE ZINFERREDTOONELEFTFIXTURE SET ZRIGHT = ? WHERE Z_PK = ?",
                arguments: [.int(1), .int(2)])
        }

        let duplicateReader = container.makeContext()
        let duplicateRight = try XCTUnwrap(
            duplicateReader.fetch(FetchDescriptor<InferredToOneRightFixture>()).first)
        XCTAssertEqual(duplicateRight.left?.title, "left")
        let duplicateTitle = "second"
        let duplicateDescriptor = FetchDescriptor<InferredToOneRightFixture>(
            predicate: #Predicate { $0.left?.title == duplicateTitle },
            includePendingChanges: false)
        XCTAssertTrue(try duplicateReader.fetch(duplicateDescriptor).isEmpty)
        XCTAssertEqual(try duplicateReader.fetchCount(duplicateDescriptor), 0)

        let pendingFirst = InferredToOneLeftFixture(title: "pending-first")
        let pendingLast = InferredToOneLeftFixture(title: "pending-last")
        context.insert(pendingFirst)
        context.insert(pendingLast)
        pendingFirst.right = right
        pendingLast.right = right
        let pendingLastTitle = "pending-last"
        let pendingInverseDescriptor = FetchDescriptor<InferredToOneRightFixture>(
            predicate: #Predicate { $0.left?.title == pendingLastTitle })
        XCTAssertEqual(try context.fetch(pendingInverseDescriptor).map(\.name), ["right"])
        let pendingFirstTitle = "pending-first"
        let displacedInverseDescriptor = FetchDescriptor<InferredToOneRightFixture>(
            predicate: #Predicate { $0.left?.title == pendingFirstTitle })
        XCTAssertTrue(try context.fetch(displacedInverseDescriptor).isEmpty)

        right.left = nil
        XCTAssertTrue(context.hasChanges)
        try context.save()
        XCTAssertNil(left.right)

        let pendingTitle = "reassigned"
        let replacement = InferredToOneLeftFixture(title: pendingTitle)
        context.insert(replacement)
        replacement.right = right
        let pendingDescriptor = FetchDescriptor<InferredToOneRightFixture>(
            predicate: #Predicate { $0.left?.title == pendingTitle })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["right"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [right.persistentModelID])
    }

    @MainActor
    func testOneSidedInverseToManyCollectionLifecycle() throws {
        let container = try ModelContainer(
            for: InverseCollectionLifecycleOwnerFixture.self,
            InverseCollectionLifecycleItemFixture.self,
            configurations: .sqliteMemory("one-sided-inverse-collection-lifecycle"))
        let context = container.mainContext
        let owner = InverseCollectionLifecycleOwnerFixture(name: "owner")
        let item = InverseCollectionLifecycleItemFixture(value: "saved", owner: nil)
        context.insert(owner)
        context.insert(item)
        item.owner = owner
        try context.save()

        let ownerAdapter = try XCTUnwrap(
            container.relationshipAdapters(for: InverseCollectionLifecycleOwnerFixture.self)
                .first(where: { $0.name == "items" }))
        XCTAssertEqual(ownerAdapter.metadata?.inverse, "owner")
        XCTAssertEqual(owner.items.map(\.value), ["saved"])

        let reader = container.makeContext()
        let fetchedOwner = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InverseCollectionLifecycleOwnerFixture>()).first)
        XCTAssertEqual(fetchedOwner.items.map(\.value), ["saved"])

        let pendingItem = InverseCollectionLifecycleItemFixture(value: "pending", owner: nil)
        context.insert(pendingItem)
        pendingItem.owner = owner
        let inverseEvents = context.state.relationshipMutations.filter { $0.property == "items" }
        XCTAssertEqual(inverseEvents.last?.oldEndpoints.map(\.persistentModelID), [item.persistentModelID])
        XCTAssertEqual(
            Set(inverseEvents.last?.newEndpoints.map(\.persistentModelID) ?? []),
            Set([item.persistentModelID, pendingItem.persistentModelID]))
        XCTAssertEqual(Set(owner.items.map(\.value)), ["saved", "pending"])
        try context.save()
        XCTAssertEqual(Set(owner.items.map(\.value)), ["saved", "pending"])
    }

    @MainActor
    func testDetachedOneSidedInverseToManyMutatesBothSides() throws {
        let owner = InverseCollectionLifecycleOwnerFixture(name: "detached owner")
        XCTAssertTrue(owner.items.isEmpty)
        let item = InverseCollectionLifecycleItemFixture(value: "detached item", owner: nil)
        XCTAssertEqual(
            (InverseCollectionLifecycleItemFixture.schemaMetadata()
                .first(where: { $0.name == "owner" })?.metadata?.base as? Schema.Relationship)?.inverse,
            "items")
        XCTAssertEqual(
            InverseCollectionLifecycleOwnerFixture.relationshipAdapterCandidatesForMutation().map(\.name), ["items"])
        item.owner = owner
        XCTAssertEqual(owner.items.map(\.value), ["detached item"])

        let secondOwner = InverseCollectionLifecycleOwnerFixture(name: "second owner")
        item.owner = secondOwner
        XCTAssertTrue(owner.items.isEmpty)
        XCTAssertEqual(secondOwner.items.map(\.value), ["detached item"])
        item.owner = nil
        XCTAssertTrue(secondOwner.items.isEmpty)

        item.owner = owner
        let container = try ModelContainer(
            for: InverseCollectionLifecycleOwnerFixture.self,
            InverseCollectionLifecycleItemFixture.self,
            configurations: .sqliteMemory("detached-inverse-insert-idempotence"))
        container.mainContext.insert(owner)
        container.mainContext.insert(item)
        try container.mainContext.save()
        XCTAssertEqual(owner.items.map(\.value), ["detached item"])
    }

    @MainActor
    func testDetachedOneToOneInverseDisplacesPreviousOwner() throws {
        let right = InferredToOneRightFixture(name: "right")
        let first = InferredToOneLeftFixture(title: "first")
        let second = InferredToOneLeftFixture(title: "second")
        first.right = right
        XCTAssertTrue(right.left === first)

        second.right = right
        XCTAssertNil(first.right)
        XCTAssertTrue(right.left === second)

        second.right = nil
        XCTAssertNil(right.left)
    }

    @MainActor
    func testDetachedSetterInfersReciprocalExplicitInverseKeyPath() throws {
        let left = InferredToOneLeftFixture(title: "left")
        let right = InferredToOneRightFixture(name: "right")
        let rightMetadata =
            InferredToOneLeftFixture.schemaMetadata()
            .first(where: { $0.name == "right" })?.metadata?.base as? Schema.Relationship
        XCTAssertEqual(rightMetadata?.inverse, "left")
        right.left = left
        XCTAssertTrue(left.right === right)

        right.left = nil
        XCTAssertNil(left.right)
    }

    @MainActor
    func testDetachedManyToManyInverseAssignmentMutatesBothSides() throws {
        let left = DetachedManyToManyLeftFixture(name: "left")
        let right = DetachedManyToManyRightFixture(name: "right")
        let rightsMetadata =
            DetachedManyToManyLeftFixture.schemaMetadata()
            .first(where: { $0.name == "rights" })?.metadata?.base as? Schema.Relationship
        XCTAssertEqual(rightsMetadata?.inverse, "lefts")
        let reciprocal = try XCTUnwrap(
            DetachedManyToManyRightFixture.relationshipAdapterCandidatesForMutation().first {
                $0.name == "lefts"
            })
        XCTAssertTrue(reciprocal.isToMany)
        XCTAssertEqual(try reciprocal.endpoints(in: reciprocal.makeInverseValue([left]) as Any).count, 1)
        left.rights = [right]
        XCTAssertEqual(left.rights.map(\.name), ["right"])
        XCTAssertEqual(right.lefts.map(\.name), ["left"])

        left.rights = []
        XCTAssertTrue(left.rights.isEmpty)
        XCTAssertTrue(right.lefts.isEmpty)
    }

    @MainActor
    func testDetachedArrayAppendRoutesThroughRelationshipMutation() throws {
        let owner = InverseCollectionLifecycleOwnerFixture(name: "owner")
        let first = InverseCollectionLifecycleItemFixture(value: "first", owner: nil)
        owner.items.append(first)
        XCTAssertTrue(first.owner === owner)
        XCTAssertEqual(owner.items.map(\.value), ["first"])

        let left = DetachedManyToManyLeftFixture(name: "left")
        let right = DetachedManyToManyRightFixture(name: "right")
        left.rights.append(right)
        XCTAssertTrue(right.lefts.contains(where: { $0 === left }))

        let container = try ModelContainer(
            for: InverseCollectionLifecycleOwnerFixture.self,
            InverseCollectionLifecycleItemFixture.self,
            configurations: .sqliteMemory("managed-relationship-array-append"))
        let managedOwner = InverseCollectionLifecycleOwnerFixture(name: "managed owner")
        container.mainContext.insert(managedOwner)
        let managedItem = InverseCollectionLifecycleItemFixture(value: "managed", owner: nil)
        container.mainContext.insert(managedItem)
        managedOwner.items.append(managedItem)
        XCTAssertTrue(managedItem.owner === managedOwner)
    }

    @MainActor
    func testDetachedManyToManyAppendUpdatesInverseAfterExistingOwner() throws {
        let firstOwner = DetachedManyToManyLeftFixture(name: "first")
        let secondOwner = DetachedManyToManyLeftFixture(name: "second")
        let right = DetachedManyToManyRightFixture(name: "right")
        firstOwner.rights = [right]
        XCTAssertEqual(right.lefts.map(\.name), ["first"])

        secondOwner.rights.append(right)
        XCTAssertEqual(secondOwner.rights.map(\.name), ["right"])
        XCTAssertEqual(Set(right.lefts.map(\.name)), ["first", "second"])
    }

    @MainActor
    func testDetachedInverseUsesExplicitKeyPathWhenMultipleOwnerLinksExist() throws {
        let owner = DetachedInverseAmbiguityOwnerFixture(name: "owner")
        let target = DetachedInverseAmbiguityTargetFixture(name: "target")
        owner.targets = [target]
        XCTAssertTrue(target.primaryOwner === owner)
        XCTAssertNil(target.secondaryOwner)

        owner.targets = []
        XCTAssertNil(target.primaryOwner)
        XCTAssertNil(target.secondaryOwner)
    }

    @MainActor
    func testDetachedRelationshipDoesNotMutateContextOwnedEndpoint() throws {
        let container = try ModelContainer(
            for: DetachedManyToManyLeftFixture.self,
            DetachedManyToManyRightFixture.self,
            configurations: .sqliteMemory("detached-to-managed-relationship"))
        let managedRight = DetachedManyToManyRightFixture(name: "managed")
        container.mainContext.insert(managedRight)
        try container.mainContext.save()

        let detachedLeft = DetachedManyToManyLeftFixture(name: "detached")
        detachedLeft.rights = [managedRight]
        XCTAssertEqual(detachedLeft.rights.map(\.name), ["managed"])
        XCTAssertTrue(managedRight.lefts.isEmpty)
        XCTAssertTrue(container.mainContext.hasChanges == false)
    }

    @MainActor
    func testUnregisteredCodableCollectionsRemainAttributesWithInferenceEnabled() throws {
        let container = try ModelContainer(
            for: InferredRelationshipCodableFallbackFixture.self,
            configurations: .sqliteMemory("inferred-codable-collection-fallback"))
        let attributes = try XCTUnwrap(
            container.schema.entity(forName: "InferredRelationshipCodableFallbackFixture")
        )
        .attributes
        XCTAssertEqual(Set(attributes.map(\.name)), ["values", "optionalValues"])

        let context = container.mainContext
        let model = InferredRelationshipCodableFallbackFixture(
            values: [CodableRelationshipFallbackValue(value: "stored")],
            optionalValues: [CodableRelationshipFallbackValue(value: "optional")])
        context.insert(model)
        try context.save()
        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<InferredRelationshipCodableFallbackFixture>()).first)
        XCTAssertEqual(fetched.values, model.values)
        XCTAssertEqual(fetched.optionalValues, model.optionalValues)
    }

    @MainActor
    func testOptionalInferredModelCollectionPreservesNilAndEmptyValues() throws {
        let container = try ModelContainer(
            for: InferredOptionalCollectionOwnerFixture.self,
            InferredOptionalCollectionTargetFixture.self,
            configurations: .sqliteMemory("optional-inferred-model-collection"))
        let context = container.mainContext
        let nilOwner = InferredOptionalCollectionOwnerFixture(targets: nil)
        let emptyOwner = InferredOptionalCollectionOwnerFixture(targets: [])
        context.insert(nilOwner)
        context.insert(emptyOwner)
        XCTAssertEqual(nilOwner.targets?.count, 0)
        XCTAssertEqual(emptyOwner.targets?.count, 0)
        try context.save()

        let reader = container.makeContext()
        let storedOwners = try reader.fetch(FetchDescriptor<InferredOptionalCollectionOwnerFixture>())
        XCTAssertEqual(storedOwners.count, 2)
        XCTAssertTrue(storedOwners.allSatisfy { $0.targets?.isEmpty == true })

        let target = InferredOptionalCollectionTargetFixture(name: "target")
        nilOwner.targets = [target]
        XCTAssertTrue(context.hasChanges)
        try context.save()
        XCTAssertEqual(nilOwner.targets?.map(\.name), ["target"])

        nilOwner.targets = nil
        try context.save()
        let finalReader = container.makeContext()
        let reloadedOwner = try XCTUnwrap(
            finalReader.fetch(FetchDescriptor<InferredOptionalCollectionOwnerFixture>()).first {
                $0.persistentModelID == nilOwner.persistentModelID
            })
        XCTAssertEqual(reloadedOwner.targets?.count, 0)
    }

    @MainActor
    func testOptionalInferredModelSetPreservesRelationshipEndpoints() throws {
        let container = try ModelContainer(
            for: InferredOptionalSetOwnerFixture.self,
            InferredOptionalCollectionTargetFixture.self,
            configurations: .sqliteMemory("optional-inferred-model-set"))
        let adapter = try XCTUnwrap(
            container.relationshipAdapters(for: InferredOptionalSetOwnerFixture.self).first)
        XCTAssertEqual(adapter.name, "targets")
        XCTAssertEqual(String(describing: adapter.destinationType), "InferredOptionalCollectionTargetFixture")
        XCTAssertTrue(adapter.isToMany)
        let context = container.mainContext
        let owner = InferredOptionalSetOwnerFixture(targets: nil)
        context.insert(owner)
        XCTAssertEqual(owner.targets?.count, 0)
        try context.save()

        let target = InferredOptionalCollectionTargetFixture(name: "set-target")
        owner.targets = [target]
        try context.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<InferredOptionalSetOwnerFixture>()).first)
        XCTAssertEqual(fetched.targets?.map(\.name), ["set-target"])

        owner.targets = nil
        try context.save()
        let finalReader = container.makeContext()
        let reloaded = try XCTUnwrap(finalReader.fetch(FetchDescriptor<InferredOptionalSetOwnerFixture>()).first)
        XCTAssertEqual(reloaded.targets?.count, 0)
    }

    @MainActor
    func testInferredSetRelationshipSupportsIsEmptyPredicate() throws {
        let container = try ModelContainer(
            for: InferredSetOwnerFixture.self,
            InferredOptionalCollectionTargetFixture.self,
            configurations: .sqliteMemory("inferred-set-is-empty"))
        let context = container.mainContext
        let item = InferredOptionalCollectionTargetFixture(name: "set-item")
        let emptyOwner = InferredSetOwnerFixture(targets: [])
        let populatedOwner = InferredSetOwnerFixture(targets: [item])
        context.insert(item)
        context.insert(emptyOwner)
        context.insert(populatedOwner)
        try context.save()

        let descriptor = FetchDescriptor<InferredSetOwnerFixture>(
            predicate: #Predicate { $0.targets.isEmpty },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.persistentModelID), [emptyOwner.persistentModelID])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        let oneTarget = 1
        let countDescriptor = FetchDescriptor<InferredSetOwnerFixture>(
            predicate: #Predicate { $0.targets.count == oneTarget },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(countDescriptor).map(\.persistentModelID), [populatedOwner.persistentModelID])
        XCTAssertEqual(try context.fetchCount(countDescriptor), 1)
    }

    @MainActor
    func testPredicateTraversesNestedOwningToOneRelationships() throws {
        let container = try ModelContainer(
            for: NestedToOneRootFixture.self,
            NestedToOneMiddleFixture.self,
            NestedToOneBranchFixture.self,
            NestedToOneLeafFixture.self,
            configurations: .sqliteMemory("nested-owning-to-one-predicate"))
        let context = container.mainContext
        let matchingLeaf = NestedToOneLeafFixture(title: "match")
        let otherLeaf = NestedToOneLeafFixture(title: "other")
        let matchingBranch = NestedToOneBranchFixture(name: "matching-branch", leaf: matchingLeaf)
        let otherBranch = NestedToOneBranchFixture(name: "other-branch", leaf: otherLeaf)
        let nilLeafBranch = NestedToOneBranchFixture(name: "nil-leaf-branch", leaf: nil)
        let matchingMiddle = NestedToOneMiddleFixture(name: "matching-middle", branch: matchingBranch)
        let otherMiddle = NestedToOneMiddleFixture(name: "other-middle", branch: otherBranch)
        let nilLeafMiddle = NestedToOneMiddleFixture(name: "nil-leaf-middle", branch: nilLeafBranch)
        context.insert(matchingLeaf)
        context.insert(otherLeaf)
        context.insert(matchingBranch)
        context.insert(otherBranch)
        context.insert(nilLeafBranch)
        context.insert(matchingMiddle)
        context.insert(otherMiddle)
        context.insert(nilLeafMiddle)
        let matchingRoot = NestedToOneRootFixture(name: "matching-root", middle: matchingMiddle)
        let otherRoot = NestedToOneRootFixture(name: "other-root", middle: otherMiddle)
        let nilLeafRoot = NestedToOneRootFixture(name: "nil-leaf-root", middle: nilLeafMiddle)
        let nilRoot = NestedToOneRootFixture(name: "nil-root", middle: nil)
        context.insert(matchingRoot)
        context.insert(otherRoot)
        context.insert(nilLeafRoot)
        context.insert(nilRoot)
        try context.save()

        let selectedTitle = "match"
        let descriptor = FetchDescriptor<NestedToOneRootFixture>(
            predicate: #Predicate { $0.middle?.branch?.leaf?.title == selectedTitle },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.name), ["matching-root"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        let nilDescriptor = FetchDescriptor<NestedToOneRootFixture>(
            predicate: #Predicate { $0.middle?.branch?.leaf?.title == nil },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(nilDescriptor).map(\.name)), ["nil-leaf-root", "nil-root"])

        matchingLeaf.title = "pending-match"
        let pendingTitle = "pending-match"
        let pendingDescriptor = FetchDescriptor<NestedToOneRootFixture>(
            predicate: #Predicate { $0.middle?.branch?.leaf?.title == pendingTitle })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["matching-root"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [matchingRoot.persistentModelID])
    }

    @MainActor
    func testNestedOwningPathTraversesInverseToOneHop() throws {
        let container = try ModelContainer(
            for: NestedInverseRootFixture.self,
            NestedInverseMiddleFixture.self,
            NestedInverseBranchFixture.self,
            NestedInverseLeafFixture.self,
            NestedInverseItemFixture.self,
            configurations: .sqliteMemory("nested-inverse-to-one-path"))
        let context = container.mainContext
        let leaf = NestedInverseLeafFixture(title: "selected")
        let selectedItem = NestedInverseItemFixture(title: "collection-match")
        let otherItem = NestedInverseItemFixture(title: "collection-other")
        let branch = NestedInverseBranchFixture(
            name: "branch", middle: nil, leaf: leaf, items: [selectedItem, otherItem])
        let middle = NestedInverseMiddleFixture(name: "middle", branch: nil)
        let root = NestedInverseRootFixture(name: "root", middle: nil)
        context.insert(leaf)
        context.insert(selectedItem)
        context.insert(otherItem)
        context.insert(branch)
        context.insert(middle)
        context.insert(root)
        branch.middle = middle
        root.middle = middle
        try context.save()

        XCTAssertNil(
            container.schema.entity(forName: "NestedInverseRootFixture")?.relationships
                .first(where: { $0.name == "middle" })?.inverse)
        XCTAssertEqual(
            container.schema.entity(forName: "NestedInverseMiddleFixture")?.relationships
                .first(where: { $0.name == "branch" })?.inverse,
            "middle")
        XCTAssertEqual(
            container.schema.entity(forName: "NestedInverseBranchFixture")?.relationships
                .first(where: { $0.name == "middle" })?.inverse,
            "branch")

        let selectedTitle = "selected"
        let descriptor = FetchDescriptor<NestedInverseRootFixture>(
            predicate: #Predicate { $0.middle?.branch?.leaf?.title == selectedTitle },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.name), ["root"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        leaf.title = "pending-selected"
        let pendingTitle = "pending-selected"
        let pendingDescriptor = FetchDescriptor<NestedInverseRootFixture>(
            predicate: #Predicate { $0.middle?.branch?.leaf?.title == pendingTitle })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["root"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [root.persistentModelID])

        let collectionNeedle = "collection-match"
        let collectionDescriptor = FetchDescriptor<NestedInverseRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { middle in
                    middle.branch.flatMap { branch in
                        branch.items.contains(where: { $0.title == collectionNeedle })
                    }
                } ?? false
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(collectionDescriptor).map(\.name), ["root"])
        XCTAssertEqual(try context.fetchCount(collectionDescriptor), 1)

        let inverseAllSatisfyDescriptor = FetchDescriptor<NestedInverseRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { middle in
                    middle.branch.flatMap { branch in
                        branch.items.allSatisfy { $0.title == collectionNeedle }
                    }
                } ?? false
            })
        XCTAssertTrue(try context.fetch(inverseAllSatisfyDescriptor).isEmpty)
        let sharedPrefix = "collection"
        let allSatisfyMatches = FetchDescriptor<NestedInverseRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { middle in
                    middle.branch.flatMap { branch in
                        branch.items.allSatisfy { $0.title.contains(sharedPrefix) }
                    }
                } ?? false
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(allSatisfyMatches).map(\.name), ["root"])

        let pendingItem = NestedInverseItemFixture(title: "pending-collection")
        context.insert(pendingItem)
        branch.items.append(pendingItem)
        let pendingCollectionNeedle = "pending-collection"
        let pendingCollectionDescriptor = FetchDescriptor<NestedInverseRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { middle in
                    middle.branch.flatMap { branch in
                        branch.items.contains(where: { $0.title == pendingCollectionNeedle })
                    }
                } ?? false
            })
        XCTAssertEqual(try context.fetch(pendingCollectionDescriptor).map(\.name), ["root"])
        XCTAssertEqual(try context.fetchCount(pendingCollectionDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingCollectionDescriptor), [root.persistentModelID])
    }

    @MainActor
    func testPredicateTraversesNestedToOneIntoHierarchyDestination() throws {
        let container = try ModelContainer(
            for: NestedHierarchyRootFixture.self,
            NestedHierarchyMiddleChildFixture.self,
            NestedToOneLeafFixture.self,
            configurations: .sqliteMemory("nested-hierarchy-to-one-path"))
        let context = container.mainContext
        let leaf = NestedToOneLeafFixture(title: "selected")
        let middle = NestedHierarchyMiddleChildFixture(name: "middle", leaf: leaf)
        let matchingRoot = NestedHierarchyRootFixture(name: "matching", middle: middle)
        let siblingRoot = NestedHierarchyRootFixture(name: "sibling", middle: nil)
        context.insert(leaf)
        context.insert(middle)
        context.insert(matchingRoot)
        context.insert(siblingRoot)
        try context.save()

        let selectedTitle = "selected"
        let descriptor = FetchDescriptor<NestedHierarchyRootFixture>(
            predicate: #Predicate { $0.middle?.leaf?.title == selectedTitle },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["matching"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)

        leaf.title = "pending-selected"
        let pendingTitle = "pending-selected"
        let pendingDescriptor = FetchDescriptor<NestedHierarchyRootFixture>(
            predicate: #Predicate { $0.middle?.leaf?.title == pendingTitle })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["matching"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [matchingRoot.persistentModelID])
    }

    @MainActor
    func testNestedToOnePathTraversesHierarchyRootTables() throws {
        let container = try ModelContainer(
            for: NestedHierarchyPathRootFixture.self,
            NestedHierarchyPathMiddleFixture.self,
            NestedHierarchyMiddleGrandchildFixture.self,
            NestedToOneLeafFixture.self,
            configurations: .sqliteMemory("nested-hierarchy-root-table-path"))
        let context = container.mainContext
        let selectedLeaf = NestedToOneLeafFixture(title: "selected")
        let otherLeaf = NestedToOneLeafFixture(title: "other")
        let matchingTarget = NestedHierarchyMiddleGrandchildFixture(
            name: "matching-target", leaf: selectedLeaf, rank: 2)
        let otherTarget = NestedHierarchyMiddleGrandchildFixture(name: "other-target", leaf: otherLeaf, rank: 3)
        let matchingMiddle = NestedHierarchyPathMiddleFixture(name: "matching-middle", target: matchingTarget)
        let otherMiddle = NestedHierarchyPathMiddleFixture(name: "other-middle", target: otherTarget)
        let matchingRoot = NestedHierarchyPathRootFixture(name: "matching-root", middle: matchingMiddle)
        let otherRoot = NestedHierarchyPathRootFixture(name: "other-root", middle: otherMiddle)
        context.insert(selectedLeaf)
        context.insert(otherLeaf)
        context.insert(matchingTarget)
        context.insert(otherTarget)
        context.insert(matchingMiddle)
        context.insert(otherMiddle)
        context.insert(matchingRoot)
        context.insert(otherRoot)
        try context.save()

        let selectedTitle = "selected"
        let descriptor = FetchDescriptor<NestedHierarchyPathRootFixture>(
            predicate: #Predicate { $0.middle?.target?.leaf?.title == selectedTitle },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.name), ["matching-root"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        selectedLeaf.title = "pending-selected"
        let pendingTitle = "pending-selected"
        let pendingDescriptor = FetchDescriptor<NestedHierarchyPathRootFixture>(
            predicate: #Predicate { $0.middle?.target?.leaf?.title == pendingTitle })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["matching-root"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [matchingRoot.persistentModelID])
    }

    @MainActor
    func testPredicateTraversesToManyCollectionThroughToOne() throws {
        let container = try ModelContainer(
            for: NestedToManyRootFixture.self,
            NestedToManyMiddleFixture.self,
            NestedToManyItemFixture.self,
            configurations: .sqliteMemory("nested-to-many-through-to-one"))
        let context = container.mainContext
        let selectedItem = NestedToManyItemFixture(title: "selected")
        let otherItem = NestedToManyItemFixture(title: "other")
        let matchingMiddle = NestedToManyMiddleFixture(name: "matching-middle", items: [selectedItem])
        let otherMiddle = NestedToManyMiddleFixture(name: "other-middle", items: [otherItem])
        context.insert(selectedItem)
        context.insert(otherItem)
        context.insert(matchingMiddle)
        context.insert(otherMiddle)
        let matchingRoot = NestedToManyRootFixture(name: "matching-root", middle: matchingMiddle)
        let otherRoot = NestedToManyRootFixture(name: "other-root", middle: otherMiddle)
        let nilRoot = NestedToManyRootFixture(name: "nil-root", middle: nil)
        context.insert(matchingRoot)
        context.insert(otherRoot)
        context.insert(nilRoot)
        try context.save()

        let selectedTitle = "selected"
        let descriptor = FetchDescriptor<NestedToManyRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { $0.items.contains(where: { $0.title == selectedTitle }) } ?? false
            },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.name), ["matching-root"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        let pendingItem = NestedToManyItemFixture(title: "pending")
        context.insert(pendingItem)
        otherMiddle.items.append(pendingItem)
        let pendingTitle = "pending"
        let pendingDescriptor = FetchDescriptor<NestedToManyRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { $0.items.contains(where: { $0.title == pendingTitle }) } ?? false
            })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["other-root"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [otherRoot.persistentModelID])

        let emptyMiddle = NestedToManyMiddleFixture(name: "empty-middle", items: [])
        let emptyRoot = NestedToManyRootFixture(name: "empty-root", middle: emptyMiddle)
        context.insert(emptyMiddle)
        context.insert(emptyRoot)
        try context.save()
        let emptyDescriptor = FetchDescriptor<NestedToManyRootFixture>(
            predicate: #Predicate { $0.middle.flatMap { $0.items.isEmpty } ?? false },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(emptyDescriptor).map(\.name), ["empty-root"])

        let nilOwnerEmptyDescriptor = FetchDescriptor<NestedToManyRootFixture>(
            predicate: #Predicate { $0.middle.flatMap { $0.items.isEmpty } ?? false },
            includePendingChanges: false)
        XCTAssertFalse(try context.fetch(nilOwnerEmptyDescriptor).contains { $0 === nilRoot })

        let pendingNestedItem = NestedToManyItemFixture(title: "nested-pending")
        context.insert(pendingNestedItem)
        emptyMiddle.items.append(pendingNestedItem)
        let pendingEmptyDescriptor = FetchDescriptor<NestedToManyRootFixture>(
            predicate: #Predicate { $0.middle.flatMap { $0.items.isEmpty } ?? false })
        XCTAssertTrue(try context.fetch(pendingEmptyDescriptor).isEmpty)
        XCTAssertEqual(try context.fetchCount(pendingEmptyDescriptor), 0)
    }

    @MainActor
    func testAllSatisfyTraversesToManyCollectionThroughToOne() throws {
        let container = try ModelContainer(
            for: NestedToManyRootFixture.self,
            NestedToManyMiddleFixture.self,
            NestedToManyItemFixture.self,
            configurations: .sqliteMemory("nested-to-one-all-satisfy"))
        let context = container.mainContext
        let accepted = NestedToManyItemFixture(title: "accepted")
        let rejected = NestedToManyItemFixture(title: "rejected")
        let allAccepted = NestedToManyMiddleFixture(name: "all-accepted", items: [accepted])
        let mixed = NestedToManyMiddleFixture(name: "mixed", items: [accepted, rejected])
        let empty = NestedToManyMiddleFixture(name: "empty", items: [])
        let acceptedRoot = NestedToManyRootFixture(name: "accepted-root", middle: allAccepted)
        let mixedRoot = NestedToManyRootFixture(name: "mixed-root", middle: mixed)
        let emptyRoot = NestedToManyRootFixture(name: "empty-root", middle: empty)
        let nilRoot = NestedToManyRootFixture(name: "nil-root", middle: nil)
        context.insert(accepted)
        context.insert(rejected)
        context.insert(allAccepted)
        context.insert(mixed)
        context.insert(empty)
        context.insert(acceptedRoot)
        context.insert(mixedRoot)
        context.insert(emptyRoot)
        context.insert(nilRoot)
        try context.save()

        let expected = "accepted"
        let descriptor = FetchDescriptor<NestedToManyRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { middle in middle.items.allSatisfy { $0.title == expected } } ?? false
            },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(descriptor).map(\.name)), ["accepted-root", "empty-root"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)

        rejected.title = expected
        let pendingDescriptor = FetchDescriptor<NestedToManyRootFixture>(
            predicate: #Predicate {
                $0.middle.flatMap { middle in middle.items.allSatisfy { $0.title == expected } } ?? false
            })
        XCTAssertEqual(
            Set(try context.fetch(pendingDescriptor).map(\.name)),
            ["accepted-root", "mixed-root", "empty-root"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
    }

    @MainActor
    func testAllSatisfyTraversesTwoOptionalToOneHops() throws {
        let container = try ModelContainer(
            for: MultiHopAllSatisfyRootFixture.self,
            MultiHopAllSatisfyMiddleFixture.self,
            MultiHopAllSatisfyBranchFixture.self,
            MultiHopAllSatisfyItemFixture.self,
            configurations: .sqliteMemory("multi-hop-optional-to-one-all-satisfy"))
        let context = container.mainContext
        let accepted = MultiHopAllSatisfyItemFixture(title: "accepted")
        let rejected = MultiHopAllSatisfyItemFixture(title: "rejected")
        let emptyBranch = MultiHopAllSatisfyBranchFixture(name: "empty", items: [])
        let matchingBranch = MultiHopAllSatisfyBranchFixture(name: "matching", items: [accepted])
        let mixedBranch = MultiHopAllSatisfyBranchFixture(name: "mixed", items: [accepted, rejected])
        let nilFirstHop = MultiHopAllSatisfyRootFixture(name: "nil-first", middle: nil)
        let nilSecondHop = MultiHopAllSatisfyRootFixture(
            name: "nil-second", middle: MultiHopAllSatisfyMiddleFixture(name: "nil-branch", branch: nil))
        let nilBranchMiddle = try XCTUnwrap(nilSecondHop.middle)
        let emptyRoot = MultiHopAllSatisfyRootFixture(
            name: "empty", middle: MultiHopAllSatisfyMiddleFixture(name: "empty-middle", branch: emptyBranch))
        let matchingRoot = MultiHopAllSatisfyRootFixture(
            name: "matching", middle: MultiHopAllSatisfyMiddleFixture(name: "matching-middle", branch: matchingBranch))
        let mixedRoot = MultiHopAllSatisfyRootFixture(
            name: "mixed", middle: MultiHopAllSatisfyMiddleFixture(name: "mixed-middle", branch: mixedBranch))
        let emptyMiddle = try XCTUnwrap(emptyRoot.middle)
        let matchingMiddle = try XCTUnwrap(matchingRoot.middle)
        let mixedMiddle = try XCTUnwrap(mixedRoot.middle)
        context.insert(accepted)
        context.insert(rejected)
        context.insert(emptyBranch)
        context.insert(matchingBranch)
        context.insert(mixedBranch)
        context.insert(nilBranchMiddle)
        context.insert(emptyMiddle)
        context.insert(matchingMiddle)
        context.insert(mixedMiddle)
        context.insert(nilFirstHop)
        context.insert(nilSecondHop)
        context.insert(emptyRoot)
        context.insert(matchingRoot)
        context.insert(mixedRoot)
        try context.save()

        let expected = "accepted"
        let predicate = #Predicate<MultiHopAllSatisfyRootFixture> { root in
            root.middle.flatMap { middle in
                middle.branch.flatMap { branch in
                    branch.items.allSatisfy { $0.title == expected }
                }
            } ?? false
        }
        let descriptor = FetchDescriptor<MultiHopAllSatisfyRootFixture>(
            predicate: predicate, includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(descriptor).map(\.name)), ["empty", "matching"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)

        rejected.title = expected
        let pendingDescriptor = FetchDescriptor<MultiHopAllSatisfyRootFixture>(
            predicate: #Predicate { root in
                root.middle.flatMap { middle in
                    middle.branch.flatMap { branch in
                        branch.items.allSatisfy { $0.title == expected }
                    }
                } ?? false
            })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["empty", "matching", "mixed"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)

        let containsDescriptor = FetchDescriptor<MultiHopAllSatisfyRootFixture>(
            predicate: #Predicate { root in
                root.middle.flatMap { middle in
                    middle.branch.flatMap { branch in
                        branch.items.contains { $0.title == expected }
                    }
                } ?? false
            })
        XCTAssertEqual(Set(try context.fetch(containsDescriptor).map(\.name)), ["matching", "mixed"])

    }

    @MainActor
    func testNestedThreeLevelContainsSupportsStringAndOuterScalarPredicates() throws {
        let container = try ModelContainer(
            for: ThreeLevelQuantifierOwnerFixture.self,
            ThreeLevelQuantifierGroupFixture.self,
            ThreeLevelQuantifierChildFixture.self,
            ThreeLevelQuantifierItemFixture.self,
            configurations: .sqliteMemory("three-level-nested-string-predicate"))
        let context = container.mainContext
        let item = ThreeLevelQuantifierItemFixture(value: "matching item")
        let child = ThreeLevelQuantifierChildFixture(name: "child", items: [item])
        let group = ThreeLevelQuantifierGroupFixture(name: "group", children: [child])
        let owner = ThreeLevelQuantifierOwnerFixture(name: "matching owner", groups: [group])
        context.insert(item)
        context.insert(child)
        context.insert(group)
        context.insert(owner)
        try context.save()

        let fragment = "mat"
        let nestedStringDescriptor = FetchDescriptor<ThreeLevelQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.value.contains(fragment) }
                    }
                }
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(nestedStringDescriptor).map(\.name), ["matching owner"])

        let scopedPredicate = #Predicate<ThreeLevelQuantifierOwnerFixture> {
            $0.name == "matching owner"
                && $0.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.value.contains(fragment) }
                    }
                }
        }
        let scopedStoredDescriptor = FetchDescriptor<ThreeLevelQuantifierOwnerFixture>(
            predicate: scopedPredicate, includePendingChanges: false)
        XCTAssertEqual(try context.fetch(scopedStoredDescriptor).map(\.name), ["matching owner"])
        let scopedDescriptor = FetchDescriptor<ThreeLevelQuantifierOwnerFixture>(predicate: scopedPredicate)
        XCTAssertEqual(try context.fetch(scopedDescriptor).map(\.name), ["matching owner"])

    }

    @MainActor
    func testNestedFourLevelContainsSupportsStoredAndPendingEvaluation() throws {
        let container = try ModelContainer(
            for: FourLevelQuantifierRootFixture.self,
            FourLevelQuantifierGroupFixture.self,
            FourLevelQuantifierChildFixture.self,
            FourLevelQuantifierItemFixture.self,
            FourLevelQuantifierLeafFixture.self,
            configurations: .sqliteMemory("nested-relationship-quantifier-depth-four"))
        let context = container.mainContext
        let needle = "match"
        let matchingTip = FourLevelQuantifierLeafFixture(value: needle)
        let matchingLeaf = FourLevelQuantifierLeafFixture(value: needle, descendants: [matchingTip])
        let matchingItem = FourLevelQuantifierItemFixture(value: "matching item", leaves: [matchingLeaf])
        let matchingChild = FourLevelQuantifierChildFixture(items: [matchingItem])
        let matchingGroup = FourLevelQuantifierGroupFixture(children: [matchingChild])
        let matchingRoot = FourLevelQuantifierRootFixture(groups: [matchingGroup])

        let otherLeaf = FourLevelQuantifierLeafFixture(value: "other")
        let otherItem = FourLevelQuantifierItemFixture(value: "other item", leaves: [otherLeaf])
        let otherChild = FourLevelQuantifierChildFixture(items: [otherItem])
        let otherGroup = FourLevelQuantifierGroupFixture(children: [otherChild])
        let otherRoot = FourLevelQuantifierRootFixture(groups: [otherGroup])

        let emptyLeavesItem = FourLevelQuantifierItemFixture(value: "empty leaves", leaves: [])
        let emptyItemsChild = FourLevelQuantifierChildFixture(items: [])
        let emptyChildrenGroup = FourLevelQuantifierGroupFixture(children: [])
        let emptyLeavesChild = FourLevelQuantifierChildFixture(items: [emptyLeavesItem])
        let emptyLeavesGroup = FourLevelQuantifierGroupFixture(children: [emptyLeavesChild])
        let emptyRoot = FourLevelQuantifierRootFixture(
            groups: [
                emptyLeavesGroup,
                emptyChildrenGroup,
                FourLevelQuantifierGroupFixture(children: [emptyItemsChild]),
            ])

        context.insert(matchingTip)
        context.insert(matchingLeaf)
        context.insert(otherLeaf)
        context.insert(matchingItem)
        context.insert(otherItem)
        context.insert(emptyLeavesItem)
        context.insert(matchingChild)
        context.insert(otherChild)
        context.insert(emptyLeavesChild)
        context.insert(emptyItemsChild)
        for group in emptyRoot.groups {
            context.insert(group)
        }
        context.insert(matchingGroup)
        context.insert(otherGroup)
        context.insert(emptyChildrenGroup)
        context.insert(matchingRoot)
        context.insert(otherRoot)
        context.insert(emptyRoot)
        try context.save()

        let predicate = #Predicate<FourLevelQuantifierRootFixture> {
            $0.groups.contains { group in
                group.children.contains { child in
                    child.items.contains { item in
                        item.leaves.contains { $0.value == needle }
                    }
                }
            }
        }
        let storedDescriptor = FetchDescriptor<FourLevelQuantifierRootFixture>(
            predicate: predicate, includePendingChanges: false)
        XCTAssertEqual(try context.fetch(storedDescriptor).map(\.persistentModelID), [matchingRoot.persistentModelID])
        XCTAssertEqual(try context.fetchCount(storedDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(storedDescriptor), [matchingRoot.persistentModelID])
        let storedRoots = try context.fetch(FetchDescriptor<FourLevelQuantifierRootFixture>())
        XCTAssertEqual(
            Set(storedRoots.map(\.persistentModelID)),
            Set([matchingRoot.persistentModelID, otherRoot.persistentModelID, emptyRoot.persistentModelID]))

        otherLeaf.value = needle
        let pendingDescriptor = FetchDescriptor<FourLevelQuantifierRootFixture>(predicate: predicate)
        let pendingStoredDescriptor = FetchDescriptor<FourLevelQuantifierRootFixture>(
            predicate: predicate, includePendingChanges: false)
        XCTAssertEqual(
            Set(try context.fetch(pendingDescriptor).map(\.persistentModelID)),
            Set([matchingRoot.persistentModelID, otherRoot.persistentModelID]))
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([matchingRoot.persistentModelID, otherRoot.persistentModelID]))
        XCTAssertEqual(
            try context.fetch(pendingStoredDescriptor).map(\.persistentModelID), [matchingRoot.persistentModelID])

        let pendingTip = FourLevelQuantifierLeafFixture(value: "pending tip")
        let pendingLeaf = FourLevelQuantifierLeafFixture(value: needle, descendants: [pendingTip])
        let pendingItem = FourLevelQuantifierItemFixture(value: "pending item", leaves: [pendingLeaf])
        let pendingChild = FourLevelQuantifierChildFixture(items: [pendingItem])
        let pendingGroup = FourLevelQuantifierGroupFixture(children: [pendingChild])
        let pendingRoot = FourLevelQuantifierRootFixture(groups: [pendingGroup])
        context.insert(pendingTip)
        context.insert(pendingLeaf)
        context.insert(pendingItem)
        context.insert(pendingChild)
        context.insert(pendingGroup)
        context.insert(pendingRoot)
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([matchingRoot.persistentModelID, otherRoot.persistentModelID, pendingRoot.persistentModelID]))
        XCTAssertEqual(try context.fetchCount(pendingStoredDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingStoredDescriptor), [matchingRoot.persistentModelID])

        let depthFivePendingTip = FourLevelQuantifierLeafFixture(value: needle)
        let depthFivePendingLeaf = FourLevelQuantifierLeafFixture(
            value: "pending parent", descendants: [depthFivePendingTip])
        let depthFivePendingItem = FourLevelQuantifierItemFixture(
            value: "pending depth five", leaves: [depthFivePendingLeaf])
        let depthFivePendingChild = FourLevelQuantifierChildFixture(items: [depthFivePendingItem])
        let depthFivePendingGroup = FourLevelQuantifierGroupFixture(children: [depthFivePendingChild])
        let depthFivePendingRoot = FourLevelQuantifierRootFixture(groups: [depthFivePendingGroup])
        context.insert(depthFivePendingTip)
        context.insert(depthFivePendingLeaf)
        context.insert(depthFivePendingItem)
        context.insert(depthFivePendingChild)
        context.insert(depthFivePendingGroup)
        context.insert(depthFivePendingRoot)

        let depthFivePredicate = #Predicate<FourLevelQuantifierRootFixture> {
            $0.groups.contains { group in
                group.children.contains { child in
                    child.items.contains { item in
                        item.leaves.contains { leaf in
                            leaf.descendants.contains { $0.value == needle }
                        }
                    }
                }
            }
        }
        let depthFiveDescriptor = FetchDescriptor<FourLevelQuantifierRootFixture>(
            predicate: depthFivePredicate, includePendingChanges: false)
        let depthFiveMatches = try context.fetch(depthFiveDescriptor)
        XCTAssertEqual(depthFiveMatches.map(\.persistentModelID), [matchingRoot.persistentModelID])
        XCTAssertEqual(try context.fetchCount(depthFiveDescriptor), 1)
        XCTAssertEqual(
            try context.fetchIdentifiers(depthFiveDescriptor), depthFiveMatches.map(\.persistentModelID))

        let depthFivePendingDescriptor = FetchDescriptor<FourLevelQuantifierRootFixture>(
            predicate: depthFivePredicate)
        let depthFivePendingMatches = try context.fetch(depthFivePendingDescriptor)
        XCTAssertEqual(
            Set(depthFivePendingMatches.map(\.persistentModelID)),
            Set([matchingRoot.persistentModelID, depthFivePendingRoot.persistentModelID]))
        XCTAssertEqual(try context.fetchCount(depthFivePendingDescriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(depthFivePendingDescriptor)),
            Set(depthFivePendingMatches.map(\.persistentModelID)))
        XCTAssertEqual(try context.fetchCount(depthFiveDescriptor), 1)

        let depthSixPredicate = #Predicate<FourLevelQuantifierRootFixture> {
            $0.groups.contains { group in
                group.children.contains { child in
                    child.items.contains { item in
                        item.leaves.contains { leaf in
                            leaf.descendants.contains { descendant in
                                descendant.descendants.contains { $0.value == needle }
                            }
                        }
                    }
                }
            }
        }
        let depthSixDescriptor = FetchDescriptor<FourLevelQuantifierRootFixture>(predicate: depthSixPredicate)
        let depthSixStoredDescriptor = FetchDescriptor<FourLevelQuantifierRootFixture>(
            predicate: depthSixPredicate, includePendingChanges: false)
        XCTAssertThrowsError(try context.fetch(depthSixDescriptor)) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected depth-six collection predicate to fail closed, got \(error)")
            }
        }
        XCTAssertThrowsError(try context.fetch(depthSixStoredDescriptor)) { error in
            guard case SwiftDataError.unsupportedPredicate = error else {
                return XCTFail("Expected depth-six collection predicate to fail closed, got \(error)")
            }
        }
    }

    @MainActor
    func testNestedFourLevelContainsSupportsMixedSetAndArrayRelationships() throws {
        let container = try ModelContainer(
            for: MixedSetQuantifierRootFixture.self,
            MixedSetQuantifierGroupFixture.self,
            MixedSetQuantifierChildFixture.self,
            MixedSetQuantifierItemFixture.self,
            MixedSetQuantifierLeafFixture.self,
            configurations: .sqliteMemory("nested-mixed-set-array-quantifiers"))
        let context = container.mainContext
        let needle = "match"
        let matchingLeaf = MixedSetQuantifierLeafFixture(value: needle)
        let matchingItem = MixedSetQuantifierItemFixture(leaves: [matchingLeaf])
        let matchingChild = MixedSetQuantifierChildFixture(items: Set([matchingItem]))
        let matchingGroup = MixedSetQuantifierGroupFixture(children: [matchingChild])
        let matchingRoot = MixedSetQuantifierRootFixture(name: "matching", groups: Set([matchingGroup]))

        let otherLeaf = MixedSetQuantifierLeafFixture(value: "other")
        let otherItem = MixedSetQuantifierItemFixture(leaves: [otherLeaf])
        let otherChild = MixedSetQuantifierChildFixture(items: Set([otherItem]))
        let otherGroup = MixedSetQuantifierGroupFixture(children: [otherChild])
        let otherRoot = MixedSetQuantifierRootFixture(name: "other", groups: Set([otherGroup]))

        let nearMissLeaf = MixedSetQuantifierLeafFixture(value: "near miss")
        let nearMissItem = MixedSetQuantifierItemFixture(leaves: [nearMissLeaf])
        let nearMissChild = MixedSetQuantifierChildFixture(items: Set([nearMissItem]))
        let nearMissGroup = MixedSetQuantifierGroupFixture(children: [nearMissChild])
        let nearMissRoot = MixedSetQuantifierRootFixture(name: "near miss", groups: Set([nearMissGroup]))
        let emptyRoot = MixedSetQuantifierRootFixture(name: "empty", groups: [])

        context.insert(matchingLeaf)
        context.insert(otherLeaf)
        context.insert(nearMissLeaf)
        context.insert(matchingItem)
        context.insert(otherItem)
        context.insert(nearMissItem)
        context.insert(matchingChild)
        context.insert(otherChild)
        context.insert(nearMissChild)
        context.insert(matchingGroup)
        context.insert(otherGroup)
        context.insert(nearMissGroup)
        context.insert(matchingRoot)
        context.insert(otherRoot)
        context.insert(nearMissRoot)
        context.insert(emptyRoot)
        try context.save()

        let predicate = #Predicate<MixedSetQuantifierRootFixture> {
            $0.groups.contains { group in
                group.children.contains { child in
                    child.items.contains { item in
                        item.leaves.contains { $0.value == needle }
                    }
                }
            }
        }
        let storedDescriptor = FetchDescriptor<MixedSetQuantifierRootFixture>(
            predicate: predicate, includePendingChanges: false)
        XCTAssertEqual(try context.fetch(storedDescriptor).map(\.name), ["matching"])
        XCTAssertEqual(try context.fetchCount(storedDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(storedDescriptor), [matchingRoot.persistentModelID])

        otherLeaf.value = needle
        XCTAssertTrue(context.hasChanges)
        let pendingDescriptor = FetchDescriptor<MixedSetQuantifierRootFixture>(predicate: predicate)
        let pendingStoredDescriptor = FetchDescriptor<MixedSetQuantifierRootFixture>(
            predicate: predicate, includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), Set(["matching", "other"]))
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([matchingRoot.persistentModelID, otherRoot.persistentModelID]))
        XCTAssertEqual(try context.fetch(pendingStoredDescriptor).map(\.name), ["matching"])
        XCTAssertEqual(try context.fetchCount(pendingStoredDescriptor), 1)

        let pendingLeaf = MixedSetQuantifierLeafFixture(value: needle)
        let pendingItem = MixedSetQuantifierItemFixture(leaves: [pendingLeaf])
        let pendingChild = MixedSetQuantifierChildFixture(items: Set([pendingItem]))
        let pendingGroup = MixedSetQuantifierGroupFixture(children: [pendingChild])
        let pendingRoot = MixedSetQuantifierRootFixture(name: "pending", groups: Set([pendingGroup]))
        context.insert(pendingLeaf)
        context.insert(pendingItem)
        context.insert(pendingChild)
        context.insert(pendingGroup)
        context.insert(pendingRoot)
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([matchingRoot.persistentModelID, otherRoot.persistentModelID, pendingRoot.persistentModelID]))
        XCTAssertEqual(try context.fetchCount(pendingStoredDescriptor), 1)
    }

    @MainActor
    func testNestedContainsTraversesInverseBackedCollection() throws {
        let container = try ModelContainer(
            for: InverseNestedQuantifierOwnerFixture.self,
            InverseNestedQuantifierChildFixture.self,
            InverseNestedQuantifierItemFixture.self,
            configurations: .sqliteMemory("nested-inverse-backed-collection"))
        let context = container.mainContext
        let matchingItem = InverseNestedQuantifierItemFixture(title: "match")
        let otherItem = InverseNestedQuantifierItemFixture(title: "other")
        let child = InverseNestedQuantifierChildFixture(name: "child")
        let owner = InverseNestedQuantifierOwnerFixture(name: "owner", children: [child])
        let emptyChild = InverseNestedQuantifierChildFixture(name: "empty child")
        let emptyOwner = InverseNestedQuantifierOwnerFixture(name: "empty owner", children: [emptyChild])
        context.insert(owner)
        context.insert(child)
        context.insert(emptyOwner)
        context.insert(emptyChild)
        context.insert(matchingItem)
        context.insert(otherItem)
        matchingItem.child = child
        otherItem.child = child
        try context.save()

        let needle = "match"
        let storedDescriptor = FetchDescriptor<InverseNestedQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.children.contains { child in
                    child.items.contains { $0.title == needle }
                }
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(storedDescriptor).map(\.name), ["owner"])
        XCTAssertFalse(try context.fetch(storedDescriptor).contains { $0 === emptyOwner })

        let pendingItem = InverseNestedQuantifierItemFixture(title: "pending other")
        context.insert(pendingItem)
        pendingItem.child = child
        let pendingDescriptor = FetchDescriptor<InverseNestedQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.children.contains { child in
                    child.items.contains { $0.title == needle }
                }
            })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["owner"])

        matchingItem.child = nil
        XCTAssertFalse(try context.fetch(pendingDescriptor).contains { $0 === owner })
        matchingItem.child = child
        try context.save()
        XCTAssertEqual(try context.fetch(storedDescriptor).map(\.name), ["owner"])
    }

    @MainActor
    func testPendingNestedInverseCollectionIdentifiersAvoidMaterializingUntouchedOwners() throws {
        let container = try ModelContainer(
            for: InverseNestedQuantifierOwnerFixture.self,
            InverseNestedQuantifierChildFixture.self,
            InverseNestedQuantifierItemFixture.self,
            configurations: .sqliteMemory("pending-nested-inverse-identifiers"))
        let writer = container.mainContext
        let firstItem = InverseNestedQuantifierItemFixture(title: "match")
        let firstChild = InverseNestedQuantifierChildFixture(name: "first child", items: [firstItem])
        let firstOwner = InverseNestedQuantifierOwnerFixture(name: "first", children: [firstChild])
        let untouchedItem = InverseNestedQuantifierItemFixture(title: "match")
        let untouchedChild = InverseNestedQuantifierChildFixture(name: "untouched child", items: [untouchedItem])
        let untouchedOwner = InverseNestedQuantifierOwnerFixture(name: "untouched", children: [untouchedChild])
        writer.insert(firstItem)
        writer.insert(firstChild)
        writer.insert(firstOwner)
        writer.insert(untouchedItem)
        writer.insert(untouchedChild)
        writer.insert(untouchedOwner)
        try writer.save()
        let ownerIDs = try writer.fetchIdentifiers(FetchDescriptor<InverseNestedQuantifierOwnerFixture>())
        let savedOwners = try writer.fetch(FetchDescriptor<InverseNestedQuantifierOwnerFixture>())
        let firstID = try XCTUnwrap(savedOwners.first(where: { $0.name == "first" })?.persistentModelID)
        let untouchedID = try XCTUnwrap(savedOwners.first(where: { $0.name == "untouched" })?.persistentModelID)

        let reader = container.makeContext()
        let first: InverseNestedQuantifierOwnerFixture = try XCTUnwrap(reader.model(for: firstID))
        let child = try XCTUnwrap(first.children.first)
        let pendingItem = InverseNestedQuantifierItemFixture(title: "match")
        reader.insert(pendingItem)
        pendingItem.child = child
        let descriptor = FetchDescriptor<InverseNestedQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.children.contains { child in
                    child.items.contains { $0.title == "match" }
                }
            })

        let expectedIDs = ownerIDs
        XCTAssertEqual(try reader.fetchIdentifiers(descriptor), expectedIDs)
        let untouchedAfterIdentifiers: InverseNestedQuantifierOwnerFixture? = reader.registeredModel(for: untouchedID)
        XCTAssertNil(untouchedAfterIdentifiers)
        XCTAssertEqual(try reader.fetchCount(descriptor), expectedIDs.count)
        let untouchedAfterCount: InverseNestedQuantifierOwnerFixture? = reader.registeredModel(for: untouchedID)
        XCTAssertNil(untouchedAfterCount)
    }

    @MainActor
    func testNestedContainsTraversesThreeInverseBackedCollectionLevels() throws {
        let container = try ModelContainer(
            for: DeepInverseQuantifierOwnerFixture.self,
            DeepInverseQuantifierGroupFixture.self,
            DeepInverseQuantifierChildFixture.self,
            DeepInverseQuantifierItemFixture.self,
            configurations: .sqliteMemory("three-level-inverse-backed-collections"))
        let context = container.mainContext
        let matchingGroup = DeepInverseQuantifierGroupFixture(name: "matching group")
        let emptyGroup = DeepInverseQuantifierGroupFixture(name: "empty group")
        let otherGroup = DeepInverseQuantifierGroupFixture(name: "other group")
        let matchingChild = DeepInverseQuantifierChildFixture(name: "matching child")
        let emptyChild = DeepInverseQuantifierChildFixture(name: "empty child")
        let otherChild = DeepInverseQuantifierChildFixture(name: "other child")
        let matchingItem = DeepInverseQuantifierItemFixture(title: "match")
        let matchingOwner = DeepInverseQuantifierOwnerFixture(name: "matching owner", groups: [matchingGroup])
        let emptyOwner = DeepInverseQuantifierOwnerFixture(name: "empty owner", groups: [emptyGroup])
        let otherOwner = DeepInverseQuantifierOwnerFixture(name: "other owner", groups: [otherGroup])
        context.insert(matchingGroup)
        context.insert(emptyGroup)
        context.insert(otherGroup)
        context.insert(matchingChild)
        context.insert(emptyChild)
        context.insert(otherChild)
        context.insert(matchingItem)
        context.insert(matchingOwner)
        context.insert(emptyOwner)
        context.insert(otherOwner)
        matchingChild.group = matchingGroup
        emptyChild.group = emptyGroup
        otherChild.group = otherGroup
        matchingItem.child = matchingChild
        try context.save()

        let needle = "match"
        let storedDescriptor = FetchDescriptor<DeepInverseQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.title == needle }
                    }
                }
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(storedDescriptor).map(\.name), ["matching owner"])

        let pendingItem = DeepInverseQuantifierItemFixture(title: "other")
        context.insert(pendingItem)
        pendingItem.child = emptyChild
        let pendingDescriptor = FetchDescriptor<DeepInverseQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.title == needle }
                    }
                }
            })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["matching owner"])

        matchingItem.child = nil
        XCTAssertTrue(try context.fetch(pendingDescriptor).isEmpty)
        matchingItem.child = matchingChild
        try context.save()
        XCTAssertEqual(try context.fetch(storedDescriptor).map(\.name), ["matching owner"])

        matchingItem.child = otherChild
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["other owner"])
        context.delete(otherChild)
        XCTAssertTrue(try context.fetch(pendingDescriptor).isEmpty)
        try context.save()
        XCTAssertTrue(try context.fetch(storedDescriptor).isEmpty)
    }

    @MainActor
    func testNestedContainsTraversesInverseManyToManyAtThirdLevel() throws {
        let container = try ModelContainer(
            for: NestedInverseManyToManyRootFixture.self,
            NestedInverseManyToManyGroupFixture.self,
            InheritedManyToManyTagFixture.self,
            InheritedManyToManyChildFixture.self,
            configurations: .sqliteMemory("nested-inverse-many-to-many-third-level"))
        let context = container.mainContext
        let tag = InheritedManyToManyTagFixture(title: "selected")
        let owner = InheritedManyToManyChildFixture(name: "owner", tags: [tag])
        let group = NestedInverseManyToManyGroupFixture(name: "group", tags: [tag])
        let root = NestedInverseManyToManyRootFixture(name: "root", groups: [group])
        context.insert(tag)
        context.insert(owner)
        context.insert(group)
        context.insert(root)
        try context.save()

        let needle = "owner"
        let descriptor = FetchDescriptor<NestedInverseManyToManyRootFixture>(
            predicate: #Predicate {
                $0.groups.contains { group in
                    group.tags.contains { tag in
                        tag.owners.contains { $0.name == needle }
                    }
                }
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["root"])

        let pendingOwner = InheritedManyToManyChildFixture(name: needle, tags: [])
        context.insert(pendingOwner)
        pendingOwner.tags = [tag]
        let pendingDescriptor = FetchDescriptor<NestedInverseManyToManyRootFixture>(
            predicate: #Predicate {
                $0.groups.contains { group in
                    group.tags.contains { tag in
                        tag.owners.contains { $0.name == needle }
                    }
                }
            })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["root"])

        group.tags = []
        XCTAssertTrue(try context.fetch(pendingDescriptor).isEmpty)
    }

    @MainActor
    func testPredicateMatchesEmptyToManyRelationshipCollections() throws {
        let container = try ModelContainer(
            for: NestedToManyMiddleFixture.self,
            NestedToManyItemFixture.self,
            configurations: .sqliteMemory("to-many-is-empty-predicate"))
        let context = container.mainContext
        let item = NestedToManyItemFixture(title: "item")
        let empty = NestedToManyMiddleFixture(name: "empty", items: [])
        let populated = NestedToManyMiddleFixture(name: "populated", items: [item])
        context.insert(item)
        context.insert(empty)
        context.insert(populated)
        try context.save()

        let emptyDescriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.isEmpty },
            includePendingChanges: false)
        let emptyMatches = try context.fetch(emptyDescriptor)
        XCTAssertEqual(emptyMatches.map(\.name), ["empty"])
        XCTAssertEqual(try context.fetchCount(emptyDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(emptyDescriptor), emptyMatches.map(\.persistentModelID))

        populated.items.removeAll()
        let pendingDescriptor = FetchDescriptor<NestedToManyMiddleFixture>(predicate: #Predicate { $0.items.isEmpty })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["empty", "populated"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([empty.persistentModelID, populated.persistentModelID]))
    }

    @MainActor
    func testPredicateAllSatisfyToManyRelationshipElements() throws {
        let container = try ModelContainer(
            for: NestedToManyMiddleFixture.self,
            NestedToManyItemFixture.self,
            configurations: .sqliteMemory("to-many-all-satisfy-predicate"))
        let context = container.mainContext
        let accepted = NestedToManyItemFixture(title: "accepted")
        let rejected = NestedToManyItemFixture(title: "rejected")
        let allAccepted = NestedToManyMiddleFixture(name: "all-accepted", items: [accepted])
        let mixed = NestedToManyMiddleFixture(name: "mixed", items: [accepted, rejected])
        let empty = NestedToManyMiddleFixture(name: "empty", items: [])
        context.insert(accepted)
        context.insert(rejected)
        context.insert(allAccepted)
        context.insert(mixed)
        context.insert(empty)
        try context.save()

        let expectedTitle = "accepted"
        let descriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.allSatisfy { $0.title == expectedTitle } },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(Set(matches.map(\.name)), ["all-accepted", "empty"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        XCTAssertEqual(Set(try context.fetchIdentifiers(descriptor)), Set(matches.map(\.persistentModelID)))

        rejected.title = "accepted"
        let pendingDescriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.allSatisfy { $0.title == expectedTitle } })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["all-accepted", "mixed", "empty"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
    }

    @MainActor
    func testPredicateComparesToManyRelationshipCount() throws {
        let container = try ModelContainer(
            for: NestedToManyMiddleFixture.self,
            NestedToManyItemFixture.self,
            configurations: .sqliteMemory("to-many-count-predicate"))
        let context = container.mainContext
        let first = NestedToManyItemFixture(title: "first")
        let second = NestedToManyItemFixture(title: "second")
        let empty = NestedToManyMiddleFixture(name: "empty", items: [])
        let one = NestedToManyMiddleFixture(name: "one", items: [first])
        let two = NestedToManyMiddleFixture(name: "two", items: [first, second])
        context.insert(first)
        context.insert(second)
        context.insert(empty)
        context.insert(one)
        context.insert(two)
        try context.save()

        let expectedCount = 2
        let descriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.count == expectedCount },
            includePendingChanges: false)
        let committedMatches = try context.fetch(descriptor)
        XCTAssertEqual(committedMatches.map(\.name), ["two"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(
            try context.fetchIdentifiers(descriptor), committedMatches.map(\.persistentModelID))

        let minimumCount = 2
        let minimumDescriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.count >= minimumCount },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(minimumDescriptor).map(\.name), ["two"])
        XCTAssertEqual(try context.fetchCount(minimumDescriptor), 1)

        one.items.append(second)
        let pendingDescriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.count == expectedCount })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(Set(pendingMatches.map(\.name)), ["one", "two"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set(pendingMatches.map(\.persistentModelID)))
        XCTAssertEqual(
            try context.fetchIdentifiers(descriptor), committedMatches.map(\.persistentModelID))
    }

    @MainActor
    func testPredicateMatchesCodableStringCollectionElements() throws {
        let container = try ModelContainer(
            for: CodableStringCollectionFixture.self,
            configurations: .sqliteMemory("codable-string-collection-contains"))
        let context = container.mainContext
        let matching = CodableStringCollectionFixture(
            name: "matching", tags: ["swift", "portable"], optionalTags: ["optional"], numbers: [7], flags: [true],
            optionalNumbers: [11])
        let other = CodableStringCollectionFixture(
            name: "other", tags: ["database"], numbers: [3], flags: [false], optionalNumbers: nil)
        let emptySet = CodableStringCollectionFixture(name: "empty-set", tags: [], optionalNumbers: [])
        context.insert(matching)
        context.insert(other)
        context.insert(emptySet)
        try context.save()

        let needle = "portable"
        let descriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.contains(needle) },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.name), ["matching"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        let number = 7
        let numberDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.numbers.contains(number) },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(numberDescriptor).map(\.name), ["matching"])

        let flag = true
        let flagDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.flags.contains(flag) },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(flagDescriptor).map(\.name), ["matching"])

        let optionalNeedle = "optional"
        let optionalDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.optionalTags.flatMap { $0.contains(optionalNeedle) } ?? false },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(optionalDescriptor).map(\.name), ["matching"])

        let optionalNumber = 11
        let optionalNumberDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.optionalNumbers.flatMap { $0.contains(optionalNumber) } ?? false },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(optionalNumberDescriptor).map(\.name), ["matching"])

        matching.tags = []
        matching.optionalTags = nil
        matching.optionalNumbers = nil
        other.tags = [needle]
        other.optionalNumbers = [optionalNumber]
        matching.numbers = []
        other.numbers = [number]
        matching.flags = []
        other.flags = [flag]
        let pendingDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.contains(needle) })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["other"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [other.persistentModelID])

        let emptyTagsDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.isEmpty },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(emptyTagsDescriptor).map(\.name)), ["empty-set"])

        let pendingNumberDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.numbers.contains(number) })
        XCTAssertEqual(try context.fetch(pendingNumberDescriptor).map(\.name), ["other"])

        let pendingFlagDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.flags.contains(flag) })
        XCTAssertEqual(try context.fetch(pendingFlagDescriptor).map(\.name), ["other"])

        let pendingOptionalNumberDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.optionalNumbers.flatMap { $0.contains(optionalNumber) } ?? false })
        XCTAssertEqual(try context.fetch(pendingOptionalNumberDescriptor).map(\.name), ["other"])
    }

    @MainActor
    func testCodableScalarCollectionIsEmptyPredicates() throws {
        let container = try ModelContainer(
            for: CodableStringCollectionFixture.self,
            configurations: .sqliteMemory("codable-scalar-collection-empty"))
        let context = container.mainContext
        let empty = CodableStringCollectionFixture(name: "empty", tags: [])
        let populated = CodableStringCollectionFixture(name: "populated", tags: ["value"])
        let nilOptional = CodableStringCollectionFixture(name: "nil", tags: [], optionalTags: nil)
        let emptyOptional = CodableStringCollectionFixture(name: "empty-optional", tags: [], optionalTags: [])
        let populatedOptional = CodableStringCollectionFixture(
            name: "populated-optional", tags: [], optionalTags: ["value"])
        context.insert(empty)
        context.insert(populated)
        context.insert(nilOptional)
        context.insert(emptyOptional)
        context.insert(populatedOptional)
        try context.save()

        let descriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.isEmpty },
            includePendingChanges: false)
        XCTAssertEqual(
            Set(try context.fetch(descriptor).map(\.name)), ["empty", "nil", "empty-optional", "populated-optional"])

        let optionalDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.optionalTags.flatMap { $0.isEmpty } ?? false },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(optionalDescriptor).map(\.name)), ["empty-optional"])
        XCTAssertEqual(try context.fetchIdentifiers(optionalDescriptor), [emptyOptional.persistentModelID])

        populated.tags = []
        populatedOptional.optionalTags = []
        let pendingDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.isEmpty })
        XCTAssertTrue(try context.fetch(pendingDescriptor).contains { $0 === populated })
        let pendingOptionalDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.optionalTags.flatMap { $0.isEmpty } ?? false })
        XCTAssertTrue(try context.fetch(pendingOptionalDescriptor).contains { $0 === populatedOptional })
    }

    @MainActor
    func testCodableScalarCollectionCountPredicates() throws {
        let container = try ModelContainer(
            for: CodableStringCollectionFixture.self,
            configurations: .sqliteMemory("codable-scalar-collection-count"))
        let context = container.mainContext
        let empty = CodableStringCollectionFixture(name: "empty", tags: [], optionalTags: [], numbers: [])
        let one = CodableStringCollectionFixture(name: "one", tags: ["one"], optionalTags: ["one"], numbers: [1])
        let two = CodableStringCollectionFixture(
            name: "two", tags: ["one", "two"], optionalTags: ["one", "two"], numbers: [1, 2])
        context.insert(empty)
        context.insert(one)
        context.insert(two)
        try context.save()

        let expectedCount = 2
        let descriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.count == expectedCount },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["two"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), [two.persistentModelID])

        one.tags.append("two")
        let pendingDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.count >= expectedCount })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["one", "two"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)

        let zeroCount = 0
        let optionalDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.optionalTags.flatMap { $0.count == zeroCount } ?? false },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(optionalDescriptor).map(\.name), ["empty"])
        XCTAssertEqual(try context.fetchIdentifiers(optionalDescriptor), [empty.persistentModelID])
    }

    @MainActor
    func testPredicateAllSatisfyOnCodableScalarCollection() throws {
        let container = try ModelContainer(
            for: CodableStringCollectionFixture.self,
            configurations: .sqliteMemory("codable-scalar-all-satisfy"))
        let context = container.mainContext
        let expected = "accepted"
        let matching = CodableStringCollectionFixture(name: "matching", tags: [expected, expected])
        let mixed = CodableStringCollectionFixture(name: "mixed", tags: [expected, "rejected"])
        let empty = CodableStringCollectionFixture(name: "empty", tags: [])
        context.insert(matching)
        context.insert(mixed)
        context.insert(empty)
        try context.save()

        let descriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.allSatisfy { $0 == expected } },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(descriptor).map(\.name)), ["matching", "empty"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(descriptor)), Set([matching.persistentModelID, empty.persistentModelID]))

        let rejected = "rejected"
        let notEqualDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.allSatisfy { $0 != rejected } },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(notEqualDescriptor).map(\.name)), ["matching", "empty"])

        mixed.tags = [expected]
        let pendingDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.allSatisfy { $0 == expected } })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["matching", "mixed", "empty"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([matching.persistentModelID, mixed.persistentModelID, empty.persistentModelID]))
    }

    @MainActor
    func testPredicateAllSatisfyIntegerComparisonOnCodableCollection() throws {
        let container = try ModelContainer(
            for: CodableStringCollectionFixture.self,
            configurations: .sqliteMemory("codable-integer-all-satisfy-comparison"))
        let context = container.mainContext
        let qualifying = CodableStringCollectionFixture(name: "qualifying", tags: [], numbers: [4, 9])
        let violating = CodableStringCollectionFixture(name: "violating", tags: [], numbers: [3, 9])
        let empty = CodableStringCollectionFixture(name: "empty", tags: [], numbers: [])
        context.insert(qualifying)
        context.insert(violating)
        context.insert(empty)
        try context.save()

        let lowerBound = 4
        let descriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.numbers.allSatisfy { $0 >= lowerBound } },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(descriptor).map(\.name)), ["qualifying", "empty"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(descriptor)), Set([qualifying.persistentModelID, empty.persistentModelID]))

        let reversedDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.numbers.allSatisfy { lowerBound <= $0 } },
            includePendingChanges: false)
        XCTAssertEqual(Set(try context.fetch(reversedDescriptor).map(\.name)), ["qualifying", "empty"])

        violating.numbers = [4, 8]
        let pendingDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.numbers.allSatisfy { $0 >= lowerBound } })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["qualifying", "violating", "empty"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([qualifying.persistentModelID, violating.persistentModelID, empty.persistentModelID]))
    }

    @MainActor
    func testNestedRelationshipContainsWhereSupportsTwoDirectLevels() throws {
        let container = try ModelContainer(
            for: QuantifierOwnerFixture.self,
            QuantifierChildFixture.self,
            QuantifierItemFixture.self,
            configurations: .sqliteMemory("nested-relationship-quantifier-depth-two"))
        let context = container.mainContext
        let match = QuantifierItemFixture(value: "match")
        let other = QuantifierItemFixture(value: "other")
        let matchingChild = QuantifierChildFixture(name: "matching-child", items: [match])
        let otherChild = QuantifierChildFixture(name: "other-child", items: [other])
        let matchingOwner = QuantifierOwnerFixture(name: "matching-owner", children: [matchingChild])
        let otherOwner = QuantifierOwnerFixture(name: "other-owner", children: [otherChild])
        let emptyOwner = QuantifierOwnerFixture(name: "empty-owner", children: [])
        context.insert(match)
        context.insert(other)
        context.insert(matchingChild)
        context.insert(otherChild)
        context.insert(matchingOwner)
        context.insert(otherOwner)
        context.insert(emptyOwner)
        try context.save()

        let needle = "match"
        let descriptor = FetchDescriptor<QuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.children.contains(where: { child in
                    child.items.contains(where: { $0.value == needle })
                })
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["matching-owner"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), [matchingOwner.persistentModelID])

        let pending = QuantifierItemFixture(value: needle)
        context.insert(pending)
        otherChild.items.append(pending)
        let pendingDescriptor = FetchDescriptor<QuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.children.contains(where: { child in
                    child.items.contains(where: { $0.value == needle })
                })
            })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["matching-owner", "other-owner"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
        XCTAssertEqual(
            Set(try context.fetchIdentifiers(pendingDescriptor)),
            Set([matchingOwner.persistentModelID, otherOwner.persistentModelID]))

        let nestedStringDescriptor = FetchDescriptor<QuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.children.contains(where: { child in
                    child.items.contains(where: { item in
                        item.value.contains(needle)
                    })
                })
            })
        XCTAssertEqual(
            Set(try context.fetch(nestedStringDescriptor).map(\.name)), ["matching-owner", "other-owner"])
    }

    @MainActor
    func testNestedRelationshipContainsWhereSupportsThreeDirectLevels() throws {
        let container = try ModelContainer(
            for: ThreeLevelQuantifierOwnerFixture.self,
            ThreeLevelQuantifierGroupFixture.self,
            ThreeLevelQuantifierChildFixture.self,
            ThreeLevelQuantifierItemFixture.self,
            configurations: .sqliteMemory("nested-relationship-quantifier-depth-three"))
        let context = container.mainContext
        let accepted = ThreeLevelQuantifierItemFixture(value: "match")
        let rejected = ThreeLevelQuantifierItemFixture(value: "other")
        let matchingChild = ThreeLevelQuantifierChildFixture(name: "matching-child", items: [accepted])
        let failingChild = ThreeLevelQuantifierChildFixture(name: "failing-child", items: [rejected])
        let emptyChild = ThreeLevelQuantifierChildFixture(name: "empty-child", items: [])
        let matchingGroup = ThreeLevelQuantifierGroupFixture(name: "matching-group", children: [matchingChild])
        let failingGroup = ThreeLevelQuantifierGroupFixture(name: "failing-group", children: [failingChild])
        let emptyGroup = ThreeLevelQuantifierGroupFixture(name: "empty-group", children: [emptyChild])
        let emptyOwnerGroup = ThreeLevelQuantifierOwnerFixture(name: "empty-owner-group", groups: [emptyGroup])
        let matchingOwner = ThreeLevelQuantifierOwnerFixture(name: "matching-owner", groups: [matchingGroup])
        let failingOwner = ThreeLevelQuantifierOwnerFixture(name: "failing-owner", groups: [failingGroup])
        let emptyOwner = ThreeLevelQuantifierOwnerFixture(name: "empty-owner", groups: [])
        context.insert(accepted)
        context.insert(rejected)
        context.insert(matchingChild)
        context.insert(failingChild)
        context.insert(emptyChild)
        context.insert(matchingGroup)
        context.insert(failingGroup)
        context.insert(emptyGroup)
        context.insert(emptyOwnerGroup)
        context.insert(matchingOwner)
        context.insert(failingOwner)
        context.insert(emptyOwner)
        try context.save()

        let needle = "match"
        let descriptor = FetchDescriptor<ThreeLevelQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.value == needle }
                    }
                }
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["matching-owner"])

        let pendingItem = ThreeLevelQuantifierItemFixture(value: needle)
        context.insert(pendingItem)
        failingChild.items.append(pendingItem)
        let pendingDescriptor = FetchDescriptor<ThreeLevelQuantifierOwnerFixture>(
            predicate: #Predicate {
                $0.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.value == needle }
                    }
                }
            })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["matching-owner", "failing-owner"])

    }

    @MainActor
    func testNestedContainsAndAllSatisfyHonorVacuousTruthAtThreeLevels() throws {
        let container = try ModelContainer(
            for: ThreeLevelQuantifierOwnerFixture.self,
            ThreeLevelQuantifierGroupFixture.self,
            ThreeLevelQuantifierChildFixture.self,
            ThreeLevelQuantifierItemFixture.self,
            configurations: .sqliteMemory("nested-contains-all-satisfy-depth-three"))
        let context = container.mainContext
        let matchingItem = ThreeLevelQuantifierItemFixture(value: "match")
        let existentialItem = ThreeLevelQuantifierItemFixture(value: "match")
        let mixedMatchingItem = ThreeLevelQuantifierItemFixture(value: "match")
        let nonmatchingItem = ThreeLevelQuantifierItemFixture(value: "other")
        let matchingChild = ThreeLevelQuantifierChildFixture(name: "matching", items: [matchingItem])
        let existentialChild = ThreeLevelQuantifierChildFixture(name: "existential", items: [existentialItem])
        let mixedMatchingChild = ThreeLevelQuantifierChildFixture(name: "matching", items: [mixedMatchingItem])
        let mixedChild = ThreeLevelQuantifierChildFixture(name: "mixed", items: [nonmatchingItem])
        let emptyChild = ThreeLevelQuantifierChildFixture(name: "empty", items: [])
        let matchingGroup = ThreeLevelQuantifierGroupFixture(name: "matching", children: [matchingChild])
        let mixedGroup = ThreeLevelQuantifierGroupFixture(
            name: "mixed", children: [mixedMatchingChild, mixedChild])
        let existentialGroup = ThreeLevelQuantifierGroupFixture(name: "existential", children: [existentialChild])
        let emptyChildGroup = ThreeLevelQuantifierGroupFixture(name: "empty-child", children: [emptyChild])
        let emptyGroup = ThreeLevelQuantifierGroupFixture(name: "empty-group", children: [])
        let matchingOwner = ThreeLevelQuantifierOwnerFixture(name: "matching", groups: [matchingGroup])
        let mixedOwner = ThreeLevelQuantifierOwnerFixture(name: "mixed", groups: [mixedGroup])
        let existentialOwner = ThreeLevelQuantifierOwnerFixture(
            name: "existential", groups: [mixedGroup, existentialGroup])
        let emptyChildOwner = ThreeLevelQuantifierOwnerFixture(name: "empty-child", groups: [emptyChildGroup])
        let emptyGroupOwner = ThreeLevelQuantifierOwnerFixture(name: "empty-group", groups: [emptyGroup])
        let emptyOwner = ThreeLevelQuantifierOwnerFixture(name: "empty-owner", groups: [])
        for model in [matchingItem, existentialItem, mixedMatchingItem, nonmatchingItem] { context.insert(model) }
        for model in [matchingChild, existentialChild, mixedMatchingChild, mixedChild, emptyChild] {
            context.insert(model)
        }
        for model in [matchingGroup, mixedGroup, existentialGroup, emptyChildGroup, emptyGroup] {
            context.insert(model)
        }
        for model in [matchingOwner, mixedOwner, existentialOwner, emptyChildOwner, emptyGroupOwner, emptyOwner] {
            context.insert(model)
        }
        try context.save()

        let expected = "match"
        let descriptor = FetchDescriptor<ThreeLevelQuantifierOwnerFixture>(
            predicate: #Predicate { owner in
                owner.groups.contains { group in
                    group.children.allSatisfy { child in
                        child.items.allSatisfy { $0.value == expected }
                    }
                }
            },
            includePendingChanges: false)
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(Set(fetched.map(\.name)), Set(["empty-child", "empty-group", "existential", "matching"]))
        XCTAssertEqual(try context.fetchCount(descriptor), 4)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), fetched.map(\.persistentModelID))

        let pendingItem = ThreeLevelQuantifierItemFixture(value: "other")
        context.insert(pendingItem)
        matchingChild.items.append(pendingItem)
        let pendingDescriptor = FetchDescriptor<ThreeLevelQuantifierOwnerFixture>(
            predicate: #Predicate { owner in
                owner.groups.contains { group in
                    group.children.allSatisfy { child in
                        child.items.allSatisfy { $0.value == expected }
                    }
                }
            })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(Set(pendingMatches.map(\.name)), Set(["empty-child", "empty-group", "existential"]))
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))
        XCTAssertEqual(try context.fetch(descriptor).map(\.persistentModelID), fetched.map(\.persistentModelID))
        XCTAssertEqual(try context.fetchCount(descriptor), 4)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), fetched.map(\.persistentModelID))
        try context.save()
        let savedMatches = try context.fetch(descriptor)
        XCTAssertEqual(Set(savedMatches.map(\.name)), Set(["empty-child", "empty-group", "existential"]))
        XCTAssertEqual(try context.fetchCount(descriptor), 3)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), savedMatches.map(\.persistentModelID))
    }

    @MainActor
    func testNestedThreeLevelContainsMatchesSubtypeOnlyHierarchyDestinationValues() throws {
        let container = try ModelContainer(
            for: ThreeLevelHierarchyQuantifierOwnerFixture.self,
            ThreeLevelHierarchyQuantifierGroupFixture.self,
            ThreeLevelHierarchyQuantifierChildFixture.self,
            ThreeLevelHierarchyQuantifierItemLeafFixture.self,
            ThreeLevelHierarchyQuantifierItemSiblingFixture.self,
            configurations: .sqliteMemory("nested-hierarchy-quantifier-depth-three"))
        let context = container.mainContext
        let matchingItem = ThreeLevelHierarchyQuantifierItemLeafFixture(title: "match", code: "leaf")
        let nonmatchingItem = ThreeLevelHierarchyQuantifierItemLeafFixture(title: "miss", code: "match")
        let siblingItem = ThreeLevelHierarchyQuantifierItemSiblingFixture(title: "match", label: "sibling")
        let matchingChild = ThreeLevelHierarchyQuantifierChildFixture(items: [matchingItem])
        let nonmatchingChild = ThreeLevelHierarchyQuantifierChildFixture(items: [nonmatchingItem])
        let siblingChild = ThreeLevelHierarchyQuantifierChildFixture(items: [siblingItem])
        let matchingGroup = ThreeLevelHierarchyQuantifierGroupFixture(children: [matchingChild])
        let nonmatchingGroup = ThreeLevelHierarchyQuantifierGroupFixture(children: [nonmatchingChild])
        let siblingGroup = ThreeLevelHierarchyQuantifierGroupFixture(children: [siblingChild])
        let matchingOwner = ThreeLevelHierarchyQuantifierOwnerFixture(
            name: "matching", groups: [matchingGroup])
        let nonmatchingOwner = ThreeLevelHierarchyQuantifierOwnerFixture(
            name: "nonmatching", groups: [nonmatchingGroup])
        let siblingOwner = ThreeLevelHierarchyQuantifierOwnerFixture(
            name: "sibling", groups: [siblingGroup])
        let emptyOwner = ThreeLevelHierarchyQuantifierOwnerFixture(name: "empty", groups: [])
        for model in [matchingItem, nonmatchingItem, siblingItem] { context.insert(model) }
        for model in [matchingChild, nonmatchingChild, siblingChild] { context.insert(model) }
        for model in [matchingGroup, nonmatchingGroup, siblingGroup] { context.insert(model) }
        for model in [matchingOwner, nonmatchingOwner, siblingOwner, emptyOwner] { context.insert(model) }
        try context.save()

        let descriptor = FetchDescriptor<ThreeLevelHierarchyQuantifierOwnerFixture>(
            predicate: #Predicate { owner in
                owner.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.title == "match" }
                    }
                }
            },
            includePendingChanges: false)
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.map(\.name), ["matching", "sibling"])
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), fetched.map(\.persistentModelID))

        let pendingItem = ThreeLevelHierarchyQuantifierItemLeafFixture(title: "match", code: "pending")
        context.insert(pendingItem)
        nonmatchingOwner.groups[0].children[0].items.append(pendingItem)
        let pendingDescriptor = FetchDescriptor<ThreeLevelHierarchyQuantifierOwnerFixture>(
            predicate: #Predicate { owner in
                owner.groups.contains { group in
                    group.children.contains { child in
                        child.items.contains { $0.title == "match" }
                    }
                }
            })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(pendingMatches.map(\.name), ["matching", "nonmatching", "sibling"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 3)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))
    }

    @MainActor
    func testUInt64CollectionAllSatisfyOrderingSupportsFullRange() throws {
        let container = try ModelContainer(
            for: UInt64CollectionFixture.self,
            configurations: .sqliteMemory("uint64-collection-all-satisfy-full-range"))
        let context = container.mainContext
        let models = [
            UInt64CollectionFixture(values: [0, UInt64(Int64.max)]),
            UInt64CollectionFixture(values: [UInt64(Int64.max) + 1]),
            UInt64CollectionFixture(values: [UInt64.max]),
            UInt64CollectionFixture(values: []),
        ]
        for model in models { context.insert(model) }
        try context.save()

        let maxValue = UInt64.max
        let beyondSignedRange = UInt64(Int64.max) + 1
        let lessDescriptor = FetchDescriptor<UInt64CollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 < maxValue } }, includePendingChanges: false)
        XCTAssertEqual(
            Set(try context.fetch(lessDescriptor).map(\.persistentModelID)),
            Set([models[0].persistentModelID, models[1].persistentModelID, models[3].persistentModelID]))
        let lessEqualDescriptor = FetchDescriptor<UInt64CollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 <= maxValue } }, includePendingChanges: false)
        XCTAssertEqual(try context.fetch(lessEqualDescriptor).map(\.persistentModelID), models.map(\.persistentModelID))
        let greaterDescriptor = FetchDescriptor<UInt64CollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 > beyondSignedRange } }, includePendingChanges: false)
        XCTAssertEqual(
            Set(try context.fetch(greaterDescriptor).map(\.persistentModelID)),
            Set([models[2].persistentModelID, models[3].persistentModelID]))
        let greaterEqualDescriptor = FetchDescriptor<UInt64CollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 >= beyondSignedRange } }, includePendingChanges: false)
        XCTAssertEqual(
            Set(try context.fetch(greaterEqualDescriptor).map(\.persistentModelID)),
            Set([models[1].persistentModelID, models[2].persistentModelID, models[3].persistentModelID]))

        let pending = UInt64CollectionFixture(values: [UInt64.max])
        context.insert(pending)
        let pendingBound = UInt64.max - 1
        let pendingDescriptor = FetchDescriptor<UInt64CollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 > pendingBound } })
        XCTAssertEqual(
            Set(try context.fetch(pendingDescriptor).map(\.persistentModelID)),
            Set([models[2].persistentModelID, models[3].persistentModelID, pending.persistentModelID]))
        let signedBoundary = UInt64(Int64.max)
        let pendingSignedBoundaryDescriptor = FetchDescriptor<UInt64CollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 > signedBoundary } })
        XCTAssertEqual(
            Set(try context.fetch(pendingSignedBoundaryDescriptor).map(\.persistentModelID)),
            Set([
                models[1].persistentModelID, models[2].persistentModelID,
                models[3].persistentModelID, pending.persistentModelID,
            ]))
    }

    @MainActor
    func testUIntCollectionAllSatisfyOrderingUsesUnsignedComparison() throws {
        let container = try ModelContainer(
            for: UIntCollectionFixture.self,
            configurations: .sqliteMemory("uint-collection-all-satisfy"))
        let context = container.mainContext
        let maximum = UInt.max
        let model = UIntCollectionFixture(values: [maximum])
        context.insert(model)
        try context.save()

        let lowerBound = maximum - 1
        let storedDescriptor = FetchDescriptor<UIntCollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 > lowerBound } },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(storedDescriptor).map(\.persistentModelID), [model.persistentModelID])

        let pending = UIntCollectionFixture(values: [maximum])
        context.insert(pending)
        let pendingDescriptor = FetchDescriptor<UIntCollectionFixture>(
            predicate: #Predicate { $0.values.allSatisfy { $0 > lowerBound } })
        XCTAssertEqual(
            Set(try context.fetch(pendingDescriptor).map(\.persistentModelID)),
            Set([model.persistentModelID, pending.persistentModelID]))
    }

    @MainActor
    func testInferredAndExplicitCodableCollectionsHaveEquivalentSchema() throws {
        let inferredContainer = try ModelContainer(
            for: CodableStringCollectionFixture.self,
            configurations: .sqliteMemory("inferred-codable-collection-parity"))
        let explicitContainer = try ModelContainer(
            for: ExplicitCodableStringCollectionFixture.self,
            configurations: .sqliteMemory("explicit-codable-collection-parity"))
        let inferredAttribute = try XCTUnwrap(
            inferredContainer.schema.entity(forName: "CodableStringCollectionFixture")?.attributes
                .first(where: { $0.name == "tags" }))
        let explicitAttribute = try XCTUnwrap(
            explicitContainer.schema.entity(forName: "ExplicitCodableStringCollectionFixture")?.attributes
                .first(where: { $0.name == "tags" }))
        XCTAssertEqual(inferredAttribute, explicitAttribute)
        let inferredOptionalAttribute = try XCTUnwrap(
            inferredContainer.schema.entity(forName: "CodableStringCollectionFixture")?.attributes
                .first(where: { $0.name == "optionalTags" }))
        let explicitOptionalAttribute = try XCTUnwrap(
            explicitContainer.schema.entity(forName: "ExplicitCodableStringCollectionFixture")?.attributes
                .first(where: { $0.name == "optionalTags" }))
        XCTAssertEqual(inferredOptionalAttribute, explicitOptionalAttribute)

        let inferredContext = inferredContainer.mainContext
        let explicitContext = explicitContainer.mainContext
        let inferred = CodableStringCollectionFixture(name: "inferred", tags: ["shared"])
        let explicit = ExplicitCodableStringCollectionFixture(tags: ["shared"], optionalTags: nil)
        inferredContext.insert(inferred)
        explicitContext.insert(explicit)
        try inferredContext.save()
        try explicitContext.save()

        let needle = "shared"
        let inferredDescriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.contains(needle) })
        let explicitDescriptor = FetchDescriptor<ExplicitCodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.contains(needle) })
        XCTAssertEqual(try inferredContext.fetch(inferredDescriptor).map(\.name), ["inferred"])
        XCTAssertEqual(try explicitContext.fetch(explicitDescriptor).count, 1)
    }

    @MainActor
    func testOptionalInferredIntegerSetPersistsAndSupportsMembership() throws {
        let container = try ModelContainer(
            for: OptionalIntegerSetFixture.self,
            configurations: .sqliteMemory("optional-inferred-integer-set"))
        let context = container.mainContext
        let matching = OptionalIntegerSetFixture(name: "matching", values: [3, 8])
        let empty = OptionalIntegerSetFixture(name: "empty", values: [])
        let nilValue = OptionalIntegerSetFixture(name: "nil", values: nil)
        context.insert(matching)
        context.insert(empty)
        context.insert(nilValue)
        try context.save()

        let value = 8
        let descriptor = FetchDescriptor<OptionalIntegerSetFixture>(
            predicate: #Predicate { $0.values.flatMap { $0.contains(value) } ?? false },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["matching"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), [matching.persistentModelID])

        matching.values = []
        nilValue.values = [value]
        let pendingDescriptor = FetchDescriptor<OptionalIntegerSetFixture>(
            predicate: #Predicate { $0.values.flatMap { $0.contains(value) } ?? false })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["nil"])
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [nilValue.persistentModelID])
    }

    @MainActor
    func testBoolCollectionMembershipRejectsNumericJSONPayload() throws {
        let container = try ModelContainer(
            for: CodableStringCollectionFixture.self,
            configurations: .sqliteMemory("codable-bool-collection-type-check"))
        let context = container.mainContext
        let model = CodableStringCollectionFixture(name: "numeric-payload", tags: [], flags: [true])
        context.insert(model)
        try context.save()
        let primaryKey = try XCTUnwrap(model.persistentModelID.primaryKey)
        try XCTUnwrap(container.store).write { connection in
            try connection.execute(
                "UPDATE ZCODABLESTRINGCOLLECTIONFIXTURE SET ZFLAGS = ? WHERE Z_PK = ?",
                arguments: [.blob(Array("[1]".utf8)), .int(primaryKey)])
        }

        let reader = container.makeContext()
        let trueValue = true
        let descriptor = FetchDescriptor<CodableStringCollectionFixture>(
            predicate: #Predicate { $0.flags.contains(trueValue) },
            includePendingChanges: false)
        XCTAssertTrue(try reader.fetch(descriptor).isEmpty)
        XCTAssertEqual(try reader.fetchCount(descriptor), 0)
    }

    @MainActor
    func testOptionalElementCollectionsSupportContainsNilAndValue() throws {
        let container = try ModelContainer(
            for: OptionalScalarElementsFixture.self,
            configurations: .sqliteMemory("optional-element-collection-membership"))
        let schemaEntity = try XCTUnwrap(container.schema.entity(forName: "OptionalScalarElementsFixture"))
        XCTAssertEqual(
            schemaEntity.attributes.first(where: { $0.name == "optionalStrings" })?.type,
            "Array<Optional<String>>")
        let context = container.mainContext
        let empty = OptionalScalarElementsFixture(
            name: "empty", optionalStrings: [], optionalNumbers: [], optionalFlags: [])
        let nilOnly = OptionalScalarElementsFixture(
            name: "nil-only", optionalStrings: [nil], optionalNumbers: [nil], optionalFlags: [nil])
        let mixed = OptionalScalarElementsFixture(
            name: "mixed", requiredStrings: ["needle"], optionalStrings: ["needle", nil], optionalNumbers: [7, nil],
            optionalFlags: [true, nil])
        let other = OptionalScalarElementsFixture(
            name: "other", optionalStrings: ["other"], optionalNumbers: [9], optionalFlags: [false])
        for model in [empty, nilOnly, mixed, other] { context.insert(model) }
        try context.save()

        let containsStringNil = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalStrings.contains(nil) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(containsStringNil).map(\.name), ["mixed", "nil-only"])
        XCTAssertEqual(try context.fetchCount(containsStringNil), 2)
        XCTAssertEqual(
            try context.fetchIdentifiers(containsStringNil),
            try context.fetch(containsStringNil).map(\.persistentModelID))
        let requiredString = "needle"
        let requiredContains = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.requiredStrings.contains(requiredString) })
        XCTAssertEqual(try context.fetch(requiredContains).map(\.name), ["mixed"])

        let stringValue = "needle"
        let containsStringValue = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalStrings.contains(stringValue) },
            sortBy: [SortDescriptor(\.name)])
        let stringValueMatches = try context.fetch(containsStringValue)
        XCTAssertEqual(stringValueMatches.map(\.name), ["mixed"])
        XCTAssertEqual(try context.fetchCount(containsStringValue), 1)
        XCTAssertEqual(
            try context.fetchIdentifiers(containsStringValue), stringValueMatches.map(\.persistentModelID))
        let optionalStringValue: String? = "needle"
        let containsOptionalStringValue = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalStrings.contains(optionalStringValue) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(containsOptionalStringValue).map(\.name), ["mixed"])

        let containsIntegerNil = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalNumbers.contains(nil) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(containsIntegerNil).map(\.name), ["mixed", "nil-only"])
        XCTAssertEqual(try context.fetchCount(containsIntegerNil), 2)
        XCTAssertEqual(
            try context.fetchIdentifiers(containsIntegerNil),
            try context.fetch(containsIntegerNil).map(\.persistentModelID))

        let containsFlagNil = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalFlags.contains(nil) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(containsFlagNil).map(\.name), ["mixed", "nil-only"])
        XCTAssertEqual(try context.fetchCount(containsFlagNil), 2)
        let flagValue = true
        let containsFlagValue = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalFlags.contains(flagValue) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(containsFlagValue).map(\.name), ["mixed"])
        let store = try XCTUnwrap(container.store)
        let numericOne = try store.read { connection in
            try connection.rows(
                "SELECT osd_json_array_contains(?, ?, ?)",
                arguments: [.blob(Array("[1]".utf8)), .int(1), .text("Optional<Bool>")])
        }
        XCTAssertEqual(numericOne, [[.int(0)]])
        let booleanTrue = try store.read { connection in
            try connection.rows(
                "SELECT osd_json_array_contains(?, ?, ?)",
                arguments: [.blob(Array("[true]".utf8)), .int(1), .text("Optional<Int>")])
        }
        XCTAssertEqual(booleanTrue, [[.int(0)]])
        let optionalAllEqual = try store.read { connection in
            try connection.rows(
                "SELECT osd_json_array_all_equal(?, ?, ?)",
                arguments: [.blob(Array("[null]".utf8)), .null, .text("Optional<String>")])
        }
        XCTAssertTrue(optionalAllEqual.isEmpty || optionalAllEqual[0][0] == .null)

        let integerValue = 7
        let containsIntegerValue = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalNumbers.contains(integerValue) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(containsIntegerValue).map(\.name), ["mixed"])
        let optionalIntegerValue: Int? = 7
        let containsOptionalIntegerValue = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalNumbers.contains(optionalIntegerValue) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(containsOptionalIntegerValue).map(\.name), ["mixed"])

        XCTAssertThrowsError(
            try context.fetch(
                FetchDescriptor<OptionalScalarElementsFixture>(
                    predicate: #Predicate { $0.optionalStrings.allSatisfy { $0 == nil } })))
        XCTAssertThrowsError(
            try context.fetch(
                FetchDescriptor<OptionalScalarElementsFixture>(
                    predicate: #Predicate { $0.optionalStrings.isEmpty })))
        XCTAssertThrowsError(
            try context.fetch(
                FetchDescriptor<OptionalScalarElementsFixture>(
                    predicate: #Predicate { $0.optionalStringCollection?.contains(nil) ?? false })))

        mixed.optionalStrings = [nil]
        mixed.optionalNumbers = [nil]
        mixed.optionalFlags = [nil]
        XCTAssertEqual(try context.fetch(containsStringNil).map(\.name), ["mixed", "nil-only"])
        XCTAssertEqual(try context.fetch(containsStringValue).map(\.name), [])
        XCTAssertEqual(try context.fetch(containsIntegerNil).map(\.name), ["mixed", "nil-only"])
        XCTAssertEqual(try context.fetch(containsIntegerValue).map(\.name), [])
        XCTAssertEqual(try context.fetch(containsFlagNil).map(\.name), ["mixed", "nil-only"])
        XCTAssertEqual(try context.fetch(containsFlagValue).map(\.name), [])
        XCTAssertEqual(try context.fetchCount(containsStringValue), 0)
        XCTAssertTrue(try context.fetchIdentifiers(containsStringValue).isEmpty)

        let optionalIntegerNil: Int? = nil
        let capturedNil = FetchDescriptor<OptionalScalarElementsFixture>(
            predicate: #Predicate { $0.optionalNumbers.contains(optionalIntegerNil) },
            sortBy: [SortDescriptor(\.name)])
        XCTAssertEqual(try context.fetch(capturedNil).map(\.name), ["mixed", "nil-only"])
    }

    @MainActor
    func testOptionalCodableCollectionMembershipSupportsNilAndPendingValues() throws {
        let container = try ModelContainer(
            for: OptionalCodableStringCollectionFixture.self,
            configurations: .sqliteMemory("optional-codable-string-collection"))
        let context = container.mainContext
        let matching = OptionalCodableStringCollectionFixture(name: "matching", tags: ["swift"])
        let empty = OptionalCodableStringCollectionFixture(name: "empty", tags: [])
        let nilValue = OptionalCodableStringCollectionFixture(name: "nil", tags: nil)
        context.insert(matching)
        context.insert(empty)
        context.insert(nilValue)
        try context.save()

        let needle = "swift"
        let descriptor = FetchDescriptor<OptionalCodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.flatMap { $0.contains(needle) } ?? false },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["matching"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), [matching.persistentModelID])

        matching.tags = []
        nilValue.tags = [needle]
        let pendingDescriptor = FetchDescriptor<OptionalCodableStringCollectionFixture>(
            predicate: #Predicate { $0.tags.flatMap { $0.contains(needle) } ?? false })
        XCTAssertEqual(try context.fetch(pendingDescriptor).map(\.name), ["nil"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), [nilValue.persistentModelID])
    }

    func testPendingBoolCollectionMembershipRejectsNumericJSONPayload() throws {
        let plan = PredicatePlan.collectionContains("flags", "Bool", .value(.int(1)))
        let matches = try RuntimePredicateEvaluator.matches(
            plan, values: ["flags": .blob(Array("[1]".utf8))])
        XCTAssertFalse(matches)
    }

    @MainActor
    func testQualifiedOptionalScalarTypesRemainScalarAttributes() throws {
        let container = try ModelContainer(
            for: QualifiedOptionalScalarFixture.self,
            configurations: .sqliteMemory("qualified-optional-scalars"))
        let entity = try XCTUnwrap(container.schema.entity(forName: "QualifiedOptionalScalarFixture"))
        XCTAssertEqual(Set(entity.attributes.map(\.name)), ["id", "link", "amount"])
        XCTAssertTrue(entity.relationships.isEmpty)

        let context = container.mainContext
        let model = QualifiedOptionalScalarFixture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            link: URL(string: "https://example.com/item"),
            amount: Decimal(string: "12.50"))
        context.insert(model)
        try context.save()
        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<QualifiedOptionalScalarFixture>()).first)
        XCTAssertEqual(fetched.id, model.id)
        XCTAssertEqual(fetched.link, model.link)
        XCTAssertEqual(fetched.amount, model.amount)
    }

    @MainActor
    func testOptionalToOneIntegerPredicateSupportsCoalescingAndPendingValues() throws {
        let container = try ModelContainer(
            for: OptionalToOneIntegerOwnerFixture.self,
            OptionalToOneIntegerTargetFixture.self,
            configurations: .sqliteMemory("optional-to-one-integer-coalesce"))
        let context = container.mainContext
        let highTarget = OptionalToOneIntegerTargetFixture(rank: 9)
        let lowTarget = OptionalToOneIntegerTargetFixture(rank: 2)
        context.insert(highTarget)
        context.insert(lowTarget)
        context.insert(OptionalToOneIntegerOwnerFixture(name: "high", target: highTarget))
        context.insert(OptionalToOneIntegerOwnerFixture(name: "low", target: lowTarget))
        context.insert(OptionalToOneIntegerOwnerFixture(name: "nil", target: nil))
        try context.save()

        let descriptor = FetchDescriptor<OptionalToOneIntegerOwnerFixture>(
            predicate: #Predicate { owner in (owner.target?.rank ?? 0) > 3 },
            includePendingChanges: false)
        let storedMatches = try context.fetch(descriptor)
        XCTAssertEqual(storedMatches.map(\.name), ["high"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), storedMatches.map(\.persistentModelID))

        let increment = 2
        let limit = 10
        let arithmeticDescriptor = FetchDescriptor<OptionalToOneIntegerOwnerFixture>(
            predicate: #Predicate { owner in (owner.target?.rank ?? 0) + increment > limit },
            includePendingChanges: false)
        let arithmeticMatches = try context.fetch(arithmeticDescriptor)
        XCTAssertEqual(arithmeticMatches.map(\.name), ["high"])
        XCTAssertEqual(try context.fetchCount(arithmeticDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(arithmeticDescriptor), arithmeticMatches.map(\.persistentModelID))

        highTarget.rank = 1
        XCTAssertTrue(highTarget.hasChanges)
        XCTAssertTrue(context.hasChanges)
        let pendingDescriptor = FetchDescriptor<OptionalToOneIntegerOwnerFixture>(
            predicate: #Predicate { owner in (owner.target?.rank ?? 0) > 3 })
        XCTAssertTrue(try context.fetch(pendingDescriptor).isEmpty)
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 0)
        XCTAssertTrue(try context.fetchIdentifiers(pendingDescriptor).isEmpty)
        let pendingArithmetic = FetchDescriptor<OptionalToOneIntegerOwnerFixture>(
            predicate: #Predicate { owner in (owner.target?.rank ?? 0) + increment > limit })
        XCTAssertTrue(try context.fetch(pendingArithmetic).isEmpty)
        XCTAssertEqual(try context.fetchCount(pendingArithmetic), 0)
        XCTAssertTrue(try context.fetchIdentifiers(pendingArithmetic).isEmpty)

        let zero = 0
        let pendingNilDefault = FetchDescriptor<OptionalToOneIntegerOwnerFixture>(
            predicate: #Predicate { owner in (owner.target?.rank ?? 0) == zero })
        XCTAssertEqual(try context.fetch(pendingNilDefault).map(\.name), ["nil"])
    }

    @MainActor
    func testOptionalToOneDatePredicateMatchesStoredAndPendingValues() throws {
        let container = try ModelContainer(
            for: OptionalToOneDateOwnerFixture.self,
            OptionalToOneDateTargetFixture.self,
            configurations: .sqliteMemory("optional-to-one-date-predicate"))
        let context = container.mainContext
        let selectedDate = Date(timeIntervalSinceReferenceDate: 12.5)
        let otherDate = Date(timeIntervalSinceReferenceDate: 42.25)
        let selectedTarget = OptionalToOneDateTargetFixture(timestamp: selectedDate)
        let otherTarget = OptionalToOneDateTargetFixture(timestamp: otherDate)
        context.insert(selectedTarget)
        context.insert(otherTarget)
        context.insert(OptionalToOneDateOwnerFixture(name: "selected", target: selectedTarget))
        context.insert(OptionalToOneDateOwnerFixture(name: "other", target: otherTarget))
        context.insert(OptionalToOneDateOwnerFixture(name: "nil", target: nil))
        try context.save()

        let storedDescriptor = FetchDescriptor<OptionalToOneDateOwnerFixture>(
            predicate: #Predicate { $0.target?.timestamp == selectedDate },
            includePendingChanges: false)
        let storedMatches = try context.fetch(storedDescriptor)
        XCTAssertEqual(storedMatches.map(\.name), ["selected"])
        XCTAssertEqual(try context.fetchCount(storedDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(storedDescriptor), storedMatches.map(\.persistentModelID))

        selectedTarget.timestamp = otherDate
        let pendingDescriptor = FetchDescriptor<OptionalToOneDateOwnerFixture>(
            predicate: #Predicate { $0.target?.timestamp == otherDate })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(pendingMatches.map(\.name), ["selected", "other"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))
    }

    @MainActor
    func testOptionalToOneDecimalOrderingMatchesNumericSemanticsAcrossFetchModes() throws {
        let container = try ModelContainer(
            for: OptionalToOneDecimalOwnerFixture.self,
            OptionalToOneDecimalTargetFixture.self,
            configurations: .sqliteMemory("optional-to-one-decimal-ordering"))
        let context = container.mainContext
        let target = OptionalToOneDecimalTargetFixture(amount: Decimal(string: "10")!)
        let negativeOne = OptionalToOneDecimalTargetFixture(amount: Decimal(string: "-1")!)
        let negativeTwo = OptionalToOneDecimalTargetFixture(amount: Decimal(string: "-2")!)
        let equivalentDecimal = OptionalToOneDecimalTargetFixture(amount: Decimal(string: "1.00")!)
        context.insert(target)
        context.insert(negativeOne)
        context.insert(negativeTwo)
        context.insert(equivalentDecimal)
        context.insert(OptionalToOneDecimalOwnerFixture(target: target))
        context.insert(OptionalToOneDecimalOwnerFixture(target: negativeOne))
        context.insert(OptionalToOneDecimalOwnerFixture(target: negativeTwo))
        context.insert(OptionalToOneDecimalOwnerFixture(target: equivalentDecimal))
        context.insert(OptionalToOneDecimalOwnerFixture(target: nil))
        try context.save()

        let decimalSort = FetchDescriptor<OptionalToOneDecimalTargetFixture>(
            sortBy: [SortDescriptor(\.amount)],
            includePendingChanges: false)
        XCTAssertEqual(
            try context.fetch(decimalSort).map(\.amount),
            [Decimal(string: "-2")!, Decimal(string: "-1")!, Decimal(string: "1.00")!, Decimal(string: "10")!])

        let threshold = Decimal(string: "9")!
        let storedDescriptor = FetchDescriptor<OptionalToOneDecimalOwnerFixture>(
            predicate: #Predicate { $0.target.flatMap { $0.amount < threshold } ?? false },
            includePendingChanges: false)
        let storedMatches = try context.fetch(storedDescriptor)
        let expectedStoredIDs: Set<PersistentIdentifier> = [
            try XCTUnwrap(
                try context.fetch(FetchDescriptor<OptionalToOneDecimalOwnerFixture>()).first {
                    $0.target?.amount == Decimal(string: "-2")!
                }
            ).persistentModelID,
            try XCTUnwrap(
                try context.fetch(FetchDescriptor<OptionalToOneDecimalOwnerFixture>()).first {
                    $0.target?.amount == Decimal(string: "-1")!
                }
            ).persistentModelID,
            try XCTUnwrap(
                try context.fetch(FetchDescriptor<OptionalToOneDecimalOwnerFixture>()).first {
                    $0.target?.amount == Decimal(string: "1.00")!
                }
            ).persistentModelID,
        ]
        XCTAssertEqual(Set(storedMatches.map(\.persistentModelID)), expectedStoredIDs)
        XCTAssertEqual(try context.fetchCount(storedDescriptor), 3)
        XCTAssertEqual(try context.fetchIdentifiers(storedDescriptor), storedMatches.map(\.persistentModelID))

        negativeOne.amount = Decimal(string: "-3")!
        let pendingDecimalSort = FetchDescriptor<OptionalToOneDecimalTargetFixture>(sortBy: [SortDescriptor(\.amount)])
        XCTAssertEqual(
            try context.fetch(pendingDecimalSort).map(\.amount),
            [Decimal(string: "-3")!, Decimal(string: "-2")!, Decimal(string: "1.00")!, Decimal(string: "10")!])
        let pendingThreshold = Decimal(string: "-2")!
        let pendingDescriptor = FetchDescriptor<OptionalToOneDecimalOwnerFixture>(
            predicate: #Predicate { $0.target.flatMap { $0.amount < pendingThreshold } ?? false })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(pendingMatches.count, 1)
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))

        let zero = Decimal.zero
        let smallThreshold = Decimal(string: "1")!
        let coalescedStored = FetchDescriptor<OptionalToOneDecimalOwnerFixture>(
            predicate: #Predicate { ($0.target?.amount ?? zero) < smallThreshold },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(coalescedStored).count, 3)
        let coalescedPending = FetchDescriptor<OptionalToOneDecimalOwnerFixture>(
            predicate: #Predicate { ($0.target?.amount ?? zero) < smallThreshold })
        XCTAssertEqual(try context.fetch(coalescedPending).count, 3)

        let one = Decimal(string: "1.0")!
        let equivalentDescriptor = FetchDescriptor<OptionalToOneDecimalOwnerFixture>(
            predicate: #Predicate { $0.target?.amount == one },
            includePendingChanges: false)
        let equivalentMatches = try context.fetch(equivalentDescriptor)
        XCTAssertEqual(equivalentMatches.count, 1)
        XCTAssertEqual(try context.fetchCount(equivalentDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(equivalentDescriptor), equivalentMatches.map(\.persistentModelID))
    }

    @MainActor
    func testToManyPredicateSupportsIntegerRangeOnElement() throws {
        let container = try ModelContainer(
            for: CollectionRangeOwnerFixture.self,
            CollectionRangeElementFixture.self,
            configurations: .sqliteMemory("to-many-range-predicate"))
        let context = container.mainContext
        let inRangeElement = CollectionRangeElementFixture(rank: 6)
        let lowerBoundElement = CollectionRangeElementFixture(rank: 4)
        let upperBoundElement = CollectionRangeElementFixture(rank: 10)
        let outsideElement = CollectionRangeElementFixture(rank: 12)
        context.insert(inRangeElement)
        context.insert(lowerBoundElement)
        context.insert(upperBoundElement)
        context.insert(outsideElement)
        let inRangeOwner = CollectionRangeOwnerFixture(elements: [inRangeElement])
        context.insert(inRangeOwner)
        context.insert(CollectionRangeOwnerFixture(elements: [lowerBoundElement]))
        context.insert(CollectionRangeOwnerFixture(elements: [upperBoundElement]))
        context.insert(CollectionRangeOwnerFixture(elements: [outsideElement]))
        context.insert(CollectionRangeOwnerFixture(elements: []))
        try context.save()

        let descriptor = FetchDescriptor<CollectionRangeOwnerFixture>(
            predicate: #Predicate { owner in
                owner.elements.contains(where: { element in (4..<10).contains(element.rank) })
            },
            includePendingChanges: false)
        let storedMatches = try context.fetch(descriptor)
        XCTAssertEqual(storedMatches.count, 2)
        XCTAssertEqual(
            Set(storedMatches.map(\.persistentModelID)),
            Set([
                inRangeOwner.persistentModelID,
                try XCTUnwrap(
                    try context.fetch(FetchDescriptor<CollectionRangeOwnerFixture>())
                        .first(where: { $0.elements.first === lowerBoundElement })
                ).persistentModelID,
            ]))
        XCTAssertEqual(storedMatches.first?.persistentModelID, inRangeOwner.persistentModelID)
        XCTAssertEqual(try context.fetchCount(descriptor), 2)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), storedMatches.map(\.persistentModelID))

        inRangeElement.rank = 12
        XCTAssertTrue(inRangeElement.hasChanges)
        XCTAssertTrue(context.hasChanges)
        let pendingDescriptor = FetchDescriptor<CollectionRangeOwnerFixture>(
            predicate: #Predicate { owner in
                owner.elements.contains(where: { element in (4..<10).contains(element.rank) })
            })
        let pendingMatches = try context.fetch(pendingDescriptor)
        let lowerBoundOwner = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CollectionRangeOwnerFixture>())
                .first(where: { $0.elements.first === lowerBoundElement }))
        XCTAssertEqual(pendingMatches.map(\.persistentModelID), [lowerBoundOwner.persistentModelID])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))
    }

    @MainActor
    func testPredicateMatchesToManyRelationshipElements() throws {
        let container = try ModelContainer(
            for: InheritanceRelationshipBaseFixture.self,
            InheritanceRelationshipChildFixture.self,
            InheritanceRelationshipItemFixture.self,
            configurations: .sqliteMemory("hierarchy-to-many-membership-predicate"))
        let context = container.mainContext
        let selectedItem = InheritanceRelationshipItemFixture(title: "selected")
        let duplicateSelectedItem = InheritanceRelationshipItemFixture(title: "selected")
        let otherItem = InheritanceRelationshipItemFixture(title: "other")
        let nilTitleItem = InheritanceRelationshipItemFixture(title: "")
        context.insert(selectedItem)
        context.insert(duplicateSelectedItem)
        context.insert(otherItem)
        context.insert(nilTitleItem)
        context.insert(InheritanceRelationshipBaseFixture(items: [selectedItem, duplicateSelectedItem]))
        context.insert(InheritanceRelationshipChildFixture(items: [otherItem], age: 4))
        context.insert(InheritanceRelationshipBaseFixture(items: [nilTitleItem]))
        try context.save()

        let baseOwner = try XCTUnwrap(
            try context.fetch(FetchDescriptor<InheritanceRelationshipBaseFixture>())
                .first(where: { $0.items.contains(where: { $0 === selectedItem }) }))
        let emptyOwner = try XCTUnwrap(
            try context.fetch(FetchDescriptor<InheritanceRelationshipBaseFixture>())
                .first(where: { $0.items.first === nilTitleItem }))
        let childOwner = try XCTUnwrap(
            try context.fetch(FetchDescriptor<InheritanceRelationshipBaseFixture>())
                .first(where: { $0.items.first === otherItem }))
        let joinRows = try container.store?.read {
            try $0.rows(
                "SELECT Z_A, Z_B FROM Z_INHERITANCERELATIONSHIPBASEFIXTURE_ITEMS_INHERITANCERELATIONSHIPITEMFIXTURE ORDER BY Z_A",
                arguments: [])
        }
        let expectedJoinRows = [
            [baseOwner.persistentModelID.primaryKey, selectedItem.persistentModelID.primaryKey],
            [baseOwner.persistentModelID.primaryKey, duplicateSelectedItem.persistentModelID.primaryKey],
            [emptyOwner.persistentModelID.primaryKey, nilTitleItem.persistentModelID.primaryKey],
            [childOwner.persistentModelID.primaryKey, otherItem.persistentModelID.primaryKey],
        ].compactMap { pair -> [RuntimeValue]? in
            guard let ownerID = pair[0], let itemID = pair[1] else { return nil }
            return [.int(ownerID), .int(itemID)]
        }.sorted { lhs, rhs in
            guard case let .int(lhsID) = lhs[0], case let .int(rhsID) = rhs[0] else { return false }
            return lhsID < rhsID
        }
        XCTAssertEqual(joinRows, expectedJoinRows)

        let selectedTitle = selectedItem.title
        let descriptor = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title == selectedTitle })
            },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches[0].items.first === selectedItem)
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        let titleFragment = "lect"
        let containsDescriptor = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title.contains(titleFragment) })
            },
            includePendingChanges: false)
        let containsMatches = try context.fetch(containsDescriptor)
        XCTAssertEqual(containsMatches.map(\.persistentModelID), matches.map(\.persistentModelID))
        XCTAssertEqual(try context.fetchCount(containsDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(containsDescriptor), containsMatches.map(\.persistentModelID))

        let titlePrefix = "sel"
        let startsWithDescriptor = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title.starts(with: titlePrefix) })
            },
            includePendingChanges: false)
        XCTAssertEqual(
            try context.fetch(startsWithDescriptor).map(\.persistentModelID), matches.map(\.persistentModelID))

        let pendingTitle = "pending-title"
        selectedItem.title = pendingTitle
        let pendingDescriptor = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title == pendingTitle })
            })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(pendingMatches.count, 1)
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))

        let pendingFragment = "pending"
        let pendingContainsDescriptor = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title.contains(pendingFragment) })
            })
        let pendingContainsMatches = try context.fetch(pendingContainsDescriptor)
        XCTAssertEqual(pendingContainsMatches.map(\.persistentModelID), [baseOwner.persistentModelID])
        XCTAssertEqual(try context.fetchCount(pendingContainsDescriptor), 1)
        XCTAssertEqual(
            try context.fetchIdentifiers(pendingContainsDescriptor), pendingContainsMatches.map(\.persistentModelID))

        let disjunction = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title == pendingTitle })
                    || base.items.contains(where: { item in item.title == "other" })
            })
        XCTAssertEqual(try context.fetch(disjunction).count, 2)

        let negated = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                !base.items.contains(where: { item in item.title == "absent" })
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(negated).count, 3)

        let optionalTitlePredicate = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title == "" || item.title == "other" })
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(optionalTitlePredicate).count, 2)

        let pendingItem = InheritanceRelationshipItemFixture(title: "pending-owner")
        context.insert(pendingItem)
        context.insert(InheritanceRelationshipBaseFixture(items: [pendingItem]))
        let pendingOwnerDescriptor = FetchDescriptor<InheritanceRelationshipBaseFixture>(
            predicate: #Predicate { base in
                base.items.contains(where: { item in item.title == "pending-owner" })
            })
        XCTAssertEqual(try context.fetch(pendingOwnerDescriptor).count, 1)

    }

    @MainActor
    func testPredicateTraversesInverseManyToManyCollection() throws {
        let container = try ModelContainer(
            for: InheritedManyToManyTagFixture.self,
            InheritedManyToManyChildFixture.self,
            configurations: .sqliteMemory("inverse-many-to-many-predicate"))
        let context = container.mainContext
        let matchingTag = InheritedManyToManyTagFixture(title: "selected")
        let otherTag = InheritedManyToManyTagFixture(title: "other")
        let selectedOwner = InheritedManyToManyChildFixture(name: "selected-owner", tags: [matchingTag])
        let otherOwner = InheritedManyToManyChildFixture(name: "other-owner", tags: [otherTag])
        context.insert(matchingTag)
        context.insert(otherTag)
        context.insert(selectedOwner)
        context.insert(otherOwner)
        try context.save()

        let selectedName = "selected-owner"
        let storedDescriptor = FetchDescriptor<InheritedManyToManyTagFixture>(
            predicate: #Predicate { tag in
                tag.owners.contains(where: { owner in owner.name == selectedName })
            },
            includePendingChanges: false)
        let storedMatches = try context.fetch(storedDescriptor)
        XCTAssertEqual(storedMatches.map(\.title), ["selected"])
        XCTAssertEqual(try context.fetchCount(storedDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(storedDescriptor), storedMatches.map(\.persistentModelID))

        selectedOwner.name = "renamed-owner"
        let renamedName = "renamed-owner"
        let renamedDescriptor = FetchDescriptor<InheritedManyToManyTagFixture>(
            predicate: #Predicate { tag in
                tag.owners.contains(where: { owner in owner.name == renamedName })
            })
        let renamedMatches = try context.fetch(renamedDescriptor)
        XCTAssertEqual(renamedMatches.map(\.title), ["selected"])
        XCTAssertEqual(try context.fetchCount(renamedDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(renamedDescriptor), renamedMatches.map(\.persistentModelID))

        let pendingOwner = InheritedManyToManyChildFixture(name: "pending-owner", tags: [matchingTag])
        context.insert(pendingOwner)
        let pendingName = "pending-owner"
        let pendingDescriptor = FetchDescriptor<InheritedManyToManyTagFixture>(
            predicate: #Predicate { tag in
                tag.owners.contains(where: { owner in owner.name == pendingName })
            })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(pendingMatches.map(\.title), ["selected"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))

        matchingTag.owners = [otherOwner]
        XCTAssertEqual(matchingTag.owners.map(\.name), ["other-owner"])
        let removedName = "renamed-owner"
        let removedDescriptor = FetchDescriptor<InheritedManyToManyTagFixture>(
            predicate: #Predicate { tag in
                tag.owners.contains(where: { owner in owner.name == removedName })
            })
        XCTAssertTrue(try context.fetch(removedDescriptor).isEmpty)
        XCTAssertEqual(try context.fetchCount(removedDescriptor), 0)
        XCTAssertTrue(try context.fetchIdentifiers(removedDescriptor).isEmpty)
    }

    @MainActor
    func testPredicateTraversesInverseOneToManyCollection() throws {
        let container = try ModelContainer(
            for: InheritedOneToManyTargetFixture.self,
            InheritedOneToManyChildFixture.self,
            InheritedOneToManyGrandchildFixture.self,
            configurations: .sqliteMemory("inverse-one-to-many-predicate"))
        let context = container.mainContext
        let selectedTarget = InheritedOneToManyTargetFixture(title: "selected")
        let otherTarget = InheritedOneToManyTargetFixture(title: "other")
        context.insert(selectedTarget)
        context.insert(otherTarget)
        context.insert(InheritedOneToManyChildFixture(name: "selected-child", target: selectedTarget))
        context.insert(InheritedOneToManyGrandchildFixture(name: "other-child", target: otherTarget, rank: 4))
        try context.save()

        let selectedName = "selected-child"
        let descriptor = FetchDescriptor<InheritedOneToManyTargetFixture>(
            predicate: #Predicate { target in
                target.children.contains(where: { child in child.name == selectedName })
            },
            includePendingChanges: false)
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.map(\.title), ["selected"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor), matches.map(\.persistentModelID))

        let selectedChild = try XCTUnwrap(
            try context.fetch(FetchDescriptor<InheritedOneToManyChildFixture>())
                .first(where: { $0.name == "selected-child" }))
        selectedChild.name = "pending-child"
        let pendingName = "pending-child"
        let pendingDescriptor = FetchDescriptor<InheritedOneToManyTargetFixture>(
            predicate: #Predicate { target in
                target.children.contains(where: { child in child.name == pendingName })
            })
        let pendingMatches = try context.fetch(pendingDescriptor)
        XCTAssertEqual(pendingMatches.map(\.title), ["selected"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingDescriptor), pendingMatches.map(\.persistentModelID))

        let insertedChild = InheritedOneToManyChildFixture(name: "inserted-child", target: selectedTarget)
        context.insert(insertedChild)
        let insertedName = "inserted-child"
        let insertedDescriptor = FetchDescriptor<InheritedOneToManyTargetFixture>(
            predicate: #Predicate { target in
                target.children.contains(where: { child in child.name == insertedName })
            })
        let insertedMatches = try context.fetch(insertedDescriptor)
        XCTAssertEqual(insertedMatches.map(\.title), ["selected"])
        XCTAssertEqual(try context.fetchCount(insertedDescriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(insertedDescriptor), insertedMatches.map(\.persistentModelID))
    }

    @MainActor
    func testPredicateMatchesInheritedNoInverseToManyRelationship() throws {
        let container = try ModelContainer(
            for: InheritedToManyChildFixture.self,
            InheritedToOneTargetFixture.self,
            configurations: .sqliteMemory("to-many-hierarchy-destination-predicate"))
        let context = container.mainContext
        let target = InheritedToOneTargetFixture(title: "selected")
        let otherTarget = InheritedToOneTargetFixture(title: "other")
        context.insert(target)
        context.insert(otherTarget)
        context.insert(InheritedToManyChildFixture(name: "selected-owner", targets: [target]))
        context.insert(InheritedToManySiblingFixture(name: "sibling-owner", targets: [otherTarget]))
        try context.save()

        let selectedTitle = target.title
        let childDescriptor = FetchDescriptor<InheritedToManyChildFixture>(
            predicate: #Predicate { owner in
                owner.targets.contains(where: { target in target.title == selectedTitle })
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(childDescriptor).map(\.name), ["selected-owner"])
    }

    @MainActor
    func testPredicateIncludesGrandchildInToManyDestinationSubtree() throws {
        let container = try ModelContainer(
            for: ToManyHierarchyOwnerFixture.self,
            ToManyHierarchyTargetChildFixture.self,
            ToManyHierarchyTargetGrandchildFixture.self,
            ToManyHierarchyTargetSiblingFixture.self,
            configurations: .sqliteMemory("to-many-destination-subtree-predicate"))
        let context = container.mainContext
        let child = ToManyHierarchyTargetChildFixture(title: "selected", code: "child")
        let grandchild = ToManyHierarchyTargetGrandchildFixture(title: "selected", code: "grandchild", rank: 2)
        let sibling = ToManyHierarchyTargetSiblingFixture(title: "selected", label: "sibling")
        context.insert(child)
        context.insert(grandchild)
        context.insert(sibling)
        context.insert(ToManyHierarchyOwnerFixture(targets: [child, grandchild]))
        try context.save()

        let selectedTitle = "selected"
        let descriptor = FetchDescriptor<ToManyHierarchyOwnerFixture>(
            predicate: #Predicate { owner in
                owner.targets.contains(where: { target in target.title == selectedTitle })
            },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetchCount(descriptor), 1)
        XCTAssertEqual(try context.fetchIdentifiers(descriptor).count, 1)
    }

    @MainActor
    func testRequiredInheritedToOneRelationshipResolvesAfterEndpointInsert() throws {
        let container = try ModelContainer(
            for: [RequiredInheritedToOneChildFixture.self, InheritedToOneTargetFixture.self],
            configurations: [.sqliteMemory("inherited-required-to-one")])
        let context = container.mainContext
        let target = InheritedToOneTargetFixture(title: "required")
        let child = RequiredInheritedToOneChildFixture(target: target, rank: 8)
        context.insert(target)
        context.insert(child)

        try context.save()

        let row = try container.store?.read {
            try $0.rows(
                "SELECT ZREQUIREDINHERITEDTOONEBASEFIXTURE_TARGET FROM ZREQUIREDINHERITEDTOONEBASEFIXTURE",
                arguments: [])
        }
        XCTAssertEqual(row, [[.int(1)]])
    }

    @MainActor
    func testRequiredInheritedToOneRelationshipRejectsDeletedEndpoint() throws {
        let container = try ModelContainer(
            for: [RequiredInheritedToOneChildFixture.self, InheritedToOneTargetFixture.self],
            configurations: [.sqliteMemory("inherited-required-to-one-delete")])
        let context = container.mainContext
        let target = InheritedToOneTargetFixture(title: "required")
        let child = RequiredInheritedToOneChildFixture(target: target, rank: 8)
        context.insert(target)
        context.insert(child)
        try context.save()
        XCTAssertTrue(target.modelContext === context)

        context.delete(target)

        XCTAssertFalse(target.isDeleted)
        XCTAssertTrue(target.modelContext === context)
        XCTAssertFalse(context.hasChanges)
        let rows = try container.store?.read {
            try $0.rows(
                "SELECT Z_PK FROM ZREQUIREDINHERITEDTOONEBASEFIXTURE WHERE Z_PK = ?",
                arguments: [.int(1)])
        }
        XCTAssertEqual(rows, [[.int(1)]])
    }

    @MainActor
    func testInheritedToOneInverseCollectionRoundTrips() throws {
        let container = try ModelContainer(
            for: [
                InheritedOneToManyChildFixture.self,
                InheritedOneToManyGrandchildFixture.self,
                InheritedOneToManySiblingFixture.self,
                InheritedOneToManyTargetFixture.self,
            ],
            configurations: [.sqliteMemory("inherited-to-one-inverse")])
        XCTAssertEqual(
            container.schema.entity(forName: "InheritedOneToManyTargetFixture")?.relationships
                .first(where: { $0.name == "children" })?.inverse,
            "target")
        let writer = container.mainContext
        let target = InheritedOneToManyTargetFixture(title: "target")
        let child = InheritedOneToManyChildFixture(name: "child", target: target)
        let grandchild = InheritedOneToManyGrandchildFixture(name: "grandchild", target: target, rank: 7)
        writer.insert(target)
        writer.insert(child)
        writer.insert(grandchild)
        writer.insert(InheritedOneToManySiblingFixture(name: "sibling", label: "unrelated"))
        try writer.save()

        let reader = container.makeContext()
        let fetchedTarget = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<InheritedOneToManyTargetFixture>(
                    relationshipKeyPathsForPrefetching: [\InheritedOneToManyTargetFixture.children])
            ).first)
        XCTAssertEqual(fetchedTarget.children.map(\.name), ["child", "grandchild"])
        XCTAssertTrue(fetchedTarget.children.allSatisfy { $0.target === fetchedTarget })
        XCTAssertEqual((fetchedTarget.children.last as? InheritedOneToManyGrandchildFixture)?.rank, 7)
        let readerChild = try XCTUnwrap(fetchedTarget.children.first)

        fetchedTarget.children = []
        XCTAssertTrue(fetchedTarget.children.isEmpty)
        XCTAssertNil(readerChild.target)
        try reader.save()
        let cleared = try container.store?.read {
            try $0.rows(
                "SELECT ZINHERITEDONETOMANYCHILDFIXTURE_TARGET FROM ZINHERITEDONETOMANYBASEFIXTURE "
                    + "ORDER BY Z_PK",
                arguments: [])
        }
        XCTAssertEqual(cleared, [[.null], [.null], [.null]])
    }

    @MainActor
    func testInheritedToManyOwnerUsesDeclaringEntityJoinTables() throws {
        let container = try ModelContainer(
            for: [
                InheritedToManyChildFixture.self,
                InheritedToManyGrandchildFixture.self,
                InheritedToManySiblingFixture.self,
                InheritedToOneTargetFixture.self,
            ],
            configurations: [.sqliteMemory("inherited-to-many-owner")])
        let writer = container.mainContext
        let first = InheritedToOneTargetFixture(title: "first")
        let second = InheritedToOneTargetFixture(title: "second")
        let siblingOnly = InheritedToOneTargetFixture(title: "sibling")
        writer.insert(first)
        writer.insert(second)
        writer.insert(siblingOnly)
        writer.insert(InheritedToManyChildFixture(name: "child", targets: [second, first]))
        writer.insert(InheritedToManyGrandchildFixture(name: "grandchild", targets: [first], rank: 9))
        writer.insert(InheritedToManySiblingFixture(name: "sibling", targets: [siblingOnly]))
        try writer.save()

        let tables = try XCTUnwrap(container.store).read {
            try $0.rows(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z_%' ORDER BY name",
                arguments: [])
        }
        XCTAssertTrue(tables.contains([.text("Z_INHERITEDTOMANYCHILDFIXTURE_TARGETS_INHERITEDTOONETARGETFIXTURE")]))
        XCTAssertTrue(tables.contains([.text("Z_INHERITEDTOMANYSIBLINGFIXTURE_TARGETS_INHERITEDTOONETARGETFIXTURE")]))

        let reader = container.makeContext()
        let child = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<InheritedToManyChildFixture>(
                    relationshipKeyPathsForPrefetching: [\InheritedToManyChildFixture.targets])
            ).first)
        let grandchild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<InheritedToManyGrandchildFixture>(
                    relationshipKeyPathsForPrefetching: [\InheritedToManyGrandchildFixture.targets])
            ).first)
        let sibling = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<InheritedToManySiblingFixture>(
                    relationshipKeyPathsForPrefetching: [\InheritedToManySiblingFixture.targets])
            ).first)
        XCTAssertEqual(child.targets.map(\.title), ["first", "second"])
        XCTAssertEqual(grandchild.targets.map(\.title), ["first"])
        XCTAssertEqual(sibling.targets.map(\.title), ["sibling"])

        let readerSecond = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritedToOneTargetFixture>())
                .first(where: { $0.title == "second" }))
        child.targets = [readerSecond]
        XCTAssertTrue(child.hasChanges)
        XCTAssertEqual(reader.state.relationshipMutations.count, 1)
        XCTAssertEqual(child.targets.map(\.title), ["second"])
        try reader.save()
        XCTAssertEqual(child.targets.map(\.title), ["second"])
    }

    @MainActor
    func testInheritedToManyJoinRowsCleanUpOnOwnerAndDestinationDelete() throws {
        let container = try ModelContainer(
            for: [
                InheritedToManyChildFixture.self,
                InheritedToManyGrandchildFixture.self,
                InheritedToManySiblingFixture.self,
                InheritedToOneTargetFixture.self,
            ],
            configurations: [.sqliteMemory("inherited-to-many-delete-cleanup")])
        let context = container.mainContext
        let target = InheritedToOneTargetFixture(title: "target")
        let child = InheritedToManyChildFixture(name: "child", targets: [target])
        let siblingTarget = InheritedToOneTargetFixture(title: "sibling")
        let sibling = InheritedToManySiblingFixture(name: "sibling", targets: [siblingTarget])
        context.insert(target)
        context.insert(siblingTarget)
        context.insert(child)
        context.insert(sibling)
        try context.save()

        context.delete(target)
        try context.save()
        let childTable = "Z_INHERITEDTOMANYCHILDFIXTURE_TARGETS_INHERITEDTOONETARGETFIXTURE"
        let siblingTable = "Z_INHERITEDTOMANYSIBLINGFIXTURE_TARGETS_INHERITEDTOONETARGETFIXTURE"
        let remaining = try container.store?.read {
            try $0.rows("SELECT Z_A, Z_B FROM \(childTable)", arguments: [])
        }
        XCTAssertTrue(remaining?.isEmpty == true)
        let siblingRows = try container.store?.read {
            try $0.rows("SELECT Z_A, Z_B FROM \(siblingTable)", arguments: [])
        }
        XCTAssertEqual(siblingRows?.count, 1)

        context.delete(sibling)
        try context.save()
        let deletedOwnerRows = try container.store?.read {
            try $0.rows("SELECT Z_A, Z_B FROM \(siblingTable)", arguments: [])
        }
        XCTAssertTrue(deletedOwnerRows?.isEmpty == true)
    }

    @MainActor
    func testInheritedToManyOwnerCascadeAndDenyRules() throws {
        let cascadeContainer = try ModelContainer(
            for: [InheritedCascadeJoinChildFixture.self, InheritedToOneTargetFixture.self],
            configurations: [.sqliteMemory("inherited-to-many-cascade")])
        let cascadeContext = cascadeContainer.mainContext
        let cascadedTarget = InheritedToOneTargetFixture(title: "cascade")
        cascadeContext.insert(cascadedTarget)
        let cascadeOwner = InheritedCascadeJoinChildFixture(name: "owner", targets: [cascadedTarget])
        cascadeContext.insert(cascadeOwner)
        try cascadeContext.save()
        cascadeContext.delete(cascadeOwner)
        try cascadeContext.save()
        XCTAssertNil(try cascadeContext.model(for: cascadedTarget.persistentModelID) as InheritedToOneTargetFixture?)

        let denyContainer = try ModelContainer(
            for: [InheritedDenyJoinChildFixture.self, InheritedToOneTargetFixture.self],
            configurations: [.sqliteMemory("inherited-to-many-deny")])
        let denyContext = denyContainer.mainContext
        let deniedTarget = InheritedToOneTargetFixture(title: "deny")
        denyContext.insert(deniedTarget)
        let denyOwner = InheritedDenyJoinChildFixture(name: "owner", targets: [deniedTarget])
        denyContext.insert(denyOwner)
        try denyContext.save()
        let denyRootRows = try denyContainer.store?.read {
            try $0.rows("SELECT Z_PK, Z_ENT FROM ZINHERITEDDENYJOINBASEFIXTURE", arguments: [])
        }
        let denyJoinRows = try denyContainer.store?.read {
            try $0.rows(
                "SELECT Z_A, Z_B FROM Z_INHERITEDDENYJOINCHILDFIXTURE_TARGETS_INHERITEDTOONETARGETFIXTURE",
                arguments: [])
        }
        XCTAssertEqual(denyRootRows?.count, 1)
        XCTAssertEqual(denyJoinRows?.count, 1)
        let denyAdapter = try XCTUnwrap(
            denyContainer.relationshipAdapterTable[ObjectIdentifier(InheritedDenyJoinChildFixture.self)]?
                .first(where: { $0.name == "targets" }))
        XCTAssertEqual(denyAdapter.metadata?.deleteRule, .deny)
        XCTAssertEqual(denyAdapter.read(denyOwner)?.count, 1)
        denyContext.delete(denyOwner)
        XCTAssertFalse(denyOwner.isDeleted)
        XCTAssertFalse(denyContext.hasChanges)
        XCTAssertEqual(try denyContext.fetch(FetchDescriptor<InheritedDenyJoinBaseFixture>()).count, 1)
    }

    @MainActor
    func testInheritedManyToManyInverseJoinTableFiltersSiblings() throws {
        let container = try ModelContainer(
            for: [
                InheritedManyToManyChildFixture.self,
                InheritedManyToManyGrandchildFixture.self,
                InheritedManyToManyTagFixture.self,
            ],
            configurations: [.sqliteMemory("inherited-many-to-many-inverse")])
        let tagsMetadata = try XCTUnwrap(
            InheritedManyToManyChildFixture.schemaMetadata().first(where: { $0.name == "tags" }))
        let tagsRelationship = try XCTUnwrap(tagsMetadata.metadata?.base as? Schema.Relationship)
        XCTAssertEqual(tagsRelationship.inverse, "owners")
        XCTAssertEqual(
            container.schema.entity(forName: "InheritedManyToManyTagFixture")?.relationships
                .first(where: { $0.name == "owners" })?.inverse,
            "tags")
        let writer = container.mainContext
        let first = InheritedManyToManyTagFixture(title: "first")
        let second = InheritedManyToManyTagFixture(title: "second")
        writer.insert(first)
        writer.insert(second)
        writer.insert(InheritedManyToManyChildFixture(name: "child", tags: [first]))
        writer.insert(InheritedManyToManyGrandchildFixture(name: "grandchild", tags: [second], rank: 5))
        try writer.save()

        let joinRows = try container.store?.read {
            try $0.rows(
                "SELECT Z_A, Z_B FROM Z_INHERITEDMANYTOMANYCHILDFIXTURE_TAGS_INHERITEDMANYTOMANYTAGFIXTURE_OWNERS "
                    + "ORDER BY Z_A",
                arguments: [])
        }
        XCTAssertEqual(joinRows, [[.int(1), .int(1)], [.int(2), .int(2)]])

        let reader = container.makeContext()
        let firstTag = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritedManyToManyTagFixture>()).first)
        XCTAssertEqual(firstTag.owners.map(\.name), ["child"])
        let secondTag = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritedManyToManyTagFixture>())
                .first(where: { $0.title == "second" }))
        XCTAssertTrue(secondTag.owners.first is InheritedManyToManyGrandchildFixture)
        let firstOwners = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<InheritedManyToManyTagFixture>(
                    propertiesToFetch: nil,
                    relationshipKeyPathsForPrefetching: [\InheritedManyToManyTagFixture.owners])
            )
            .first(where: { $0.title == "first" }))
        XCTAssertEqual(firstOwners.owners.map(\.name), ["child"])
        XCTAssertNil(firstTag.owners.first(where: { $0.name == "sibling" }))

        firstOwners.owners = []
        XCTAssertTrue(firstOwners.owners.isEmpty)
        XCTAssertTrue(firstOwners.hasChanges)
        try reader.save()
        let remainingEdges = try container.store?.read {
            try $0.rows(
                "SELECT Z_A, Z_B FROM Z_INHERITEDMANYTOMANYCHILDFIXTURE_TAGS_INHERITEDMANYTOMANYTAGFIXTURE_OWNERS "
                    + "ORDER BY Z_A",
                arguments: [])
        }
        XCTAssertEqual(remainingEdges, [[.int(2), .int(2)]])

        let grandchild = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritedManyToManyGrandchildFixture>()).first)
        XCTAssertEqual(grandchild.tags.map(\.title), ["second"])
        reader.delete(secondTag)
        try reader.save()
        XCTAssertTrue(grandchild.tags.isEmpty)
        let afterTargetDelete = try container.store?.read {
            try $0.rows(
                "SELECT Z_A, Z_B FROM Z_INHERITEDMANYTOMANYCHILDFIXTURE_TAGS_INHERITEDMANYTOMANYTAGFIXTURE_OWNERS",
                arguments: [])
        }
        XCTAssertTrue(afterTargetDelete?.isEmpty == true)
        reader.delete(grandchild)
        try reader.save()
        let afterGrandchildDelete = try container.store?.read {
            try $0.rows(
                "SELECT Z_A, Z_B FROM Z_INHERITEDMANYTOMANYCHILDFIXTURE_TAGS_INHERITEDMANYTOMANYTAGFIXTURE_OWNERS",
                arguments: [])
        }
        XCTAssertTrue(afterGrandchildDelete?.isEmpty == true)
    }

    @MainActor
    func testHierarchyToHierarchyManyToManyFiltersBothEndpoints() throws {
        let container = try ModelContainer(
            for: [
                MatrixLeftChildFixture.self,
                MatrixLeftGrandchildFixture.self,
                MatrixLeftSiblingFixture.self,
                MatrixRightChildFixture.self,
                MatrixRightGrandchildFixture.self,
                MatrixRightSiblingFixture.self,
            ],
            configurations: [.sqliteMemory("hierarchy-to-hierarchy-many-to-many")])
        let writer = container.mainContext
        let rightChild = MatrixRightChildFixture(name: "right-child")
        let rightGrandchild = MatrixRightGrandchildFixture(name: "right-grandchild", rank: 4)
        let rightSibling = MatrixRightSiblingFixture(name: "right-sibling", label: "unrelated")
        let leftChild = MatrixLeftChildFixture(name: "left-child", rightMembers: [rightGrandchild])
        let leftGrandchild = MatrixLeftGrandchildFixture(name: "left-grandchild", rightMembers: [rightChild], rank: 3)
        let leftSibling = MatrixLeftSiblingFixture(name: "left-sibling", label: "unrelated")
        writer.insert(rightChild)
        writer.insert(rightGrandchild)
        writer.insert(rightSibling)
        writer.insert(leftChild)
        writer.insert(leftGrandchild)
        writer.insert(leftSibling)
        try writer.save()

        let reader = container.makeContext()
        let readLeftChild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<MatrixLeftChildFixture>(
                    relationshipKeyPathsForPrefetching: [\MatrixLeftChildFixture.rightMembers])
            ).first)
        let readLeftGrandchild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<MatrixLeftGrandchildFixture>(
                    relationshipKeyPathsForPrefetching: [\MatrixLeftGrandchildFixture.rightMembers])
            ).first)
        let readRightChild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<MatrixRightChildFixture>(
                    relationshipKeyPathsForPrefetching: [\MatrixRightChildFixture.leftMembers])
            ).first)
        let readRightGrandchild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<MatrixRightGrandchildFixture>(
                    relationshipKeyPathsForPrefetching: [\MatrixRightGrandchildFixture.leftMembers])
            ).first)
        let readLeftSibling = try XCTUnwrap(reader.fetch(FetchDescriptor<MatrixLeftSiblingFixture>()).first)
        let readRightSibling = try XCTUnwrap(reader.fetch(FetchDescriptor<MatrixRightSiblingFixture>()).first)

        XCTAssertTrue(readLeftChild.rightMembers.first is MatrixRightGrandchildFixture)
        XCTAssertEqual(readLeftGrandchild.rightMembers.map(\.name), ["right-child"])
        XCTAssertTrue(readRightChild.leftMembers.first is MatrixLeftGrandchildFixture)
        XCTAssertEqual(readRightGrandchild.leftMembers.map(\.name), ["left-child"])
        XCTAssertTrue(readLeftSibling.name == "left-sibling")
        XCTAssertTrue(readRightSibling.name == "right-sibling")

        readRightChild.leftMembers = []
        try reader.save()
        XCTAssertTrue(readLeftGrandchild.rightMembers.isEmpty)

        reader.delete(readLeftChild)
        try reader.save()
        XCTAssertTrue(readRightGrandchild.leftMembers.isEmpty)
    }

    @MainActor
    func testSelfReferentialHierarchyManyToManyFiltersConcreteEndpoints() throws {
        let container = try ModelContainer(
            for: [SelfLinkChildFixture.self, SelfLinkGrandchildFixture.self],
            configurations: [.sqliteMemory("self-hierarchy-many-to-many")])
        let writer = container.mainContext
        let child = SelfLinkChildFixture(name: "child")
        let grandchild = SelfLinkGrandchildFixture(name: "grandchild", rank: 2)
        writer.insert(child)
        writer.insert(grandchild)
        try writer.save()

        let reader = container.makeContext()
        let fetchedChild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<SelfLinkChildFixture>(
                    relationshipKeyPathsForPrefetching: [\SelfLinkChildFixture.children])
            ).first)
        let fetchedGrandchild = try XCTUnwrap(
            reader.fetch(
                FetchDescriptor<SelfLinkGrandchildFixture>(
                    relationshipKeyPathsForPrefetching: [\SelfLinkGrandchildFixture.parents])
            ).first)
        fetchedChild.children = [fetchedGrandchild]
        try reader.save()

        let lazyReader = container.makeContext()
        let lazyGrandchild = try XCTUnwrap(
            lazyReader.fetch(FetchDescriptor<SelfLinkGrandchildFixture>()).first)
        XCTAssertEqual(lazyGrandchild.parents.map(\.name), ["child"])
        XCTAssertTrue(lazyGrandchild.parents.first is SelfLinkChildFixture)
    }

    @MainActor
    func testDeletingInverseCollectionOwnerNullifiesInheritedToOne() throws {
        let container = try ModelContainer(
            for: [
                InheritedOneToManyChildFixture.self,
                InheritedOneToManyGrandchildFixture.self,
                InheritedOneToManyTargetFixture.self,
            ],
            configurations: [.sqliteMemory("inherited-to-one-inverse-delete")])
        let writer = container.mainContext
        let target = InheritedOneToManyTargetFixture(title: "target")
        writer.insert(target)
        writer.insert(InheritedOneToManyChildFixture(name: "child", target: target))
        try writer.save()

        let reader = container.makeContext()
        let targetToDelete = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritedOneToManyTargetFixture>()).first)
        reader.delete(targetToDelete)
        try reader.save()

        let rows = try container.store?.read {
            try $0.rows(
                "SELECT ZINHERITEDONETOMANYCHILDFIXTURE_TARGET FROM ZINHERITEDONETOMANYBASEFIXTURE",
                arguments: [])
        }
        XCTAssertEqual(rows, [[.null]])
        let child = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritedOneToManyBaseFixture>()).first)
        XCTAssertNil((child as? InheritedOneToManyChildFixture)?.target)
    }

    @MainActor
    func testInheritedToOneInverseDeleteRulesCascadeAndDeny() throws {
        let cascadeContainer = try ModelContainer(
            for: [InheritedCascadeChildFixture.self, InheritedCascadeTargetFixture.self],
            configurations: [.sqliteMemory("inherited-to-one-cascade")])
        let cascadeContext = cascadeContainer.mainContext
        let cascadeTarget = InheritedCascadeTargetFixture(title: "cascade")
        cascadeContext.insert(cascadeTarget)
        cascadeContext.insert(InheritedCascadeChildFixture(name: "child", target: cascadeTarget))
        try cascadeContext.save()
        let cascadeReader = cascadeContainer.makeContext()
        let persistedCascadeTarget = try XCTUnwrap(
            cascadeReader.fetch(FetchDescriptor<InheritedCascadeTargetFixture>()).first)
        cascadeReader.delete(persistedCascadeTarget)
        try cascadeReader.save()
        XCTAssertTrue(try cascadeReader.fetch(FetchDescriptor<InheritedCascadeBaseFixture>()).isEmpty)

        let denyContainer = try ModelContainer(
            for: [InheritedDenyChildFixture.self, InheritedDenyTargetFixture.self],
            configurations: [.sqliteMemory("inherited-to-one-deny")])
        let denyContext = denyContainer.mainContext
        let denyTarget = InheritedDenyTargetFixture(title: "deny")
        denyContext.insert(denyTarget)
        denyContext.insert(InheritedDenyChildFixture(name: "child", target: denyTarget))
        try denyContext.save()
        let denyReader = denyContainer.makeContext()
        let persistedDenyTarget = try XCTUnwrap(denyReader.fetch(FetchDescriptor<InheritedDenyTargetFixture>()).first)
        denyReader.delete(persistedDenyTarget)
        XCTAssertFalse(persistedDenyTarget.isDeleted)
        XCTAssertFalse(denyReader.hasChanges)
        XCTAssertEqual(try denyReader.fetch(FetchDescriptor<InheritedDenyBaseFixture>()).count, 1)
    }

    func testRelationshipInverseDestinationAcceptsLogicalOwnerAncestors() {
        let types: [any PersistentModel.Type] = [
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
        ]
        XCTAssertTrue(
            ModelContainer.relationshipDestination(
                "InheritanceMacroBaseFixture", matchesLogicalOwner: "InheritanceMacroChildFixture", among: types))
        XCTAssertTrue(
            ModelContainer.relationshipDestination(
                "InheritanceMacroChildFixture", matchesLogicalOwner: "InheritanceMacroChildFixture", among: types))
        XCTAssertFalse(
            ModelContainer.relationshipDestination(
                "InheritanceMacroGrandchildFixture", matchesLogicalOwner: "InheritanceMacroBaseFixture", among: types))
    }

    @MainActor
    func testExplicitInverseMayBeDeclaredOnDestinationSubtype() throws {
        let container = try ModelContainer(
            for: [HierarchyOwnerChildFixture.self, HierarchyTargetGrandchildFixture.self],
            configurations: [.sqliteMemory("inverse-on-destination-subtype")])

        let ownerRelationship = try XCTUnwrap(
            container.schema.entity(forName: "HierarchyOwnerChildFixture")?.relationships
                .first(where: { $0.name == "target" }))
        let targetRelationship = try XCTUnwrap(
            container.schema.entity(forName: "HierarchyTargetChildFixture")?.relationships
                .first(where: { $0.name == "owners" }))

        XCTAssertEqual(ownerRelationship.destination, "HierarchyTargetBaseFixture")
        XCTAssertNil(
            container.schema.entity(forName: "HierarchyTargetBaseFixture")?.relationships
                .first(where: { $0.name == "owners" }))
        XCTAssertEqual(ownerRelationship.inverse, "owners")
        XCTAssertEqual(targetRelationship.inverse, "target")
        XCTAssertEqual(
            container.schema.relationshipStorageMapping(
                modelEntityName: "HierarchyTargetGrandchildFixture", relationshipName: "owners")?
                .declaringEntityName,
            "HierarchyTargetChildFixture")
    }

    @MainActor
    func testSubtypeInverseDenyRulePreventsConcreteTargetDeletion() throws {
        let container = try ModelContainer(
            for: [
                HierarchySubtypeOwnerChildFixture.self,
                DeniedHierarchyTargetChildFixture.self,
            ],
            configurations: [.sqliteMemory("subtype-inverse-deny")])
        let context = container.mainContext
        let target = DeniedHierarchyTargetChildFixture(name: "target", detail: "deny")
        context.insert(target)
        let owner = HierarchySubtypeOwnerChildFixture(name: "owner", target: target)
        context.insert(owner)
        try context.save()
        let deleteContext = container.makeContext()
        let targetForDelete = try XCTUnwrap(
            deleteContext.fetch(FetchDescriptor<DeniedHierarchyTargetBaseFixture>()).first
                as? DeniedHierarchyTargetChildFixture)
        deleteContext.delete(targetForDelete)

        XCTAssertFalse(targetForDelete.isDeleted)
        XCTAssertFalse(deleteContext.hasChanges)
        XCTAssertEqual(try deleteContext.fetch(FetchDescriptor<HierarchySubtypeOwnerBaseFixture>()).count, 1)

        let ownerForDelete = try XCTUnwrap(
            deleteContext.fetch(FetchDescriptor<HierarchySubtypeOwnerChildFixture>()).first)
        deleteContext.delete(ownerForDelete)
        try deleteContext.save()
        XCTAssertEqual(try deleteContext.fetch(FetchDescriptor<DeniedHierarchyTargetBaseFixture>()).count, 1)
        XCTAssertTrue(try deleteContext.fetch(FetchDescriptor<HierarchySubtypeOwnerBaseFixture>()).isEmpty)
    }

    @MainActor
    func testSubtypeInverseCascadeDeletesOwnerWhenTargetIsDeleted() throws {
        let container = try ModelContainer(
            for: [CascadeHierarchyInverseOwnerChildFixture.self, CascadeHierarchyTargetChildFixture.self],
            configurations: [.sqliteMemory("subtype-inverse-cascade")])
        let context = container.mainContext
        let target = CascadeHierarchyTargetChildFixture(name: "target", detail: "cascade")
        context.insert(target)
        context.insert(CascadeHierarchyInverseOwnerChildFixture(name: "owner", target: target))
        try context.save()

        let deleteContext = container.makeContext()
        let targetForDelete = try XCTUnwrap(
            deleteContext.fetch(FetchDescriptor<CascadeHierarchyTargetBaseFixture>()).first
                as? CascadeHierarchyTargetChildFixture)
        let cascadeJoinOrFK = try container.store?.read {
            try $0.rows(
                "SELECT ZCASCADEHIERARCHYINVERSEOWNERCHILDFIXTURE_TARGET FROM ZCASCADEHIERARCHYSOURCEBASEFIXTURE",
                arguments: [])
        }
        XCTAssertEqual(cascadeJoinOrFK, [[.int(1)]])
        let inverseMetadata = try XCTUnwrap(
            container.schema.relationship(named: "owners", onOrBelow: "CascadeHierarchyTargetBaseFixture"))
        XCTAssertEqual(inverseMetadata.deleteRule, .cascade)
        XCTAssertEqual(targetForDelete.owners.map(\.name), ["owner"])
        deleteContext.delete(targetForDelete)
        try deleteContext.save()

        XCTAssertTrue(try deleteContext.fetch(FetchDescriptor<CascadeHierarchySourceBaseFixture>()).isEmpty)
        XCTAssertTrue(try deleteContext.fetch(FetchDescriptor<CascadeHierarchyTargetBaseFixture>()).isEmpty)
    }

    @MainActor
    func testContainerAutomaticallyIncludesModelAncestors() throws {
        let implicit = try ModelContainer(
            for: [InheritanceRelationshipChildFixture.self, InheritanceRelationshipItemFixture.self])
        let explicit = try ModelContainer(
            for: [
                InheritanceRelationshipBaseFixture.self,
                InheritanceRelationshipChildFixture.self,
                InheritanceRelationshipItemFixture.self,
            ])
        let reversed = try ModelContainer(
            for: [
                InheritanceRelationshipItemFixture.self,
                InheritanceRelationshipChildFixture.self,
                InheritanceRelationshipBaseFixture.self,
            ])

        XCTAssertEqual(implicit.schema.entities, explicit.schema.entities)
        XCTAssertEqual(reversed.schema.entityIDsByName, explicit.schema.entityIDsByName)
        XCTAssertNotNil(implicit.schema.entity(forName: "InheritanceRelationshipBaseFixture"))
        XCTAssertEqual(
            implicit.schema.relationshipStorageMapping(
                modelEntityName: "InheritanceRelationshipChildFixture", relationshipName: "items")?
                .declaringEntityName,
            "InheritanceRelationshipBaseFixture")
    }

    @MainActor
    func testSQLiteContainerAutomaticallyIncludesModelAncestors() throws {
        let implicit = try ModelContainer(
            for: [InheritanceMacroChildFixture.self],
            configurations: [.sqliteMemory("inheritance-implicit-ancestor")])
        let explicit = try ModelContainer(
            for: [InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self],
            configurations: [.sqliteMemory("inheritance-explicit-ancestor")])

        XCTAssertEqual(implicit.schema.entities, explicit.schema.entities)
        let tables = try XCTUnwrap(implicit.store).read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z%'", arguments: [])
        }
        XCTAssertEqual(tables, [[.text("Z_PRIMARYKEY")], [.text("ZINHERITANCEMACROBASEFIXTURE")]])
    }

    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set() {
            lock.lock()
            storage = true
            lock.unlock()
        }
    }

    @MainActor
    func testModelContainerInfersInheritanceMetadata() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self)
        let base = try XCTUnwrap(container.schema.entity(forName: "InheritanceMacroBaseFixture"))
        let child = try XCTUnwrap(container.schema.entity(forName: "InheritanceMacroChildFixture"))
        let grandchild = try XCTUnwrap(container.schema.entity(forName: "InheritanceMacroGrandchildFixture"))
        XCTAssertNil(base.superentityName)
        XCTAssertEqual(child.superentityName, "InheritanceMacroBaseFixture")
        XCTAssertEqual(grandchild.superentityName, "InheritanceMacroChildFixture")
        XCTAssertEqual(child.attributes.map(\.name), ["name", "age"])
        XCTAssertEqual(grandchild.attributes.map(\.name), ["name", "age", "rank"])
    }

    @MainActor
    func testInheritedSQLiteSchemaBootstrapsOneRootTableAndParentIDs() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-schema-bootstrap"))
        let store = try XCTUnwrap(container.store)
        let tables = try store.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z%'", arguments: [])
        }
        XCTAssertEqual(tables, [[.text("Z_PRIMARYKEY")], [.text("ZINHERITANCEMACROBASEFIXTURE")]])
        let entities = try store.read {
            try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT", arguments: [])
        }
        XCTAssertEqual(
            entities,
            [
                [.int(1), .text("InheritanceMacroBaseFixture"), .int(0), .int(0)],
                [.int(2), .text("InheritanceMacroChildFixture"), .int(1), .int(0)],
                [.int(3), .text("InheritanceMacroGrandchildFixture"), .int(2), .int(0)],
            ])
    }

    @MainActor
    func testInheritedChildInsertUsesRootTableAndConcreteDiscriminator() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-child-insert"))
        let context = container.mainContext
        context.insert(InheritanceMacroChildFixture(name: "child", age: 7))
        try context.save()
        let rows = try container.store?.read {
            try $0.rows(
                "SELECT Z_PK, Z_ENT, ZNAME, ZAGE, ZRANK FROM ZINHERITANCEMACROBASEFIXTURE", arguments: [])
        }
        XCTAssertEqual(rows, [[.int(1), .int(2), .text("child"), .int(7), .null]])
    }

    @MainActor
    func testInheritanceFetchCountIdentifiersAndConcreteMaterialization() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-polymorphic-fetch"))
        let writer = container.mainContext
        writer.insert(InheritanceMacroBaseFixture(name: "base"))
        writer.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        writer.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        do {
            try writer.save()
        } catch {
            XCTFail("Saving hierarchy rows failed: \(error)")
            return
        }

        let reader = container.makeContext()
        let baseModels: [InheritanceMacroBaseFixture]
        do {
            baseModels = try reader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
        } catch {
            XCTFail("Fetching the hierarchy root failed: \(error)")
            return
        }
        XCTAssertEqual(baseModels.map(\.name), ["base", "child", "grandchild"])
        XCTAssertTrue(baseModels[1] is InheritanceMacroChildFixture)
        XCTAssertTrue(baseModels[2] is InheritanceMacroGrandchildFixture)
        XCTAssertEqual((baseModels[2] as? InheritanceMacroGrandchildFixture)?.rank, 4)
        let baseCount: Int
        do { baseCount = try reader.fetchCount(FetchDescriptor<InheritanceMacroBaseFixture>()) } catch {
            XCTFail("Counting base hierarchy failed: \(error)"); return
        }
        XCTAssertEqual(baseCount, 3)
        let baseIdentifiers: [PersistentIdentifier]
        do { baseIdentifiers = try reader.fetchIdentifiers(FetchDescriptor<InheritanceMacroBaseFixture>()) } catch {
            XCTFail("Fetching base identifiers failed: \(error)"); return
        }
        XCTAssertEqual(baseIdentifiers.count, 3)
        XCTAssertEqual(baseIdentifiers[1].entityName, "InheritanceMacroChildFixture")
        XCTAssertEqual(baseIdentifiers[2].entityName, "InheritanceMacroGrandchildFixture")

        let childPredicateID = baseIdentifiers[1]
        let childIdentityPredicate = #Predicate<InheritanceMacroBaseFixture> {
            $0.persistentModelID == childPredicateID
        }
        XCTAssertEqual(try reader.fetch(FetchDescriptor(predicate: childIdentityPredicate)).map(\.name), ["child"])
        let grandchildPredicateID = baseIdentifiers[2]
        let grandchildIdentityPredicate = #Predicate<InheritanceMacroBaseFixture> {
            $0.persistentModelID == grandchildPredicateID
        }
        XCTAssertEqual(
            try reader.fetch(FetchDescriptor(predicate: grandchildIdentityPredicate)).map(\.name), ["grandchild"])
        let basePredicateID = baseIdentifiers[0]
        let baseIdentityPredicate = #Predicate<InheritanceMacroBaseFixture> {
            $0.persistentModelID == basePredicateID
        }
        XCTAssertEqual(try reader.fetch(FetchDescriptor(predicate: baseIdentityPredicate)).map(\.name), ["base"])

        let pagedRoot = try reader.fetch(
            FetchDescriptor<InheritanceMacroBaseFixture>(
                sortBy: [SortDescriptor(\InheritanceMacroBaseFixture.name)],
                fetchLimit: 1,
                fetchOffset: 1,
                includePendingChanges: false))
        XCTAssertEqual(pagedRoot.map(\.name), ["child"])
        XCTAssertTrue(pagedRoot.first is InheritanceMacroChildFixture)
        XCTAssertEqual(
            try reader.fetchIdentifiers(
                FetchDescriptor<InheritanceMacroBaseFixture>(
                    sortBy: [SortDescriptor(\InheritanceMacroBaseFixture.name)],
                    fetchLimit: 1,
                    fetchOffset: 1,
                    includePendingChanges: false)),
            pagedRoot.map(\.persistentModelID))
        XCTAssertEqual(
            try reader.fetchCount(
                FetchDescriptor<InheritanceMacroBaseFixture>(
                    sortBy: [SortDescriptor(\InheritanceMacroBaseFixture.name)],
                    fetchLimit: 1,
                    fetchOffset: 1,
                    includePendingChanges: false)),
            1)

        let secondChildPage = try reader.fetch(
            FetchDescriptor<InheritanceMacroChildFixture>(
                sortBy: [SortDescriptor(\InheritanceMacroChildFixture.name)],
                fetchLimit: 1,
                fetchOffset: 1,
                includePendingChanges: false))
        XCTAssertEqual(secondChildPage.map(\.name), ["grandchild"])
        XCTAssertTrue(secondChildPage.first is InheritanceMacroGrandchildFixture)
        XCTAssertEqual(
            try reader.fetchIdentifiers(
                FetchDescriptor<InheritanceMacroChildFixture>(
                    sortBy: [SortDescriptor(\InheritanceMacroChildFixture.name)],
                    fetchLimit: 1,
                    fetchOffset: 1,
                    includePendingChanges: false)),
            secondChildPage.map(\.persistentModelID))

        XCTAssertTrue(try XCTUnwrap(baseModels.first(where: { $0.name == "child" })) is InheritanceMacroChildFixture)
        let childFirstReader = container.makeContext()
        let childFirst = try XCTUnwrap(
            childFirstReader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()).first)
        let childAfterRootFirst = try XCTUnwrap(
            childFirstReader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
                .first(where: { $0.name == "child" }))
        XCTAssertTrue(childFirst === childAfterRootFirst)

        let identifierReader = container.makeContext()
        let childIdentifier = try XCTUnwrap(
            baseIdentifiers.first(where: { $0.entityName == "InheritanceMacroChildFixture" }))
        let resolvedAsBase: InheritanceMacroBaseFixture?
        do { resolvedAsBase = try identifierReader.model(for: childIdentifier) } catch {
            XCTFail("Resolving inherited identifier as its base failed: \(error)")
            return
        }
        XCTAssertTrue(resolvedAsBase is InheritanceMacroChildFixture)
        XCTAssertTrue(
            identifierReader.registeredModel(for: childIdentifier) as InheritanceMacroChildFixture? != nil)
        let resolvedAsChild: InheritanceMacroChildFixture?
        do { resolvedAsChild = try identifierReader.model(for: childIdentifier) } catch {
            XCTFail("Resolving inherited identifier as its concrete type failed: \(error)")
            return
        }
        XCTAssertTrue(resolvedAsBase === resolvedAsChild)
        func resolveGrandchild(_ identifier: PersistentIdentifier) throws -> InheritanceMacroGrandchildFixture? {
            try identifierReader.model(for: identifier)
        }
        XCTAssertThrowsError(try resolveGrandchild(childIdentifier))
        let grandchildIdentifier = try XCTUnwrap(
            baseIdentifiers.first(where: { $0.entityName == "InheritanceMacroGrandchildFixture" }))
        let resolvedGrandchildAsChild: InheritanceMacroChildFixture? = try identifierReader.model(
            for: grandchildIdentifier)
        XCTAssertTrue(resolvedGrandchildAsChild is InheritanceMacroGrandchildFixture)
        let mismatchedIdentifier = PersistentIdentifier(
            storeIdentifier: childIdentifier.storeIdentifier,
            entityName: "InheritanceMacroChildFixture",
            primaryKey: try XCTUnwrap(grandchildIdentifier.primaryKey))
        let mismatchedModel: InheritanceMacroChildFixture? = try identifierReader.model(for: mismatchedIdentifier)
        XCTAssertNil(mismatchedModel)

        let childPredicate = #Predicate<InheritanceMacroChildFixture> {
            $0.name == "child" || $0.age == 3
        }
        let childModels: [InheritanceMacroChildFixture]
        do {
            childModels = try reader.fetch(FetchDescriptor(predicate: childPredicate))
        } catch { XCTFail("Fetching child predicate failed: \(error)"); return }
        XCTAssertEqual(childModels.map(\.age), [2, 3])
        XCTAssertTrue(childModels[1] is InheritanceMacroGrandchildFixture)
        let childCount: Int
        do { childCount = try reader.fetchCount(FetchDescriptor<InheritanceMacroChildFixture>()) } catch {
            XCTFail("Counting child hierarchy failed: \(error)"); return
        }
        XCTAssertEqual(childCount, 2)

        let sortedChildren = try reader.fetch(
            FetchDescriptor<InheritanceMacroChildFixture>(
                sortBy: [SortDescriptor(\InheritanceMacroChildFixture.name)]))
        XCTAssertEqual(sortedChildren.map(\.name), ["child", "grandchild"])
        let projectionReader = container.makeContext()
        let projectedChildren = try projectionReader.fetch(
            FetchDescriptor<InheritanceMacroChildFixture>(
                propertiesToFetch: [\InheritanceMacroChildFixture.name]))
        XCTAssertEqual(projectedChildren.map(\.name), ["child", "grandchild"])
        XCTAssertEqual(projectedChildren.compactMap(\.age), [2, 3])
        XCTAssertEqual(
            try XCTUnwrap(projectedChildren.last as? InheritanceMacroGrandchildFixture).rank, 4)

        let grandchildPredicate = #Predicate<InheritanceMacroGrandchildFixture> {
            $0.name == "grandchild" || $0.rank == 4
        }
        let grandchildModels = try reader.fetch(FetchDescriptor(predicate: grandchildPredicate))
        XCTAssertEqual(grandchildModels.map(\.name), ["grandchild"])

        let pendingBase = InheritanceMacroBaseFixture(name: "pending-base")
        let pendingChild = InheritanceMacroGrandchildFixture(name: "pending-grandchild", age: 5, rank: 6)
        reader.insert(pendingBase)
        reader.insert(pendingChild)
        let pendingHierarchyDescriptor = FetchDescriptor<InheritanceMacroBaseFixture>(
            predicate: #Predicate { $0.name != "base" },
            sortBy: [SortDescriptor(\.name)],
            includePendingChanges: true)
        let pendingHierarchy = try reader.fetch(pendingHierarchyDescriptor)
        XCTAssertEqual(pendingHierarchy.map(\.name), ["child", "grandchild", "pending-base", "pending-grandchild"])
        XCTAssertTrue(pendingHierarchy[0] is InheritanceMacroChildFixture)
        XCTAssertTrue(pendingHierarchy[1] is InheritanceMacroGrandchildFixture)
        XCTAssertFalse(pendingHierarchy[2] is InheritanceMacroChildFixture)
        XCTAssertTrue(pendingHierarchy[3] is InheritanceMacroGrandchildFixture)
        XCTAssertEqual(
            try reader.fetchIdentifiers(pendingHierarchyDescriptor), pendingHierarchy.map(\.persistentModelID))
        XCTAssertEqual(try reader.fetchCount(pendingHierarchyDescriptor), pendingHierarchy.count)

        try reader.save()
        let persistedHierarchyDescriptor = FetchDescriptor<InheritanceMacroBaseFixture>(
            predicate: #Predicate { $0.name != "base" },
            sortBy: [SortDescriptor(\.name)],
            includePendingChanges: false)
        let persistedHierarchy = try reader.fetch(persistedHierarchyDescriptor)
        XCTAssertEqual(persistedHierarchy.map(\.name), pendingHierarchy.map(\.name))
        XCTAssertTrue(persistedHierarchy[0] is InheritanceMacroChildFixture)
        XCTAssertTrue(persistedHierarchy[1] is InheritanceMacroGrandchildFixture)
        XCTAssertFalse(persistedHierarchy[2] is InheritanceMacroChildFixture)
        XCTAssertTrue(persistedHierarchy[3] is InheritanceMacroGrandchildFixture)
        XCTAssertEqual(
            try reader.fetchIdentifiers(persistedHierarchyDescriptor), persistedHierarchy.map(\.persistentModelID))
        XCTAssertEqual(try reader.fetchCount(persistedHierarchyDescriptor), persistedHierarchy.count)

        let reverseReader = container.makeContext()
        let reverseChildren: [InheritanceMacroChildFixture]
        do { reverseChildren = try reverseReader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()) } catch {
            XCTFail("Reverse child fetch failed: \(error)"); return
        }
        let reverseRoots: [InheritanceMacroBaseFixture]
        do { reverseRoots = try reverseReader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()) } catch {
            XCTFail("Reverse root fetch failed: \(error)"); return
        }
        XCTAssertTrue(reverseRoots[1] === reverseChildren[0])
    }

    @MainActor
    func testHierarchyEnumerationResolvesConcreteSubtypesAcrossBatches() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-enumeration"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        context.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        context.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        try context.save()

        let descriptor = FetchDescriptor<InheritanceMacroBaseFixture>()
        let enumeratingContext = container.makeContext()
        var enumerated: [InheritanceMacroBaseFixture] = []
        try enumeratingContext.enumerate(descriptor, batchSize: 1) { enumerated.append($0) }
        let fetched = try container.makeContext().fetch(descriptor)

        XCTAssertEqual(enumerated.count, 3)
        XCTAssertEqual(enumerated.map(\.persistentModelID), fetched.map(\.persistentModelID))
        XCTAssertTrue(enumerated[1] is InheritanceMacroChildFixture)
        XCTAssertTrue(enumerated[2] is InheritanceMacroGrandchildFixture)
        XCTAssertEqual(enumerated.map(\.name), ["base", "child", "grandchild"])
        XCTAssertFalse(enumeratingContext.hasChanges)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testPredicateDeleteIncludesSubclassesAndSavesMatches() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-predicate-delete"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        context.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        context.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        try context.save()

        try context.delete(model: InheritanceMacroBaseFixture.self, where: #Predicate { $0.name != "missing" })

        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).isEmpty)
    }

    @MainActor
    func testPredicateDeleteWithoutPredicateDeletesAllRequestedModels() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-delete-without-predicate"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        context.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        context.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        try context.save()

        try context.delete(model: InheritanceMacroBaseFixture.self)

        XCTAssertTrue(try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).isEmpty)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testPredicateDeleteWithoutPredicateCanExcludeSubclasses() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-delete-all-exact-type"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        context.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        context.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        try context.save()

        try context.delete(model: InheritanceMacroBaseFixture.self, includeSubclasses: false)

        let remaining = try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
        XCTAssertEqual(remaining.map(\.name), ["child", "grandchild"])
        XCTAssertTrue(remaining[0] is InheritanceMacroChildFixture)
        XCTAssertTrue(remaining[1] is InheritanceMacroGrandchildFixture)
    }

    @MainActor
    func testPredicateDeleteInsideTransactionDefersSaveToOuterBoundary() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-predicate-delete-transaction"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        context.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        try context.save()

        try context.transaction {
            try context.delete(model: InheritanceMacroBaseFixture.self, where: #Predicate { $0.name == "base" })
            XCTAssertTrue(context.hasChanges)
            let inTransaction = try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
            XCTAssertEqual(inTransaction.map(\.name), ["base", "child"])
        }

        let afterCommit = try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
        XCTAssertEqual(afterCommit.map(\.name), ["child"])
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testPredicateDeleteRollsBackWithFailedOuterTransaction() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-predicate-delete-rollback"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        try context.save()
        let model = try XCTUnwrap(context.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first)
        let identifier = model.persistentModelID

        XCTAssertThrowsError(
            try context.transaction {
                try context.delete(model: InheritanceMacroBaseFixture.self)
                throw SwiftDataError.unsupportedStore("rollback predicate delete")
            })

        XCTAssertTrue(model.modelContext === context)
        XCTAssertEqual(model.persistentModelID, identifier)
        XCTAssertFalse(model.isDeleted)
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(
            try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).map(\.name), ["base"])
    }

    @MainActor
    func testPredicateDeleteCanExcludeSubclasses() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-predicate-delete-exact-type"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        context.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        context.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        try context.save()

        try context.delete(
            model: InheritanceMacroBaseFixture.self,
            where: #Predicate { $0.name != "missing" },
            includeSubclasses: false)

        let remaining = try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
        XCTAssertEqual(remaining.map(\.name), ["child", "grandchild"])
        XCTAssertTrue(remaining[0] is InheritanceMacroChildFixture)
        XCTAssertTrue(remaining[1] is InheritanceMacroGrandchildFixture)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testPredicateDeleteCanTargetHierarchyMidpointOnly() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-predicate-delete-midpoint"))
        let context = container.mainContext
        context.insert(InheritanceMacroBaseFixture(name: "base"))
        context.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        context.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        try context.save()

        try context.delete(
            model: InheritanceMacroChildFixture.self,
            where: #Predicate { $0.name != "missing" },
            includeSubclasses: false)

        let remaining = try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
        XCTAssertEqual(remaining.map(\.name), ["base", "grandchild"])
        XCTAssertFalse(remaining[0] is InheritanceMacroChildFixture)
        XCTAssertTrue(remaining[1] is InheritanceMacroGrandchildFixture)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testPredicateDeleteCancelsMatchingPendingInsertions() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-predicate-delete-pending"))
        let context = container.mainContext
        let pendingBase = InheritanceMacroBaseFixture(name: "pending-base")
        let pendingChild = InheritanceMacroChildFixture(name: "pending-child", age: 2)
        context.insert(pendingBase)
        context.insert(pendingChild)

        try context.delete(
            model: InheritanceMacroBaseFixture.self, where: #Predicate { $0.name.starts(with: "pending-") })

        XCTAssertNil(pendingBase.modelContext)
        XCTAssertNil(pendingChild.modelContext)
        XCTAssertFalse(pendingBase.isDeleted)
        XCTAssertFalse(pendingChild.isDeleted)
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(try container.makeContext().fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).isEmpty)
    }

    @MainActor
    func testEnumerationHonorsCommittedOnlyDescriptorWithPendingDeletion() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-enumeration-committed-deletion"))
        let writer = container.mainContext
        let child = InheritanceMacroChildFixture(name: "child", age: 2)
        let grandchild = InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4)
        writer.insert(child)
        writer.insert(grandchild)
        try writer.save()

        let reader = container.makeContext()
        let fetchedChild = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()).first { $0.name == "child" })
        reader.delete(fetchedChild)

        let committedDescriptor = FetchDescriptor<InheritanceMacroBaseFixture>(includePendingChanges: false)
        let committedFetch = try reader.fetch(committedDescriptor)
        var committedEnumeration: [InheritanceMacroBaseFixture] = []
        try reader.enumerate(committedDescriptor, batchSize: 1) { committedEnumeration.append($0) }
        XCTAssertEqual(committedEnumeration.map(\.persistentModelID), committedFetch.map(\.persistentModelID))
        XCTAssertTrue(committedEnumeration[0] === fetchedChild)
        XCTAssertTrue(committedEnumeration[0].isDeleted)
        XCTAssertEqual(committedEnumeration.map(\.name), ["child", "grandchild"])

        let pendingDescriptor = FetchDescriptor<InheritanceMacroBaseFixture>()
        let pendingFetch = try reader.fetch(pendingDescriptor)
        var pendingEnumeration: [InheritanceMacroBaseFixture] = []
        try reader.enumerate(pendingDescriptor, batchSize: 1) { pendingEnumeration.append($0) }
        XCTAssertEqual(pendingEnumeration.map(\.persistentModelID), pendingFetch.map(\.persistentModelID))
        XCTAssertEqual(pendingEnumeration.map(\.name), ["grandchild"])

        try reader.save()
        XCTAssertEqual(try reader.fetch(committedDescriptor).map(\.name), ["grandchild"])
    }

    @MainActor
    func testPendingHierarchyDeletionMatchesCommittedOnlyQueries() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-pending-delete-query-parity"))
        let writer = container.mainContext
        let child = InheritanceMacroChildFixture(name: "child", age: 2)
        let grandchild = InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4)
        writer.insert(child)
        writer.insert(grandchild)
        try writer.save()

        let reader = container.makeContext()
        reader.delete(try XCTUnwrap(reader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()).first))

        let pendingBase = FetchDescriptor<InheritanceMacroBaseFixture>()
        let committedBase = FetchDescriptor<InheritanceMacroBaseFixture>(includePendingChanges: false)
        XCTAssertEqual(try reader.fetch(pendingBase).map(\.name), ["grandchild"])
        XCTAssertEqual(try reader.fetchCount(pendingBase), 1)
        XCTAssertEqual(
            try reader.fetchIdentifiers(pendingBase).map(\.entityName), ["InheritanceMacroGrandchildFixture"])
        XCTAssertEqual(try reader.fetch(committedBase).map(\.name), ["child", "grandchild"])
        XCTAssertEqual(try reader.fetchCount(committedBase), 2)
        XCTAssertEqual(
            try reader.fetchIdentifiers(committedBase).map(\.entityName),
            ["InheritanceMacroChildFixture", "InheritanceMacroGrandchildFixture"])

        let pendingChildren = FetchDescriptor<InheritanceMacroChildFixture>()
        let committedChildren = FetchDescriptor<InheritanceMacroChildFixture>(includePendingChanges: false)
        XCTAssertEqual(try reader.fetch(pendingChildren).map(\.name), ["grandchild"])
        XCTAssertEqual(try reader.fetchCount(pendingChildren), 1)
        XCTAssertEqual(
            try reader.fetchIdentifiers(pendingChildren).map(\.entityName), ["InheritanceMacroGrandchildFixture"])
        XCTAssertEqual(try reader.fetch(committedChildren).map(\.name), ["child", "grandchild"])
        XCTAssertEqual(try reader.fetchCount(committedChildren), 2)
        XCTAssertEqual(
            try reader.fetchIdentifiers(committedChildren).map(\.entityName),
            ["InheritanceMacroChildFixture", "InheritanceMacroGrandchildFixture"])

        try reader.save()
        XCTAssertEqual(try reader.fetch(pendingBase).map(\.name), ["grandchild"])
        XCTAssertEqual(try reader.fetch(committedBase).map(\.name), ["grandchild"])
        XCTAssertEqual(try reader.fetchCount(pendingBase), 1)
        XCTAssertEqual(try reader.fetchCount(committedBase), 1)
        XCTAssertEqual(try reader.fetchIdentifiers(pendingBase), try reader.fetchIdentifiers(committedBase))
        XCTAssertEqual(try reader.fetch(pendingChildren).map(\.name), ["grandchild"])
        XCTAssertEqual(try reader.fetch(committedChildren).map(\.name), ["grandchild"])
        XCTAssertEqual(try reader.fetchCount(pendingChildren), 1)
        XCTAssertEqual(try reader.fetchCount(committedChildren), 1)
        XCTAssertEqual(try reader.fetchIdentifiers(pendingChildren), try reader.fetchIdentifiers(committedChildren))
    }

    @MainActor
    func testPendingHierarchyChangesAreMergedBeforePagination() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-pending-pagination"))
        let writer = container.mainContext
        let child = InheritanceMacroChildFixture(name: "a-child", age: 1)
        let grandchild = InheritanceMacroGrandchildFixture(name: "b-grandchild", age: 2, rank: 3)
        let base = InheritanceMacroBaseFixture(name: "c-base")
        writer.insert(child)
        writer.insert(grandchild)
        writer.insert(base)
        try writer.save()
        let committedIdentifiers = try writer.fetchIdentifiers(FetchDescriptor<InheritanceMacroBaseFixture>())

        let reader = container.makeContext()
        let fetchedChild = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()).first)
        reader.delete(fetchedChild)
        let pendingChild = InheritanceMacroChildFixture(name: "d-child", age: 4)
        reader.insert(pendingChild)

        let descriptor = FetchDescriptor<InheritanceMacroBaseFixture>(
            sortBy: [SortDescriptor(\.name)],
            fetchLimit: 2,
            fetchOffset: 1)
        let identifierPage = try reader.fetchIdentifiers(descriptor)
        XCTAssertEqual(try reader.fetchCount(descriptor), identifierPage.count)
        let unmaterializedBaseID = try XCTUnwrap(
            committedIdentifiers.first { $0.entityName == "InheritanceMacroBaseFixture" })
        let unmaterializedGrandchildID = try XCTUnwrap(
            committedIdentifiers.first { $0.entityName == "InheritanceMacroGrandchildFixture" })
        let unmaterializedBase: InheritanceMacroBaseFixture? = reader.registeredModel(for: unmaterializedBaseID)
        let unmaterializedGrandchild: InheritanceMacroBaseFixture? = reader.registeredModel(
            for: unmaterializedGrandchildID)
        XCTAssertNil(unmaterializedBase)
        XCTAssertNil(unmaterializedGrandchild)
        let page = try reader.fetch(descriptor)
        XCTAssertEqual(page.map(\.name), ["c-base", "d-child"])
        XCTAssertFalse(page[0] is InheritanceMacroChildFixture)
        XCTAssertTrue(page[1] is InheritanceMacroChildFixture)
        XCTAssertEqual(try reader.fetchIdentifiers(descriptor), page.map(\.persistentModelID))
        XCTAssertEqual(try reader.fetchCount(descriptor), 2)
    }

    @MainActor
    func testSubtypeSortKeyOrdersHierarchyRowsAndPendingUpdates() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-subtype-sort"))
        let writer = container.mainContext
        let child = InheritanceMacroChildFixture(name: "child", age: 30)
        let grandchild = InheritanceMacroGrandchildFixture(name: "grandchild", age: 10, rank: 1)
        writer.insert(child)
        writer.insert(grandchild)
        try writer.save()

        let reader = container.makeContext()
        let descriptor = FetchDescriptor<InheritanceMacroChildFixture>(
            sortBy: [SortDescriptor(\.age)],
            fetchLimit: 1)
        let firstStoredPage = try reader.fetch(descriptor)
        XCTAssertTrue(try XCTUnwrap(firstStoredPage.first) is InheritanceMacroGrandchildFixture)
        XCTAssertEqual(firstStoredPage.first?.age, 10)
        XCTAssertEqual(try reader.fetchIdentifiers(descriptor), firstStoredPage.map(\.persistentModelID))
        XCTAssertEqual(try reader.fetchCount(descriptor), 1)

        let fetchedChild = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()).first { $0.name == "child" })
        fetchedChild.age = 5
        let updatedPage = try reader.fetch(descriptor)
        XCTAssertEqual(updatedPage.map(\.name), ["child"])
        XCTAssertEqual(updatedPage.first?.age, 5)
        XCTAssertEqual(try reader.fetchIdentifiers(descriptor), updatedPage.map(\.persistentModelID))
        XCTAssertEqual(try reader.fetchCount(descriptor), 1)

        try reader.save()
        let reopenedPage = try reader.fetch(
            FetchDescriptor<InheritanceMacroChildFixture>(
                sortBy: [SortDescriptor(\.age)],
                fetchLimit: 2,
                includePendingChanges: false))
        XCTAssertEqual(reopenedPage.map(\.name), ["child", "grandchild"])
        XCTAssertEqual(reopenedPage.map(\.age), [5, 10])
        XCTAssertTrue(reopenedPage[1] is InheritanceMacroGrandchildFixture)
    }

    @MainActor
    func testRelationshipPersistentIdentifierMatchesInheritedEndpoint() throws {
        let container = try ModelContainer(
            for: InheritanceIdentifierOwnerFixture.self,
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("relationship-inherited-identifier"))
        let context = container.mainContext
        let owner = InheritanceIdentifierOwnerFixture(name: "owner")
        let missing = InheritanceIdentifierOwnerFixture(name: "missing")
        let child = InheritanceMacroChildFixture(name: "child", age: 4)
        context.insert(owner)
        context.insert(missing)
        context.insert(child)
        owner.favorite = child
        try context.save()

        let identifier = child.persistentModelID
        let equal = FetchDescriptor<InheritanceIdentifierOwnerFixture>(
            predicate: #Predicate<InheritanceIdentifierOwnerFixture> {
                $0.favorite?.persistentModelID == identifier
            })
        let notEqual = FetchDescriptor<InheritanceIdentifierOwnerFixture>(
            predicate: #Predicate<InheritanceIdentifierOwnerFixture> {
                $0.favorite?.persistentModelID != identifier
            })
        XCTAssertEqual(try context.fetch(equal).map(\.name), ["owner"])
        XCTAssertEqual(try context.fetch(notEqual).map(\.name), ["missing"])
    }

    @MainActor
    func testAddingLeafSubclassToExistingSQLiteHierarchyPreservesEntityIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let configuration = ModelConfiguration.sqliteFile("leaf-subclass-addition", url: url)
        let sourceContainer = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            configurations: configuration)
        let sourceIDs = sourceContainer.schema.entityIDsByName
        let sourceContext = sourceContainer.mainContext
        let base = InheritanceMacroBaseFixture(name: "base")
        let child = InheritanceMacroChildFixture(name: "child", age: 8)
        sourceContext.insert(base)
        sourceContext.insert(child)
        try sourceContext.save()
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroAardvarkFixture.self,
            InheritanceMacroPuppyFixture.self,
            configurations: configuration)
        let runtimeIDs = container.schema.entityIDsByName
        XCTAssertEqual(runtimeIDs["InheritanceMacroBaseFixture"], sourceIDs["InheritanceMacroBaseFixture"])
        XCTAssertEqual(runtimeIDs["InheritanceMacroChildFixture"], sourceIDs["InheritanceMacroChildFixture"])
        XCTAssertGreaterThan(
            try XCTUnwrap(runtimeIDs["InheritanceMacroAardvarkFixture"]),
            try XCTUnwrap(sourceIDs.values.max()))
        XCTAssertGreaterThan(
            try XCTUnwrap(runtimeIDs["InheritanceMacroPuppyFixture"]),
            try XCTUnwrap(runtimeIDs["InheritanceMacroAardvarkFixture"]))

        let existingChildren = try container.mainContext.fetch(FetchDescriptor<InheritanceMacroChildFixture>())
        XCTAssertEqual(existingChildren.map(\.name), ["child"])
        let puppy = InheritanceMacroPuppyFixture(name: "puppy", age: 1, collar: "red")
        container.mainContext.insert(puppy)
        let newLeaf = InheritanceMacroAardvarkFixture(name: "new leaf", color: "black")
        container.mainContext.insert(newLeaf)
        try container.mainContext.save()
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).map(\.name),
            ["base", "child", "new leaf", "puppy"])
        let fetchedPuppy = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<InheritanceMacroChildFixture>())
                .first(where: { $0.name == "puppy" }))
        XCTAssertTrue(fetchedPuppy is InheritanceMacroPuppyFixture)
        XCTAssertEqual((fetchedPuppy as? InheritanceMacroPuppyFixture)?.collar, "red")
        XCTAssertEqual(newLeaf.persistentModelID.entityName, "InheritanceMacroAardvarkFixture")
    }

    @MainActor
    func testAddingLeafWithRequiredDefaultMaterializesTypedDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration.sqliteFile(
            "leaf-required-default-migration", url: directory.appendingPathComponent("store.sqlite"))
        let sourceContainer = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            configurations: configuration)
        sourceContainer.mainContext.insert(InheritanceMacroBaseFixture(name: "existing"))
        try sourceContainer.mainContext.save()
        let sourceIDs = sourceContainer.schema.entityIDsByName
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroKittenFixture.self,
            configurations: configuration)
        XCTAssertEqual(
            container.schema.entityIDsByName["InheritanceMacroBaseFixture"],
            sourceIDs["InheritanceMacroBaseFixture"])
        let existing = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first)
        XCTAssertEqual(existing.name, "existing")

        let kitten = InheritanceMacroKittenFixture(name: "kitten")
        container.mainContext.insert(kitten)
        XCTAssertEqual(kitten.rank, 7)
        try container.mainContext.save()
        let fetched = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<InheritanceMacroKittenFixture>()).first)
        XCTAssertEqual(fetched.rank, 7)
        XCTAssertEqual(fetched.name, "kitten")
    }

    @MainActor
    func testAddingIndependentRootWithOptionalToOneRelationshipRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration.sqliteFile(
            "independent-root-to-one-migration", url: directory.appendingPathComponent("store.sqlite"))
        let sourceContainer = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            configurations: configuration)
        let base = InheritanceMacroBaseFixture(name: "base")
        let child = InheritanceMacroChildFixture(name: "child", age: 3)
        let target = InheritedToOneMigrationTargetFixture(title: "target")
        sourceContainer.mainContext.insert(base)
        sourceContainer.mainContext.insert(child)
        sourceContainer.mainContext.insert(target)
        try sourceContainer.mainContext.save()
        let sourceIDs = sourceContainer.schema.entityIDsByName
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: IndependentRelationshipRootFixture.self,
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            configurations: configuration)
        XCTAssertEqual(
            container.schema.entityIDsByName["InheritanceMacroBaseFixture"],
            sourceIDs["InheritanceMacroBaseFixture"])
        XCTAssertEqual(
            container.schema.entityIDsByName["InheritedToOneMigrationTargetFixture"],
            sourceIDs["InheritedToOneMigrationTargetFixture"])

        let newRoot = IndependentRelationshipRootFixture(name: "new root", target: target)
        container.mainContext.insert(newRoot)
        try container.mainContext.save()
        let reader = container.makeContext()
        let fetched = try XCTUnwrap(
            reader.fetch(FetchDescriptor<IndependentRelationshipRootFixture>()).first)
        XCTAssertEqual(fetched.target?.title, "target")
        fetched.target = nil
        try reader.save()

        let reopened = try ModelContainer(
            for: IndependentRelationshipRootFixture.self,
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            configurations: configuration)
        let refreshed = try XCTUnwrap(
            reopened.mainContext.fetch(FetchDescriptor<IndependentRelationshipRootFixture>()).first)
        XCTAssertNil(refreshed.target)
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).map(\.name),
            ["base", "child"])
    }

    @MainActor
    func testAddingIndependentRootWithToManyJoinTableRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration.sqliteFile(
            "independent-root-to-many-migration", url: directory.appendingPathComponent("store.sqlite"))
        let sourceContainer = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            ToManyHierarchyTargetChildFixture.self,
            ToManyHierarchyTargetGrandchildFixture.self,
            ToManyHierarchyTargetSiblingFixture.self,
            configurations: configuration)
        let base = InheritanceMacroBaseFixture(name: "base")
        let child = InheritanceMacroChildFixture(name: "child", age: 2)
        let first = ToManyHierarchyTargetChildFixture(title: "first", code: "one")
        let second = ToManyHierarchyTargetGrandchildFixture(title: "second", code: "two", rank: 2)
        let sibling = ToManyHierarchyTargetSiblingFixture(title: "sibling", label: "other")
        sourceContainer.mainContext.insert(base)
        sourceContainer.mainContext.insert(child)
        sourceContainer.mainContext.insert(first)
        sourceContainer.mainContext.insert(second)
        sourceContainer.mainContext.insert(sibling)
        try sourceContainer.mainContext.save()
        let sourceIDs = sourceContainer.schema.entityIDsByName
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: IndependentToManyRootFixture.self,
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            ToManyHierarchyTargetChildFixture.self,
            ToManyHierarchyTargetGrandchildFixture.self,
            ToManyHierarchyTargetSiblingFixture.self,
            configurations: configuration)
        XCTAssertEqual(
            container.schema.entityIDsByName["InheritanceMacroBaseFixture"],
            sourceIDs["InheritanceMacroBaseFixture"])
        let root = IndependentToManyRootFixture(name: "root", items: [first, second])
        container.mainContext.insert(root)
        try container.mainContext.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<IndependentToManyRootFixture>()).first)
        XCTAssertEqual(Set(fetched.items.map(\.title)), ["first", "second"])
        XCTAssertTrue(fetched.items.contains { $0 is ToManyHierarchyTargetGrandchildFixture })
        fetched.items.removeAll { $0.title == "first" }
        try reader.save()

        let reopened = try ModelContainer(
            for: IndependentToManyRootFixture.self,
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            ToManyHierarchyTargetChildFixture.self,
            ToManyHierarchyTargetGrandchildFixture.self,
            ToManyHierarchyTargetSiblingFixture.self,
            configurations: configuration)
        let refreshed = try XCTUnwrap(
            reopened.mainContext.fetch(FetchDescriptor<IndependentToManyRootFixture>()).first)
        XCTAssertEqual(refreshed.items.map(\.title), ["second"])
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).map(\.name),
            ["base", "child"])
    }

    @MainActor
    func testAddingEntirelyNewRootAndLeafTreeRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration.sqliteFile(
            "new-tree-migration", url: directory.appendingPathComponent("store.sqlite"))
        let sourceContainer = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            configurations: configuration)
        let base = InheritanceMacroBaseFixture(name: "existing base")
        let child = InheritanceMacroChildFixture(name: "existing child", age: 4)
        let target = InheritedToOneMigrationTargetFixture(title: "target")
        sourceContainer.mainContext.insert(base)
        sourceContainer.mainContext.insert(child)
        sourceContainer.mainContext.insert(target)
        try sourceContainer.mainContext.save()
        let sourceIDs = sourceContainer.schema.entityIDsByName
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: MigratedTreeRootFixture.self,
            MigratedTreeLeafFixture.self,
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            configurations: configuration)
        for name in [
            "InheritanceMacroBaseFixture", "InheritanceMacroChildFixture", "InheritedToOneMigrationTargetFixture",
        ] {
            XCTAssertEqual(container.schema.entityIDsByName[name], sourceIDs[name])
        }
        let rootID = try XCTUnwrap(container.schema.entityIDsByName["MigratedTreeRootFixture"])
        let leafID = try XCTUnwrap(container.schema.entityIDsByName["MigratedTreeLeafFixture"])
        XCTAssertLessThan(rootID, leafID)

        let root = MigratedTreeRootFixture(name: "new root")
        let leaf = MigratedTreeLeafFixture(name: "new leaf", label: "leaf", target: target)
        container.mainContext.insert(root)
        container.mainContext.insert(leaf)
        try container.mainContext.save()
        let reader = container.makeContext()
        XCTAssertEqual(
            Set(try reader.fetch(FetchDescriptor<MigratedTreeRootFixture>()).map(\.name)), ["new root", "new leaf"])
        let fetchedLeaf = try XCTUnwrap(reader.fetch(FetchDescriptor<MigratedTreeLeafFixture>()).first)
        XCTAssertEqual(fetchedLeaf.target?.title, "target")
        XCTAssertEqual(fetchedLeaf.label, "leaf")

        let reopened = try ModelContainer(
            for: MigratedTreeRootFixture.self,
            MigratedTreeLeafFixture.self,
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            configurations: configuration)
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).map(\.name),
            ["existing base", "existing child"])
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<MigratedTreeLeafFixture>()).first?.target?.title,
            "target")
    }

    @MainActor
    func testNoInverseToManyBetweenHierarchiesIsIsolatedByDeclaringLeaf() throws {
        let container = try ModelContainer(
            for: DualHierarchyOwnerBaseFixture.self,
            DualHierarchyOwnerLeafAFixture.self,
            DualHierarchyOwnerLeafBFixture.self,
            DualHierarchyTargetBaseFixture.self,
            DualHierarchyTargetLeafFixture.self,
            DualHierarchyTargetSiblingFixture.self,
            configurations: .sqliteMemory("dual-hierarchy-no-inverse-to-many"))
        let writer = container.mainContext
        let firstTarget = DualHierarchyTargetLeafFixture(name: "first", code: "a")
        let secondTarget = DualHierarchyTargetLeafFixture(name: "second", code: "b")
        let siblingTarget = DualHierarchyTargetSiblingFixture(name: "sibling", label: "x")
        let firstOwner = DualHierarchyOwnerLeafAFixture(name: "first owner", items: [firstTarget])
        let secondOwner = DualHierarchyOwnerLeafBFixture(name: "second owner", items: [secondTarget])
        writer.insert(firstTarget)
        writer.insert(secondTarget)
        writer.insert(siblingTarget)
        writer.insert(firstOwner)
        writer.insert(secondOwner)
        try writer.save()

        let reader = container.makeContext()
        let owners = try reader.fetch(FetchDescriptor<DualHierarchyOwnerBaseFixture>())
        let fetchedFirstOwner = try XCTUnwrap(
            owners.first { $0.name == "first owner" } as? DualHierarchyOwnerLeafAFixture)
        let fetchedSecondOwner = try XCTUnwrap(
            owners.first { $0.name == "second owner" } as? DualHierarchyOwnerLeafBFixture)
        XCTAssertEqual(fetchedFirstOwner.items.map(\.name), ["first"])
        XCTAssertEqual(fetchedSecondOwner.items.map(\.name), ["second"])

        let firstPredicate = #Predicate<DualHierarchyOwnerLeafAFixture> { owner in
            owner.items.contains { $0.code == "b" }
        }
        XCTAssertTrue(try reader.fetch(FetchDescriptor(predicate: firstPredicate)).isEmpty)

        let readerTarget = try XCTUnwrap(
            reader.fetch(FetchDescriptor<DualHierarchyTargetLeafFixture>()).first(where: { $0.name == "first" }))
        XCTAssertEqual(readerTarget.persistentModelID.entityName, "DualHierarchyTargetLeafFixture")
        reader.delete(readerTarget)
        try reader.save()
        let joinTableA = "Z_DUALHIERARCHYOWNERLEAFAFIXTURE_ITEMS_DUALHIERARCHYTARGETLEAFFIXTURE"
        let joinTableB = "Z_DUALHIERARCHYOWNERLEAFBFIXTURE_ITEMS_DUALHIERARCHYTARGETLEAFFIXTURE"
        let afterTargetDeleteCounts = try container.store?.read {
            try $0.rows(
                "SELECT (SELECT COUNT(*) FROM \(joinTableA)), (SELECT COUNT(*) FROM \(joinTableB))",
                arguments: [])
        }
        XCTAssertEqual(afterTargetDeleteCounts, [[.int(0), .int(1)]])
        let afterTargetDelete = container.makeContext()
        let remainingOwners = try afterTargetDelete.fetch(FetchDescriptor<DualHierarchyOwnerBaseFixture>())
        let remainingFirstOwner = try XCTUnwrap(
            remainingOwners.first { $0.name == "first owner" } as? DualHierarchyOwnerLeafAFixture)
        let remainingSecondOwner = try XCTUnwrap(
            remainingOwners.first { $0.name == "second owner" } as? DualHierarchyOwnerLeafBFixture)
        XCTAssertTrue(remainingFirstOwner.items.isEmpty)
        XCTAssertEqual(remainingSecondOwner.items.map(\.name), ["second"])

        afterTargetDelete.delete(remainingFirstOwner)
        try afterTargetDelete.save()
        let counts = try container.store?.read {
            try $0.rows(
                "SELECT (SELECT COUNT(*) FROM \(joinTableA)), (SELECT COUNT(*) FROM \(joinTableB))", arguments: [])
        }
        XCTAssertEqual(counts, [[.int(0), .int(1)]])
    }

    @MainActor
    func testInheritedDefaultedPropertyIsReadableBeforeContextInsertion() throws {
        let kitten = InheritanceMacroKittenFixture(name: "detached")
        XCTAssertEqual(kitten.rank, 7)
    }

    @MainActor
    func testAddingLeafToOneRelationshipMigratesQualifiedRootColumn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration.sqliteFile(
            "leaf-to-one-relationship-migration", url: directory.appendingPathComponent("store.sqlite"))
        let sourceContainer = try ModelContainer(
            for: InheritedToOneMigrationBaseFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            configurations: configuration)
        let originalBase = InheritedToOneMigrationBaseFixture(name: "base")
        let target = InheritedToOneMigrationTargetFixture(title: "target")
        sourceContainer.mainContext.insert(originalBase)
        sourceContainer.mainContext.insert(target)
        try sourceContainer.mainContext.save()
        let sourceIDs = sourceContainer.schema.entityIDsByName
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: InheritedToOneMigrationBaseFixture.self,
            InheritedToOneMigrationTargetFixture.self,
            InheritedToOneMigrationChildFixture.self,
            configurations: configuration)
        XCTAssertEqual(
            container.schema.relationshipStorageMapping(
                modelEntityName: "InheritedToOneMigrationChildFixture", relationshipName: "target")?
                .storageColumnName,
            "InheritedToOneMigrationChildFixture_target")
        XCTAssertEqual(
            container.schema.entityIDsByName["InheritedToOneMigrationBaseFixture"],
            sourceIDs["InheritedToOneMigrationBaseFixture"])

        let child = InheritedToOneMigrationChildFixture(name: "child", target: target)
        container.mainContext.insert(child)
        try container.mainContext.save()
        let reader = container.makeContext()
        let fetchedChild = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritedToOneMigrationChildFixture>()).first)
        XCTAssertEqual(fetchedChild.target?.title, "target")
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<InheritedToOneMigrationBaseFixture>()), 2)

        fetchedChild.target = nil
        try reader.save()
        let refreshedChild = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<InheritedToOneMigrationChildFixture>()).first)
        XCTAssertNil(refreshedChild.target)
    }

    @MainActor
    func testAddingLeafToManyRelationshipMigratesJoinTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration.sqliteFile(
            "leaf-to-many-relationship-migration", url: directory.appendingPathComponent("store.sqlite"))
        let sourceContainer = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritedToManyMigrationItemFixture.self,
            configurations: configuration)
        let firstItem = InheritedToManyMigrationItemFixture(title: "first")
        let secondItem = InheritedToManyMigrationItemFixture(title: "second")
        sourceContainer.mainContext.insert(InheritanceMacroBaseFixture(name: "base"))
        sourceContainer.mainContext.insert(firstItem)
        sourceContainer.mainContext.insert(secondItem)
        try sourceContainer.mainContext.save()
        let sourceIDs = sourceContainer.schema.entityIDsByName
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritedToManyMigrationItemFixture.self,
            InheritedToManyMigrationChildFixture.self,
            configurations: configuration)
        XCTAssertEqual(
            container.schema.entityIDsByName["InheritanceMacroBaseFixture"],
            sourceIDs["InheritanceMacroBaseFixture"])
        let childID = try XCTUnwrap(container.schema.entityIDsByName["InheritedToManyMigrationChildFixture"])
        XCTAssertGreaterThan(childID, try XCTUnwrap(sourceIDs.values.max()))

        let child = InheritedToManyMigrationChildFixture(name: "child", items: [firstItem, secondItem])
        container.mainContext.insert(child)
        try container.mainContext.save()
        let reader = container.makeContext()
        let fetched = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritedToManyMigrationChildFixture>()).first)
        XCTAssertEqual(Set(fetched.items.map(\.title)), ["first", "second"])
        fetched.items.removeAll { $0.title == "first" }
        try reader.save()
        let refreshed = try XCTUnwrap(
            container.makeContext().fetch(FetchDescriptor<InheritedToManyMigrationChildFixture>()).first)
        XCTAssertEqual(refreshed.items.map(\.title), ["second"])
        let joinTables = try container.store?.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z_%'", arguments: [])
        }
        XCTAssertTrue(
            joinTables?.contains {
                $0 == [.text("Z_INHERITEDTOMANYMIGRATIONCHILDFIXTURE_ITEMS_INHERITEDTOMANYMIGRATIONITEMFIXTURE")]
            } == true)
    }

    @MainActor
    func testAddingLeafInverseRelationshipPreservesExistingToOneStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration.sqliteFile(
            "leaf-inverse-relationship-migration", url: directory.appendingPathComponent("store.sqlite"))
        let sourceContainer = try ModelContainer(
            for: InverseMigrationOwnerFixture.self,
            InverseMigrationTargetBaseFixture.self,
            configurations: configuration)
        let oldTarget = InverseMigrationTargetBaseFixture(name: "old target")
        let oldOwner = InverseMigrationOwnerFixture(name: "old owner", target: oldTarget)
        sourceContainer.mainContext.insert(oldTarget)
        sourceContainer.mainContext.insert(oldOwner)
        try sourceContainer.mainContext.save()
        let oldIDs = sourceContainer.schema.entityIDsByName
        let oldMapping = try XCTUnwrap(
            sourceContainer.schema.relationshipStorageMapping(
                modelEntityName: "InverseMigrationOwnerFixture", relationshipName: "target"))
        try sourceContainer.store?.close()

        let container = try ModelContainer(
            for: InverseMigrationOwnerFixture.self,
            InverseMigrationTargetBaseFixture.self,
            InverseMigrationTargetChildFixture.self,
            configurations: configuration)
        let newMapping = try XCTUnwrap(
            container.schema.relationshipStorageMapping(
                modelEntityName: "InverseMigrationOwnerFixture", relationshipName: "target"))
        XCTAssertEqual(oldMapping.storageColumnName, newMapping.storageColumnName)
        XCTAssertEqual(
            container.schema.entityIDsByName["InverseMigrationOwnerFixture"],
            oldIDs["InverseMigrationOwnerFixture"])
        XCTAssertEqual(
            container.schema.entityIDsByName["InverseMigrationTargetBaseFixture"],
            oldIDs["InverseMigrationTargetBaseFixture"])

        let reader = container.makeContext()
        let fetchedOldOwner = try XCTUnwrap(try reader.fetch(FetchDescriptor<InverseMigrationOwnerFixture>()).first)
        XCTAssertEqual(fetchedOldOwner.target?.name, "old target")
        let newTarget = InverseMigrationTargetChildFixture(name: "new target")
        let newOwner = InverseMigrationOwnerFixture(name: "new owner", target: newTarget)
        reader.insert(newTarget)
        reader.insert(newOwner)
        try reader.save()
        let freshReader = container.makeContext()
        let fetchedChild = try XCTUnwrap(
            try freshReader.fetch(FetchDescriptor<InverseMigrationTargetChildFixture>()).first)
        XCTAssertEqual(fetchedChild.owners.map(\.name), ["new owner"])
    }

    @MainActor
    func testHierarchyLifecycleRollbackUndoAndIdentity() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("hierarchy-lifecycle-undo"))
        let context = container.mainContext
        let grandchild = InheritanceMacroGrandchildFixture(name: "saved", age: 4, rank: 8)
        context.insert(grandchild)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager

        grandchild.rank = 10
        XCTAssertTrue(grandchild.hasChanges)
        context.rollback()
        XCTAssertEqual(grandchild.rank, 8)
        XCTAssertFalse(context.hasChanges)

        grandchild.rank = 11
        try context.save()
        undoManager.undo()
        XCTAssertEqual(grandchild.rank, 8)
        try context.save()
        undoManager.redo()
        XCTAssertEqual(grandchild.rank, 11)
        try context.save()

        let reader = container.makeContext()
        let fetchedAsBase: InheritanceMacroBaseFixture = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first)
        XCTAssertTrue(fetchedAsBase is InheritanceMacroGrandchildFixture)
        let fetchedAsGrandchild: InheritanceMacroGrandchildFixture = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritanceMacroGrandchildFixture>()).first)
        XCTAssertTrue(fetchedAsBase === fetchedAsGrandchild)
        XCTAssertEqual(fetchedAsGrandchild.rank, 11)

        let readerUndoManager = UndoManager()
        reader.undoManager = readerUndoManager
        reader.delete(fetchedAsGrandchild)
        try reader.save()
        XCTAssertTrue(readerUndoManager.canUndo)
        readerUndoManager.undo()
        let restored: InheritanceMacroBaseFixture = try XCTUnwrap(
            reader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first)
        XCTAssertTrue(restored is InheritanceMacroGrandchildFixture)
        XCTAssertEqual((restored as? InheritanceMacroGrandchildFixture)?.rank, 11)
    }

    @MainActor
    func testUndoDeletionRestoresHierarchySubtypeAndConcreteIdentity() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("hierarchy-delete-undo"))
        let context = container.mainContext
        let grandchild = InheritanceMacroGrandchildFixture(name: "saved", age: 4, rank: 8)
        context.insert(grandchild)
        try context.save()
        let originalPrimaryKey = try XCTUnwrap(grandchild.persistentModelID.primaryKey)
        let undoManager = UndoManager()
        context.undoManager = undoManager

        context.delete(grandchild)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).isEmpty)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()

        XCTAssertTrue(undoManager.canRedo)
        XCTAssertTrue(grandchild.modelContext === context)
        XCTAssertFalse(grandchild.isDeleted)
        XCTAssertTrue(context.insertedModels.contains { $0 === grandchild })
        let restoredBase = try XCTUnwrap(context.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first)
        let restoredGrandchild = try XCTUnwrap(restoredBase as? InheritanceMacroGrandchildFixture)
        XCTAssertTrue(restoredGrandchild === grandchild)
        XCTAssertEqual(restoredGrandchild.age, 4)
        XCTAssertEqual(restoredGrandchild.rank, 8)
        XCTAssertEqual(restoredGrandchild.persistentModelID.entityName, "InheritanceMacroGrandchildFixture")
        try context.save()

        undoManager.redo()
        XCTAssertTrue(grandchild.isDeleted)
        XCTAssertTrue(grandchild.modelContext === context)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).isEmpty)
        XCTAssertEqual(grandchild.persistentModelID.primaryKey, originalPrimaryKey)

        undoManager.undo()
        XCTAssertFalse(grandchild.isDeleted)
        XCTAssertTrue(grandchild.modelContext === context)
        XCTAssertTrue(context.insertedModels.contains { $0 === grandchild })
        try context.save()
        let restoredAgain = try XCTUnwrap(context.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first)
        XCTAssertTrue(restoredAgain is InheritanceMacroGrandchildFixture)
        XCTAssertEqual(restoredAgain.persistentModelID.primaryKey, originalPrimaryKey)
    }

    @MainActor
    func testUndoPendingHierarchyDeleteBeforeSave() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("hierarchy-pending-delete-undo"))
        let context = container.mainContext
        let grandchild = InheritanceMacroGrandchildFixture(name: "saved", age: 4, rank: 8)
        context.insert(grandchild)
        try context.save()
        context.undoManager = UndoManager()

        context.delete(grandchild)
        XCTAssertTrue(grandchild.isDeleted)
        XCTAssertTrue(context.hasChanges)
        context.undoManager?.undo()

        XCTAssertFalse(grandchild.isDeleted)
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(try XCTUnwrap(context.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first) === grandchild)
        try context.save()
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testHierarchySubtypeUndoRestoresMutationAndDelete() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("hierarchy-insert-undo"))
        let context = container.mainContext
        let grandchild = InheritanceMacroGrandchildFixture(name: "pending", age: 3, rank: 5)
        context.insert(grandchild)
        try context.save()
        let undoManager = UndoManager()
        context.undoManager = undoManager
        grandchild.rank = 6

        XCTAssertTrue(context.hasChanges)
        undoManager.undo()
        XCTAssertEqual(grandchild.rank, 5)
        try context.save()
        context.delete(grandchild)
        try context.save()
        undoManager.undo()
        try context.save()

        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()).first)
        XCTAssertTrue(restored is InheritanceMacroGrandchildFixture)
        XCTAssertEqual((restored as? InheritanceMacroGrandchildFixture)?.rank, 5)
        let rows = try container.store?.read {
            try $0.rows("SELECT Z_PK FROM ZINHERITANCEMACROBASEFIXTURE", arguments: [])
        }
        XCTAssertEqual(rows?.count, 1)
    }

    @MainActor
    func testHierarchyIdentifierLookupReusesExistingMaterializedModel() throws {
        let container = try ModelContainer(
            for: InheritanceLookupBaseFixture.self, InheritanceLookupChildFixture.self,
            configurations: .sqliteMemory("inheritance-identifier-existing"))
        let writer = container.mainContext
        writer.insert(InheritanceLookupChildFixture(name: "child", requiredValue: "required"))
        try writer.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritanceLookupBaseFixture>()).first)
        let identifier = fetched.persistentModelID
        let resolved: InheritanceLookupBaseFixture? = try reader.model(for: identifier)

        XCTAssertTrue(fetched === resolved)
        XCTAssertEqual((resolved as? InheritanceLookupChildFixture)?.requiredValue, "required")
    }

    @MainActor
    func testHierarchyExternalRefreshKeepsRootIdentityMapEntry() throws {
        let container = try ModelContainer(
            for: InheritanceLookupBaseFixture.self, InheritanceLookupChildFixture.self,
            configurations: .sqliteMemory("inheritance-external-refresh"))
        let writer = container.mainContext
        writer.insert(InheritanceLookupChildFixture(name: "before", requiredValue: "required"))
        try writer.save()

        let reader = container.makeContext()
        let registered = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritanceLookupBaseFixture>()).first)
        try reader.pollForExternalChanges()

        let writerChild = try XCTUnwrap(writer.fetch(FetchDescriptor<InheritanceLookupChildFixture>()).first)
        writerChild.name = "after"
        try writer.save()
        try reader.pollForExternalChanges()

        let fetchedAgain = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritanceLookupBaseFixture>()).first)
        XCTAssertTrue(registered === fetchedAgain)
        XCTAssertEqual(registered.name, "after")
    }

    @MainActor
    func testHierarchyPendingIdentifierFetchMatchesModelFetch() throws {
        let container = try ModelContainer(
            for: InheritanceLookupBaseFixture.self, InheritanceLookupChildFixture.self,
            configurations: .sqliteMemory("inheritance-pending-identifiers"))
        let writer = container.mainContext
        writer.insert(InheritanceLookupBaseFixture(name: "saved"))
        try writer.save()

        let reader = container.makeContext()
        reader.insert(InheritanceLookupChildFixture(name: "pending", requiredValue: "required"))
        let descriptor = FetchDescriptor<InheritanceLookupBaseFixture>(fetchLimit: 1)

        let modelIdentifiers = try reader.fetch(descriptor).map(\.persistentModelID)
        let identifiers = try reader.fetchIdentifiers(descriptor)

        XCTAssertEqual(identifiers, modelIdentifiers)
    }

    func testModelMacroProvidesPersistentModelConformance() {
        let model = MacroBackedFixture(title: "conformance")
        func requiresPersistentModel<T: PersistentModel>(_ value: T) {}
        requiresPersistentModel(model)

        XCTAssertEqual(model.title, "conformance")
    }

    func testModelMacroProvidesRuntimeBackedGroupedBindingFixtureProperties() {
        let model = GroupedBindingFixture()

        XCTAssertEqual(model.first, 0)
        XCTAssertEqual(model.second, 0)
        XCTAssertEqual(GroupedBindingFixture.schemaMetadata().map(\.name), ["first", "second"])

        model.first = 11
        model.second = 22
        XCTAssertEqual(model.first, 11)
        XCTAssertEqual(model.second, 22)
    }

    func testModelMacroProvidesUncheckedSendableConformance() {
        let model = MacroBackedFixture(title: "sendable")
        func requiresSendable<T: Sendable>(_ value: T) {}
        requiresSendable(model)
    }

    func testUnassignedNonoptionalPropertyReadTerminatesWithExactMessage() throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["OpenSwiftDataTests.PersistentModelTests/testRunUnassignedPropertyChild"]
        var environment = ProcessInfo.processInfo.environment
        environment["OSD_UNASSIGNED_PROPERTY_CHILD"] = "1"
        process.environment = environment
        process.standardError = standardError

        try process.run()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(
            String(decoding: errorOutput, as: UTF8.self)
                .contains("Fatal error: OSD: property 'title' of UnassignedPropertyFixture was read before assignment")
        )
    }

    func testRunUnassignedPropertyChild() throws {
        guard ProcessInfo.processInfo.environment["OSD_UNASSIGNED_PROPERTY_CHILD"] == "1" else {
            throw XCTSkip("Child-only crash test")
        }
        _ = UnassignedPropertyFixture().title
    }

    func testBackingDataInitializerPreservesDeclaredDefaults() {
        let backingData = BackingDataDefaultsFixture.createBackingData()
        let model = BackingDataDefaultsFixture(backingData: backingData)

        XCTAssertEqual(model.count, 5)
        XCTAssertEqual(model.optionalDefault, "default")
        XCTAssertNil(model.explicitlyNil)
    }

    func testModelMacroProvidesRuntimeBackedAccessors() {
        let model = MacroBackedFixture(title: "initial")

        XCTAssertEqual(model.title, "initial")
        XCTAssertEqual(model.count, 3)
        XCTAssertNil(model.note)
        XCTAssertEqual(model.defaultedNote, "default")
        XCTAssertNil(model.explicitlyNil)

        model.title = "updated"
        XCTAssertEqual(model.title, "updated")

        let replacement = MacroBackedFixture.createBackingData()
        replacement.setValue(forKey: \.title, to: "replacement")
        model.persistentBackingData = replacement

        XCTAssertEqual(model.title, "replacement")
        XCTAssertTrue(model.persistentBackingData === replacement)
    }

    @MainActor
    func testGeneratedScalarSetterTracksManagedMutation() throws {
        let model = MacroBackedFixture(title: "before")
        let container = try ModelContainer(
            for: MacroBackedFixture.self, configurations: .sqliteMemory("scalar-setter"))
        container.mainContext.insert(model)
        try container.mainContext.save()

        model.title = "after"

        XCTAssertEqual(model.title, "after")
        XCTAssertTrue(container.mainContext.changedModelsArray.contains { $0 === model })
    }
}
