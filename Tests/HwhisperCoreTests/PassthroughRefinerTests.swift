import Testing
@testable import HwhisperCore

struct PassthroughRefinerTests {
    @Test
    func returnsTextUnmodified() async throws {
        let refiner = PassthroughRefiner()
        let result = try await refiner.refine("um so, hello", context: RefinementContext())
        #expect(result == "um so, hello")
    }
}
