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

@Suite("prepare-release after an RC cycle")
struct PrepareReleaseAfterRCTests {
    @Test func consolidatesRCsWhenUnreleasedIsEmpty() async throws {
        let repo = try fixture(unreleased: "")

        let result = try await prepareRelease(repo)

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(try repo.git(["-C", repo.remote, "tag"]) == "1.1.0")
        let changelog = try String(contentsOfFile: "\(repo.releaser)/CHANGELOG.md", encoding: .utf8)
        #expect(changelog.contains("## [1.1.0]"))
        #expect(!changelog.contains("-RC"))
        #expect(changelog.contains("- First RC feature"))
        #expect(changelog.contains("- Second RC fix"))
    }

    @Test func failsWithoutChangesWhenUnreleasedHasUntestedEntries() async throws {
        let repo = try fixture(unreleased: "### Added\n- Untested feature\n")

        let result = try await prepareRelease(repo)

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("no release candidate tested"))
        #expect(try repo.git(["-C", repo.releaser, "status", "--porcelain"]).isEmpty)
        #expect(try repo.git(["-C", repo.releaser, "tag"]).isEmpty)
    }

    @Test func rcStillRequiresUnreleasedEntries() async throws {
        let repo = try fixture(unreleased: "")

        let result = try await ToolRunner.run("prepare-release", arguments: ["rc", "--file", "VERSION", "--push"], workingDirectory: repo.releaser)

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("[Unreleased] section is empty"))
        #expect(try repo.git(["-C", repo.releaser, "tag"]).isEmpty)
    }
}

private extension PrepareReleaseAfterRCTests {
    func fixture(unreleased: String) throws -> GitFixture {
        try GitFixture(files: [
            "VERSION": "1.1.0\n",
            "CHANGELOG.md": """
            # Changelog

            ## [Unreleased]

            \(unreleased)
            ## [1.1.0-RC2] 2024-02-02

            ### Fixed
            - Second RC fix

            ## [1.1.0-RC1] 2024-02-01

            ### Added
            - First RC feature

            ## [1.0.0] 2024-01-01

            ### Added
            - Initial release

            """,
        ])
    }

    func prepareRelease(_ repo: GitFixture) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await ToolRunner.run("prepare-release", arguments: ["--file", "VERSION", "--push"], workingDirectory: repo.releaser)
    }
}
