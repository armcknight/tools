import Foundation
import Testing

@Suite("migrate-changelog")
struct MigrateChangelogTests {
    let tmpDir: String

    init() throws {
        tmpDir = try makeTempDir()
        // Initialize a git repo so the tool can operate
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", tmpDir]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // Configure git user for commits
        for (key, value) in [("user.name", "Test"), ("user.email", "test@test.com")] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tmpDir, "config", key, value]
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
    }

    @Test func migrateUnreleasedSection() async throws {
        let changelog = """
        # Changelog

        ## [Unreleased]

        ### Added
        - New feature

        ## [1.0.0] 2024-01-01

        ### Added
        - Initial release
        """
        let path = "\(tmpDir)/CHANGELOG.md"
        try changelog.write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run(
            "migrate-changelog",
            arguments: [path, "1.1.0", "--no-commit"]
        )
        #expect(result.exitCode == 0)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("## [Unreleased]"))
        #expect(content.contains("## [1.1.0]"))
        #expect(content.contains("### Added"))
    }

    @Test func migrateWithCommit() async throws {
        let changelog = """
        # Changelog

        ## [Unreleased]

        ### Fixed
        - Bug fix
        """
        let path = "\(tmpDir)/CHANGELOG.md"
        try changelog.write(toFile: path, atomically: true, encoding: .utf8)

        // Stage and commit the initial file so working tree is clean
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        add.arguments = ["-C", tmpDir, "add", "."]
        add.standardOutput = FileHandle.nullDevice
        try add.run()
        add.waitUntilExit()

        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commit.arguments = ["-C", tmpDir, "commit", "-m", "initial", "--no-gpg-sign"]
        commit.standardOutput = FileHandle.nullDevice
        commit.standardError = FileHandle.nullDevice
        try commit.run()
        commit.waitUntilExit()

        let result = try await ToolRunner.run(
            "migrate-changelog",
            arguments: [path, "2.0.0"],
            workingDirectory: tmpDir
        )
        #expect(result.exitCode == 0)

        // Verify a git commit was created
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        log.arguments = ["-C", tmpDir, "log", "--oneline", "-1"]
        let pipe = Pipe()
        log.standardOutput = pipe
        try log.run()
        log.waitUntilExit()
        let logOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(logOutput.contains("2.0.0"))
    }

    @Test func failsWithoutUnreleasedSection() async throws {
        let path = "\(tmpDir)/CHANGELOG.md"
        try "# Changelog\n\n## [1.0.0] 2024-01-01\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run(
            "migrate-changelog",
            arguments: [path, "1.1.0", "--no-commit"]
        )
        #expect(result.exitCode != 0)
    }
}
