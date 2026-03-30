import Foundation
import Subprocess
import System

/// Helper to run built tool binaries in tests.
enum ToolRunner {
    /// Path to the build products directory.
    /// Derives it from the source file location.
    static var buildDir: String {
        // #filePath gives us Tests/IntegrationTests/ToolRunner.swift
        // Go up 3 levels to get the package root, then into .build/debug
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent()  // IntegrationTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        return packageRoot.appendingPathComponent(".build/debug").path
    }

    /// Run a tool binary and return (exitCode, stdout, stderr).
    static func run(
        _ tool: String,
        arguments: [String] = [],
        workingDirectory: String? = nil
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let toolPath = "\(buildDir)/\(tool)"

        let result = try await Subprocess.run(
            .path(FilePath(toolPath)),
            arguments: Arguments(arguments),
            workingDirectory: workingDirectory.map { FilePath($0) },
            output: .string(limit: 16 * 1024 * 1024),
            error: .string(limit: 16 * 1024 * 1024)
        )

        let stdout = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = result.standardError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let exitCode: Int32
        switch result.terminationStatus {
        case .exited(let code):
            exitCode = code
        case .signaled(let sig):
            exitCode = sig
        }

        return (exitCode, stdout, stderr)
    }
}

/// Create a temporary directory for a test, returning the path.
func makeTempDir() throws -> String {
    let path = NSTemporaryDirectory() + "tools-integration-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}
