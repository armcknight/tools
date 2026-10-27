import Testing
@testable import Shared

@Suite("Version")
struct VersionTests {
    @Test func versionIsSet() {
        #expect(!toolsVersion.isEmpty)
        #expect(toolsVersion.contains("."))
    }

     func fullVersionStartsWithTheVersion() {
        // Without `make install`'s generated metadata, the two are the same.
        #expect(toolsFullVersion.hasPrefix(toolsVersion))
    }
}
