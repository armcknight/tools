import Foundation
import Testing

@Suite("check-release-ready")
struct CheckReleaseReadyTests {
    let repo: GitFixture

    init() throws {
        repo = try GitFixture(files: ["README": "hello\n"])
    }

    @Test func passesWhenCleanAndUpToDate() async throws {
        let result = try await checkReleaseReady(["--branch", "main"])
        #expect(result.exitCode == 0, "\(result.stderr)")
    }

    @Test func failsWhenBehindUpstream() async throws {
        try repo.pushTeammateCommit()

        let result = try await checkReleaseReady([])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("origin/main has 1 commit that HEAD does not"))
    }

    @Test func failsWithUncommittedChanges() async throws {
        try "changed\n".write(toFile: "\(repo.releaser)/README", atomically: true, encoding: .utf8)

        let result = try await checkReleaseReady([])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("working tree has changes"))
    }

    @Test func failsWithUntrackedFiles() async throws {
        try "new\n".write(toFile: "\(repo.releaser)/NEW", atomically: true, encoding: .utf8)

        let result = try await checkReleaseReady([])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("?? NEW"))
    }

    @Test func failsOnWrongBranch() async throws {
        try repo.git(["-C", repo.releaser, "switch", "--quiet", "-c", "feature"])

        let result = try await checkReleaseReady(["--branch", "main"])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("HEAD is on 'feature', not 'main'"))
    }

    @Test func failsWithoutUpstream() async throws {
        try repo.git(["-C", repo.releaser, "branch", "--quiet", "--unset-upstream"])

        let result = try await checkReleaseReady([])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("no upstream"))
    }
}

private extension CheckReleaseReadyTests {
    func checkReleaseReady(_ arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await ToolRunner.run("check-release-ready", arguments: arguments, workingDirectory: repo.releaser)
    }
}
