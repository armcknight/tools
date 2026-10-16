import Foundation
import Testing

@Suite("prepare-release")
struct PrepareReleaseTests {
    let repo: GitFixture

    init() throws {
        repo = try GitFixture(files: [
            "VERSION": "1.1.0\n",
            "CHANGELOG.md": """
            # Changelog

            ## [Unreleased]

            ### Added
            - New feature

            ## [1.0.0] 2024-01-01

            ### Added
            - Initial release

            """,
        ])
    }

    @Test func failsWithoutChangesWhenBehindUpstream() async throws {
        try repo.pushTeammateCommit()

        let result = try await prepareRelease()

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("origin/main has 1 commit that HEAD does not"))
        #expect(try repo.git(["-C", repo.releaser, "status", "--porcelain"]).isEmpty)
        #expect(try repo.git(["-C", repo.releaser, "tag"]).isEmpty)
    }

    @Test func releasesWhenUpToDate() async throws {
        let result = try await prepareRelease()

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(try repo.git(["-C", repo.remote, "tag"]) == "1.1.0")
    }

    @Test func failsWithoutUpstream() async throws {
        try repo.git(["-C", repo.releaser, "branch", "--quiet", "--unset-upstream"])

        let result = try await prepareRelease()

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("no upstream"))
        #expect(try repo.git(["-C", repo.releaser, "tag"]).isEmpty)
    }
}

private extension PrepareReleaseTests {
    func prepareRelease() async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await ToolRunner.run("prepare-release", arguments: ["--file", "VERSION", "--push"], workingDirectory: repo.releaser)
    }
}
