import ArgumentParser
import Foundation
import Shared

@main
struct UploadSymbols: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload dSYM files to Sentry.",
        discussion: "Resolves Sentry credentials from environment variables, .sentryclirc, or .env file. Designed for use as an Xcode Run Script build phase.",
        version: toolsVersion
    )

    @Option(help: "Build configuration (reads from CONFIGURATION env var if not provided).")
    var configuration: String?

    @Option(help: "Path to the dSYM folder (reads from DWARF_DSYM_FOLDER_PATH env var if not provided).")
    var dsymPath: String?

    @Option(help: "Project directory (reads from PROJECT_DIR env var if not provided).")
    var projectDir: String?

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = configuration ?? env["CONFIGURATION"] ?? ""

        if config == "Testing" {
            print("Skipping symbol upload during test build")
            return
        }

        // Verify sentry-cli is installed
        let whichResult = await Shell.runOptional("which", arguments: ["sentry-cli"])
        guard whichResult.success else {
            throw UploadSymbolsError.sentryCLINotFound
        }

        let projDir = projectDir ?? env["PROJECT_DIR"] ?? "."

        // Resolve credentials
        let org = try resolveConfig(key: "SENTRY_ORG", envVar: "SENTRY_ORG", projDir: projDir)
        let project = try resolveConfig(key: "SENTRY_PROJECT", envVar: "SENTRY_PROJECT", projDir: projDir)
        let authToken = try resolveAuthToken(projDir: projDir)

        let dsymFolder = dsymPath ?? env["DWARF_DSYM_FOLDER_PATH"]
        guard let dsymFolder else {
            throw UploadSymbolsError.missingDsymPath
        }

        try await Shell.run("sentry-cli", arguments: [
            "upload-dif",
            "--force-foreground",
            "--include-sources",
            "-o", org,
            "-p", project,
            "--auth-token", authToken,
            dsymFolder,
        ])

        print("Symbols uploaded successfully.")
    }

    private func resolveConfig(key: String, envVar: String, projDir: String) throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let value = env[envVar], !value.isEmpty { return value }

        let dotenvPath = "\(projDir)/.env"
        if let value = readFromDotenv(key: key, path: dotenvPath) { return value }

        throw UploadSymbolsError.missingConfig(key)
    }

    private func resolveAuthToken(projDir: String) throws -> String {
        let env = ProcessInfo.processInfo.environment

        if let value = env["SENTRY_AUTH_TOKEN"], !value.isEmpty { return value }

        // Try .sentryclirc
        let rcPath = NSHomeDirectory() + "/.sentryclirc"
        if FileManager.default.fileExists(atPath: rcPath),
           let content = try? FileHelpers.read(rcPath) {
            for line in content.components(separatedBy: "\n") {
                if line.hasPrefix("token=") {
                    return String(line.dropFirst("token=".count))
                }
            }
        }

        // Try .env
        let dotenvPath = "\(projDir)/.env"
        if let value = readFromDotenv(key: "SENTRY_AUTH_TOKEN", path: dotenvPath) { return value }

        throw UploadSymbolsError.missingConfig("SENTRY_AUTH_TOKEN")
    }

    private func readFromDotenv(key: String, path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let content = try? FileHelpers.read(path) else { return nil }
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("\(key)=") {
                return String(line.dropFirst("\(key)=".count))
            }
        }
        return nil
    }
}

enum UploadSymbolsError: LocalizedError {
    case sentryCLINotFound
    case missingDsymPath
    case missingConfig(String)

    var errorDescription: String? {
        switch self {
        case .sentryCLINotFound:
            return "sentry-cli not installed. Download from https://github.com/getsentry/sentry-cli/releases"
        case .missingDsymPath:
            return "No dSYM path provided. Set --dsym-path or run from an Xcode build phase (DWARF_DSYM_FOLDER_PATH)."
        case .missingConfig(let key):
            return "Missing \(key). Provide via environment variable, .sentryclirc, or .env file."
        }
    }
}
