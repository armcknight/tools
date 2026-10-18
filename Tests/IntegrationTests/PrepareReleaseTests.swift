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

/// Two tag families in one repository: the main one releases from `VERSION` and
/// `CHANGELOG.md` as bare tags (`1.1.0`); the components release from
/// `components/VERSION` and `components/CHANGELOG.md` as `v`-prefixed tags (`v1.1.0`).
@Suite("prepare-release --tag-prefix")
struct PrepareReleaseTagPrefixTests {
    @Test func releasesWithPrefixedTag() async throws {
        let repo = try fixture()

        let result = try await prepareComponents(repo)

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "v1.1.0")
        #expect(try repo.git(["-C", repo.remote, "tag"]) == "v1.1.0")
        #expect(try repo.git(["-C", repo.releaser, "log", "-1", "--format=%s"]) == "tag release v1.1.0")
        let changelog = try String(contentsOfFile: "\(repo.releaser)/components/CHANGELOG.md", encoding: .utf8)
        #expect(changelog.contains("## [v1.1.0]"))
        #expect(!changelog.contains("## [1.1.0]"))
    }

    @Test func releasesCandidateWithPrefixedTag() async throws {
        let repo = try fixture()

        let result = try await prepareComponents(repo, rc: true)

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(try repo.git(["-C", repo.remote, "tag"]) == "v1.1.0-RC1")
        #expect(try repo.git(["-C", repo.releaser, "log", "-1", "--format=%s"]) == "tag release candidate v1.1.0-RC1")
        let changelog = try String(contentsOfFile: "\(repo.releaser)/components/CHANGELOG.md", encoding: .utf8)
        #expect(changelog.contains("## [v1.1.0-RC1]"))
    }

    @Test func numbersAndConsolidatesPrefixedCandidates() async throws {
        let repo = try fixture(componentsChangelog: """
            # Changelog

            ## [Unreleased]

            ### Fixed
            - Second RC fix

            ## [v1.1.0-RC1] 2024-02-01

            ### Added
            - First RC feature

            ## [v1.0.0] 2024-01-01

            ### Added
            - Initial component release

            """)

        let rc = try await prepareComponents(repo, rc: true)
        #expect(rc.exitCode == 0, "\(rc.stderr)")
        #expect(try repo.git(["-C", repo.remote, "tag"]) == "v1.1.0-RC2")

        let release = try await prepareComponents(repo)
        #expect(release.exitCode == 0, "\(release.stderr)")
        #expect(try repo.git(["-C", repo.remote, "tag", "--list", "v1.1.0"]) == "v1.1.0")
        let changelog = try String(contentsOfFile: "\(repo.releaser)/components/CHANGELOG.md", encoding: .utf8)
        #expect(changelog.contains("## [v1.1.0]"))
        #expect(!changelog.contains("-RC"))
        #expect(changelog.contains("- First RC feature"))
        #expect(changelog.contains("- Second RC fix"))
    }

    @Test func failsWhenPrefixedVersionWasNotBumped() async throws {
        let repo = try fixture(componentsVersion: "1.0.0\n")

        let result = try await prepareComponents(repo)

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Version 1.0.0 was already released"))
        #expect(try repo.git(["-C", repo.releaser, "tag"]).isEmpty)
    }

    @Test func familiesDoNotReadEachOthersSections() async throws {
        let repo = try fixture()

        let components = try await prepareComponents(repo)
        #expect(components.exitCode == 0, "\(components.stderr)")

        let main = try await ToolRunner.run("prepare-release", arguments: ["--file", "VERSION", "--push"], workingDirectory: repo.releaser)
        #expect(main.exitCode == 0, "\(main.stderr)")

        #expect(try repo.git(["-C", repo.remote, "tag"]) == "1.1.0\nv1.1.0")
        let mainChangelog = try String(contentsOfFile: "\(repo.releaser)/CHANGELOG.md", encoding: .utf8)
        #expect(mainChangelog.contains("## [1.1.0]"))
        #expect(!mainChangelog.contains("[v1.1.0]"))
        let componentsChangelog = try String(contentsOfFile: "\(repo.releaser)/components/CHANGELOG.md", encoding: .utf8)
        #expect(componentsChangelog.contains("## [v1.1.0]"))
        #expect(!componentsChangelog.contains("[1.1.0]"))
    }
}

private extension PrepareReleaseTagPrefixTests {
    func fixture(componentsVersion: String = "1.1.0\n", componentsChangelog: String? = nil) throws -> GitFixture {
        try GitFixture(files: [
            "VERSION": "1.1.0\n",
            "CHANGELOG.md": """
            # Changelog

            ## [Unreleased]

            ### Added
            - New command feature

            ## [1.0.0] 2024-01-01

            ### Added
            - Initial command release

            """,
            "components/VERSION": componentsVersion,
            "components/CHANGELOG.md": componentsChangelog ?? """
            # Changelog

            ## [Unreleased]

            ### Added
            - New component

            ## [v1.0.0] 2024-01-01

            ### Added
            - Initial component release

            """,
        ])
    }

    func prepareComponents(_ repo: GitFixture, rc: Bool = false) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let arguments = (rc ? ["rc"] : []) + [
            "--file", "components/VERSION",
            "--changelog", "components/CHANGELOG.md",
            "--tag-prefix", "v",
            "--push",
        ]
        return try await ToolRunner.run("prepare-release", arguments: arguments, workingDirectory: repo.releaser)
    }
}
