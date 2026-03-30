import Foundation
import Subprocess
import System

/// Convenience wrapper around swift-subprocess for common patterns.
public enum Shell {
    /// Default max output size (16 MB).
    public static let defaultMaxOutput = 16 * 1024 * 1024

    /// Run a command by name (resolved via PATH) and return trimmed stdout. Throws on non-zero exit.
    @discardableResult
    public static func run(_ executable: String, arguments: [String] = [], workingDirectory: String? = nil) async throws -> String {
        let result: ExecutionRecord<StringOutput<UTF8>, DiscardedOutput>
        if let dir = workingDirectory {
            result = try await Subprocess.run(
                .name(executable),
                arguments: Arguments(arguments),
                workingDirectory: FilePath(dir),
                output: .string(limit: defaultMaxOutput)
            )
        } else {
            result = try await Subprocess.run(
                .name(executable),
                arguments: Arguments(arguments),
                output: .string(limit: defaultMaxOutput)
            )
        }

        guard result.terminationStatus.isSuccess else {
            throw ShellError.nonZeroExit(
                command: ([executable] + arguments).joined(separator: " "),
                output: result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }

        return result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Run a command and return (isSuccess, stdout) without throwing.
    public static func runOptional(_ executable: String, arguments: [String] = []) async -> (success: Bool, output: String) {
        do {
            let result = try await Subprocess.run(
                .name(executable),
                arguments: Arguments(arguments),
                output: .string(limit: defaultMaxOutput)
            )
            return (result.terminationStatus.isSuccess, result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } catch {
            return (false, "")
        }
    }
}

public enum ShellError: LocalizedError {
    case nonZeroExit(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(let command, let output):
            return "Command '\(command)' failed: \(output)"
        }
    }
}
