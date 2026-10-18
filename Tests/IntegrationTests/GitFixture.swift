import Foundation
import Testing

/// A bare remote with two clones of it: `releaser` (the checkout under test) and
/// `teammate` (pushes commits the releaser does not have yet).
struct GitFixture {
    let remote: String
    let releaser: String
    let teammate: String

    init(files: [String: String]) throws {
        let tmpDir = try makeTempDir()
        remote = "\(tmpDir)/remote.git"
        releaser = "\(tmpDir)/releaser"
        teammate = "\(tmpDir)/teammate"

        try git(["init", "--bare", "--initial-branch=main", remote])
        try git(["clone", "--quiet", remote, releaser])
        try configureUser(releaser)
        for (name, contents) in files {
            let directory = URL(fileURLWithPath: "\(releaser)/\(name)").deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(toFile: "\(releaser)/\(name)", atomically: true, encoding: .utf8)
        }
        try git(["-C", releaser, "add", "."])
        try git(["-C", releaser, "commit", "--quiet", "-m", "initial"])
        try git(["-C", releaser, "push", "--quiet", "-u", "origin", "main"])

        try git(["clone", "--quiet", remote, teammate])
        try configureUser(teammate)
    }

    /// Commits a new file in `teammate` and pushes it, putting `releaser` one commit behind.
    func pushTeammateCommit() throws {
        try "teammate\n".write(toFile: "\(teammate)/NOTES", atomically: true, encoding: .utf8)
        try git(["-C", teammate, "add", "."])
        try git(["-C", teammate, "commit", "--quiet", "-m", "teammate change"])
        try git(["-C", teammate, "push", "--quiet"])
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension GitFixture {
    func configureUser(_ repo: String) throws {
        try git(["-C", repo, "config", "user.name", "Test"])
        try git(["-C", repo, "config", "user.email", "test@test.com"])
        try git(["-C", repo, "config", "commit.gpgsign", "false"])
        try git(["-C", repo, "config", "tag.gpgsign", "false"])
    }
}
