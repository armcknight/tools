import ArgumentParser
import Foundation
import Shared

@main
struct Psst: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inject secrets into source file placeholders.",
        version: toolsVersion
    )

    @Argument(help: "Optional path to a macOS keychain file.")
    var keychainPath: String?

    func run() async throws {
        guard FileManager.default.fileExists(atPath: ".git") else {
            throw PsstError.notInRepoRoot
        }

        let keysPath = ".psst/keys"
        let valuesPath = ".psst/values"

        guard FileManager.default.fileExists(atPath: keysPath) else {
            throw PsstError.noKeysFile
        }

        let keysContent = try FileHelpers.read(keysPath)
        let keys = keysContent.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.components(separatedBy: " ").first ?? $0 }
            .filter { !$0.isEmpty }

        for key in keys {
            guard let value = try await resolveValue(for: key, valuesPath: valuesPath) else {
                throw PsstError.noValue(key)
            }

            // Find files containing this key
            let result = await Shell.runOptional("grep", arguments: [
                "--recursive", "--files-with-matches", "--exclude-dir=.psst", key, "."
            ])

            let files = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }

            for file in files {
                if file == valuesPath { continue }
                try FileHelpers.replaceInFile(file, target: key, replacement: value)
            }
        }

        print("Secrets injected successfully.")
    }

    private func resolveValue(for key: String, valuesPath: String) async throws -> String? {
        // 1. Try .psst/values file
        if FileManager.default.fileExists(atPath: valuesPath) {
            let content = try FileHelpers.read(valuesPath)
            for line in content.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " ")
                if parts.count >= 2 && parts[0] == key {
                    return parts.dropFirst().joined(separator: " ")
                }
            }
        }

        // 2. Try environment variable
        if let envValue = ProcessInfo.processInfo.environment[key] {
            return envValue
        }

        // 3. Try macOS Keychain
        if let keychainPath, FileManager.default.fileExists(atPath: keychainPath) {
            let result = await Shell.runOptional("security", arguments: [
                "find-generic-password", "-ga", key, "-w", keychainPath
            ])
            if result.success && !result.output.isEmpty {
                return result.output
            }
        }

        return nil
    }
}

enum PsstError: LocalizedError {
    case notInRepoRoot
    case noKeysFile
    case noValue(String)

    var errorDescription: String? {
        switch self {
        case .notInRepoRoot:
            return "Must be run from the root directory of a git repository."
        case .noKeysFile:
            return "No .psst/keys file found."
        case .noValue(let key):
            return "No value found for key '\(key)'. Provide it in .psst/values, an environment variable, or a keychain."
        }
    }
}
