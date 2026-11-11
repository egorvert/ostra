import Testing
@testable import T3Bridge

@Suite struct T3ConfigurationTests {
    @Test func defaultsPinTheRelease() {
        #expect(T3Configuration().version == "0.1.8")
    }
}
