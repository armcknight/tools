import ArgumentParser
import Foundation
import GitKit
import Shared

@main
struct InjectGitInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inject git metadata into Info.plist at build time.",
        discussion: "Writes GIT_COMMIT_HASH, GIT_BRANCH, and GIT_STATUS_CLEAN into the target's built Info.plist. Designed for use as an Xcode Run Script build phase."
    )

    @Option(help: "Build configuration (reads from CONFIGURATION env var if not provided).")
    var configuration: String?

    @Option(help: "Path to the built Info.plist (reads from TARGET_BUILD_DIR/INFOPLIST_PATH env vars if not provided).")
    var plistPath: String?

    @Option(help: "Project directory for git operations (reads from PROJECT_DIR env var if not provided).")
    var projectDir: String?

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = configuration ?? env["CONFIGURATION"] ?? ""
        let projectDirectory = projectDir ?? env["PROJECT_DIR"] ?? "."

        if config == "Testing" {
            print("Skipping git info injection during test build")
            return
        }

        let plist: String
        if let provided = plistPath {
            plist = provided
        } else if let buildDir = env["TARGET_BUILD_DIR"], let infoPlistPath = env["INFOPLIST_PATH"] {
            plist = "\(buildDir)/\(infoPlistPath)"
        } else {
            throw InjectGitInfoError.missingPlistPath
        }

        let git = Git(path: projectDirectory)
        let commitHash = try git.run(.raw("rev-parse --short HEAD"))
        let branch = try git.run(.revParse(abbrevRef: true, revision: "HEAD"))
        let statusOutput = try git.run(.status(short: true))
        let isClean = statusOutput.isEmpty

        try await Plist.set(key: "GIT_COMMIT_HASH", value: commitHash, in: plist)
        try await Plist.set(key: "GIT_BRANCH", value: branch, in: plist)
        try await Plist.set(key: "GIT_STATUS_CLEAN", value: isClean ? "YES" : "NO", in: plist)

        print("Injected git info: \(commitHash) (\(branch)) clean=\(isClean ? "YES" : "NO")")
    }
}

enum InjectGitInfoError: LocalizedError {
    case missingPlistPath

    var errorDescription: String? {
        switch self {
        case .missingPlistPath:
            return "No plist path provided. Set --plist-path or run from an Xcode build phase (TARGET_BUILD_DIR/INFOPLIST_PATH)."
        }
    }
}
