import Foundation
import Observation
import XCTest
@testable import OpenSwiftData
import OSDTestSupport

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
final class InheritedToOneTargetFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
class InheritedToOneBaseFixture {
    @Relationship(inverse: nil) var target: InheritedToOneTargetFixture?
    init(target: InheritedToOneTargetFixture?) { self.target = target }
}

@Model
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
        let pendingContains = FetchDescriptor<HierarchyToHierarchyOwnerChildFixture>(
            predicate: #Predicate { $0.target?.name.contains(pendingString) == true })
        let pendingContainedOwners = try context.fetch(pendingContains)
        XCTAssertEqual(pendingContainedOwners.map(\.name), ["matched"])
        XCTAssertEqual(try context.fetchCount(pendingContains), 1)
        XCTAssertEqual(try context.fetchIdentifiers(pendingContains), pendingContainedOwners.map(\.persistentModelID))

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
        XCTAssertEqual(try context.fetch(descriptor).map(\.name), ["two"])
        XCTAssertEqual(try context.fetchCount(descriptor), 1)

        let minimumCount = 2
        let minimumDescriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.count >= minimumCount },
            includePendingChanges: false)
        XCTAssertEqual(try context.fetch(minimumDescriptor).map(\.name), ["two"])
        XCTAssertEqual(try context.fetchCount(minimumDescriptor), 1)

        one.items.append(second)
        let pendingDescriptor = FetchDescriptor<NestedToManyMiddleFixture>(
            predicate: #Predicate { $0.items.count == expectedCount })
        XCTAssertEqual(Set(try context.fetch(pendingDescriptor).map(\.name)), ["one", "two"])
        XCTAssertEqual(try context.fetchCount(pendingDescriptor), 2)
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
        let projectedChildren = try reader.fetch(
            FetchDescriptor<InheritanceMacroChildFixture>(
                propertiesToFetch: [\InheritanceMacroChildFixture.name]))
        XCTAssertEqual(projectedChildren.map(\.name), ["child", "grandchild"])

        let grandchildPredicate = #Predicate<InheritanceMacroGrandchildFixture> {
            $0.name == "grandchild" || $0.rank == 4
        }
        let grandchildModels = try reader.fetch(FetchDescriptor(predicate: grandchildPredicate))
        XCTAssertEqual(grandchildModels.map(\.name), ["grandchild"])

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
