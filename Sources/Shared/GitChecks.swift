import Foundation

/// Preflight checks for anything that ships from the current checkout.
public enum GitChecks {
    /// Fetches, then errors if the upstream of the current branch has commits that
    /// HEAD does not. Being ahead is fine: those commits go out with the release push.
    public static func validateUpToDateWithUpstream() async throws {
        let upstream = await Shell.runOptional("git", arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        guard upstream.success, !upstream.output.isEmpty else {
            throw GitCheckError.noUpstream
        }
        try await Shell.run("git", arguments: ["fetch", "--quiet"])
        let behind = try await Shell.run("git", arguments: ["rev-list", "--count", "HEAD..@{u}"])
        if let count = Int(behind), count > 0 {
            throw GitCheckError.behindUpstream(upstream: upstream.output, commits: count)
        }
    }

    /// Errors if the working tree has staged, unstaged, or untracked (non-ignored) changes.
    public static func validateCleanWorkingTree() async throws {
        let status = try await Shell.run("git", arguments: ["status", "--porcelain"])
        if !status.isEmpty {
            throw GitCheckError.dirtyWorkingTree(status)
        }
    }

    /// Errors if HEAD is not on `expected`.
    public static func validateBranch(_ expected: String) async throws {
        let current = try await Shell.run("git", arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        if current != expected {
            throw GitCheckError.wrongBranch(expected: expected, actual: current)
        }
    }
}

public enum GitCheckError: LocalizedError {
    case noUpstream
    case behindUpstream(upstream: String, commits: Int)
    case dirtyWorkingTree(String)
    case wrongBranch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .noUpstream:
            return "The current branch has no upstream, so it cannot be checked against the remote. Set one with 'git branch --set-upstream-to'."
        case .behindUpstream(let upstream, let commits):
            return "\(upstream) has \(commits) commit\(commits == 1 ? "" : "s") that HEAD does not. Pull, then try again."
        case .dirtyWorkingTree(let status):
            return "The working tree has changes. Commit or stash them, then try again:\n\(status)"
        case .wrongBranch(let expected, let actual):
            return "HEAD is on '\(actual)', not '\(expected)'."
        }
    }
}
