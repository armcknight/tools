import Testing
@testable import Shared

@Suite("Version")
struct VersionTests {
    @Test func versionIsSet() {
        #expect(!toolsVersion.isEmpty)
        #expect(toolsVersion.contains("."))
    }
}
