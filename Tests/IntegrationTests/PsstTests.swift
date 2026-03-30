import Foundation
import Testing

@Suite("psst")
struct PsstTests {
    let tmpDir: String

    init() throws {
        tmpDir = try makeTempDir()
        // Initialize a git repo (psst requires .git)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", tmpDir]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test func injectFromValuesFile() async throws {
        // Set up .psst/keys and .psst/values
        let psstDir = "\(tmpDir)/.psst"
        try FileManager.default.createDirectory(atPath: psstDir, withIntermediateDirectories: true)
        try "MY_SECRET\n".write(toFile: "\(psstDir)/keys", atomically: true, encoding: .utf8)
        try "MY_SECRET actual_value\n".write(toFile: "\(psstDir)/values", atomically: true, encoding: .utf8)

        // Create a file with the placeholder
        try "api_key = MY_SECRET\n".write(toFile: "\(tmpDir)/config.txt", atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("psst", workingDirectory: tmpDir)
        #expect(result.exitCode == 0)

        let content = try String(contentsOfFile: "\(tmpDir)/config.txt", encoding: .utf8)
        #expect(content.contains("actual_value"))
        #expect(!content.contains("MY_SECRET"))
    }

    @Test func failsOutsideGitRepo() async throws {
        let nonGitDir = try makeTempDir()
        // No .git directory

        // Need at least a keys file to avoid that error first
        let psstDir = "\(nonGitDir)/.psst"
        try FileManager.default.createDirectory(atPath: psstDir, withIntermediateDirectories: true)
        try "KEY\n".write(toFile: "\(psstDir)/keys", atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("psst", workingDirectory: nonGitDir)
        #expect(result.exitCode != 0)
    }

    @Test func failsWithMissingKeys() async throws {
        // No .psst/keys file
        let result = try await ToolRunner.run("psst", workingDirectory: tmpDir)
        #expect(result.exitCode != 0)
    }
}
