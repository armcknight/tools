import Foundation
import Subprocess
import System

/// Helpers for reading and writing plist files.
public enum Plist {
    /// Read a value from a plist file using PlistBuddy.
    public static func read(key: String, from path: String) async throws -> String {
        let result = try await Subprocess.run(
            .path(FilePath("/usr/libexec/PlistBuddy")),
            arguments: ["-c", "Print :\(key)", path],
            output: .string(limit: Shell.defaultMaxOutput)
        )
        guard result.terminationStatus.isSuccess else {
            throw PlistError.readFailed(key: key, path: path)
        }
        return result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Set a value in a plist file, creating the key if it doesn't exist.
    public static func set(key: String, value: String, in path: String) async throws {
        let setResult = try await Subprocess.run(
            .path(FilePath("/usr/libexec/PlistBuddy")),
            arguments: ["-c", "Set :\(key) \(value)", path],
            output: .string(limit: Shell.defaultMaxOutput)
        )
        if !setResult.terminationStatus.isSuccess {
            let addResult = try await Subprocess.run(
                .path(FilePath("/usr/libexec/PlistBuddy")),
                arguments: ["-c", "Add :\(key) string \(value)", path],
                output: .string(limit: Shell.defaultMaxOutput)
            )
            guard addResult.terminationStatus.isSuccess else {
                throw PlistError.writeFailed(key: key, path: path)
            }
        }
    }

    /// Read a plist as a dictionary.
    public static func readDictionary(from path: String) -> NSDictionary? {
        return NSDictionary(contentsOfFile: path)
    }

    /// Write a dictionary to a plist file.
    public static func writeDictionary(_ dict: NSDictionary, to path: String) -> Bool {
        return dict.write(toFile: path, atomically: true)
    }
}

public enum PlistError: LocalizedError {
    case readFailed(key: String, path: String)
    case writeFailed(key: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let key, let path):
            return "Failed to read key '\(key)' from plist: \(path)"
        case .writeFailed(let key, let path):
            return "Failed to write key '\(key)' to plist: \(path)"
        }
    }
}
