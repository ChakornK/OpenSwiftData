import Testing
import OpenSwiftData

@Suite struct UnassignedPropertyExitTests {
    @Test func `reading an unassigned non-optional property terminates with the exact message`() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = UnassignedPropertyFixture().title
        }
        let output = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(output.contains("OSD: property 'title' of UnassignedPropertyFixture was read before assignment"))
    }
}
