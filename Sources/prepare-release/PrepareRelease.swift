import ArgumentParser
import Foundation
import Shared

@main
struct PrepareRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Migrate the changelog, tag the release, and optionally push and create a GitHub release.",
        version: toolsVersion
    )

    @Argument(help: "Pass 'rc' to create a release candidate tag. Omit for a final release.")
    var component: String?

    @Option(name: [.customShort("f"), .long], help: "Path to the file containing the version.")
    var file: String

    @Option(name: [.customShort("k"), .long], help: "Key mapping to the version in the file. Optional for plain version files (e.g. a bare VERSION file).")
    var key: String?

    @Option(name: [.customShort("l"), .long], help: "Path to the changelog file.")
    var changelog: String = "CHANGELOG.md"

    @Option(name: [.customShort("b"), .customLong("build-number")], help: "Build number to append as semver metadata (+N) in the changelog entry and git tag. The version file is not affected.")
    var buildNumber: Int?

    @Option(name: .long, help: "Key for the build number in --file. When set, prepare-release increments the numeric value at this key via vrsn and uses the result as the build number. Supersedes --build-number.")
    var buildNumberKey: String?

    @Option(name: [.customShort("n"), .customLong("rc-number")], help: "Override the release candidate number (default: auto-detected from consecutive RC sections in the changelog).")
    var rcNumber: Int?

    @Flag(name: .long, help: "Push the commit and tag to the remote after tagging.")
    var push = false

    @Flag(name: .long, help: "Create a GitHub release via prepare-github-release after pushing. Requires --push.")
    var githubRelease = false

    @Flag(name: .long, help: "Mark the GitHub release as a prerelease. Requires --github-release.")
    var prerelease = false

    func run() async throws {
        let isRC = component?.lowercased() == "rc"
        let currentVersion = try await Shell.run("vrsn", arguments: vrsnReadArgs())

        // Validate that the marketing version has been bumped since the last release.
        // Uses the changelog as the source of truth — compares against the most recent
        // non-RC section header so that multiple RCs in the same cycle don't require
        // re-bumping between deploys.
        try validateVersionBumped(currentVersion: currentVersion)

        // Validate that [Unreleased] has content before mutating anything.
        try validateUnreleasedNotEmpty()

        // Auto-increment the build number if --build-number-key was given.
        // vrsn prints the new value after writing, so one call does both.
        var resolvedBuildNumber = buildNumber
        if let bnKey = buildNumberKey {
            let newBuild = try await Shell.run("vrsn", arguments: ["-n", "-f", file, "-k", bnKey])
            resolvedBuildNumber = Int(newBuild.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Determine tag version.
        // RC: append -RCn (and optional +build). Version was already bumped externally.
        // Release: use the current version as-is (also already bumped externally).
        let tagVersion: String
        if isRC {
            let n: Int
            if let override = rcNumber {
                n = override
            } else {
                n = try nextRCNumber()
            }
            let base = "\(currentVersion)-RC\(n)"
            tagVersion = resolvedBuildNumber.map { "\(base)+\($0)" } ?? base
        } else {
            tagVersion = resolvedBuildNumber.map { "\(currentVersion)+\($0)" } ?? currentVersion
        }

        // Migrate the changelog.
        // RC: move [Unreleased] → [tagVersion].
        // Release: consolidate any consecutive -RC* sections into [tagVersion],
        //          falling back to normal Unreleased migration if no RC cycle exists.
        if isRC {
            try await Shell.run("migrate-changelog", arguments: [changelog, tagVersion, "--no-commit"])
        } else if try hasRCEntries() {
            try consolidateRCEntries(tagVersion: tagVersion)
        } else {
            try await Shell.run("migrate-changelog", arguments: [changelog, tagVersion, "--no-commit"])
        }

        // Commit all staged changes and create an annotated tag.
        let commitMessage = isRC
            ? "tag release candidate \(tagVersion)"
            : "tag release \(tagVersion)"

        try await Shell.run("changetag", arguments: [
            changelog, tagVersion,
            "--commit", "--message", commitMessage,
        ])

        if push {
            try await Shell.run("git", arguments: ["push"])
            try await Shell.run("git", arguments: ["push", "origin", tagVersion])
        }

        if githubRelease {
            var args = [tagVersion, "--changelog", changelog]
            if prerelease { args.append("--prerelease") }
            try await Shell.run("prepare-github-release", arguments: args)
        }

        print(tagVersion)
    }

    // MARK: - vrsn argument builder

    private func vrsnReadArgs() -> [String] {
        var args = ["-r", "-f", file]
        if let k = key { args += ["-k", k] }
        return args
    }

    // MARK: - Changelog helpers

    /// Validates that the [Unreleased] section contains at least one non-blank line,
    /// so we don't tag an empty release.
    private func validateUnreleasedNotEmpty() throws {
        let lines = try FileHelpers.readLines(changelog)
        guard let unreleasedIdx = lines.firstIndex(where: { $0.hasPrefix("## [Unreleased]") }) else {
            return // No structure to validate against
        }
        let bodyEnd = lines[(unreleasedIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let hasContent = lines[(unreleasedIdx + 1)..<bodyEnd].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !hasContent {
            throw PrepareReleaseError.emptyUnreleasedSection
        }
    }

    /// Validates that the current version in the version file differs from the most recent
    /// non-RC release section in the changelog. Errors if they match, meaning the version
    /// was not bumped before deploying (e.g. run `make patch`, `make minor`, or `make major`).
    private func validateVersionBumped(currentVersion: String) throws {
        let lines = try FileHelpers.readLines(changelog)
        guard let unreleasedIdx = lines.firstIndex(where: { $0.hasPrefix("## [Unreleased]") }) else {
            return // No changelog structure to validate against
        }
        // Skip past any RC sections to find the most recent final release section.
        var i = lines[(unreleasedIdx + 1)...].firstIndex(where: { $0.hasPrefix("## [") }) ?? lines.endIndex
        while i < lines.count, lines[i].hasPrefix("## ["), lines[i].contains("-RC") {
            i = lines[(i + 1)...].firstIndex(where: { $0.hasPrefix("## [") }) ?? lines.endIndex
        }
        guard i < lines.count, lines[i].hasPrefix("## [") else {
            return // No previous release to compare against
        }
        let lastReleaseVersion = coreVersion(from: lines[i])
        if currentVersion == lastReleaseVersion {
            throw PrepareReleaseError.versionNotBumped(currentVersion)
        }
    }

    /// Extracts the bare semantic version from a changelog section header,
    /// stripping any `-RC<N>` suffix and `+<build>` metadata.
    /// E.g. "## [1.3.0-RC2+42] 2025-01-01" → "1.3.0"
    private func coreVersion(from header: String) -> String {
        guard let open = header.firstIndex(of: "["),
              let close = header[open...].firstIndex(of: "]") else { return "" }
        var v = String(header[header.index(after: open)..<close])
        if let r = v.range(of: #"-RC\d+"#, options: .regularExpression) { v = String(v[..<r.lowerBound]) }
        if let p = v.firstIndex(of: "+") { v = String(v[..<p]) }
        return v
    }

    /// Returns the next RC number by scanning consecutive `-RC*` sections immediately
    /// after `[Unreleased]` in the changelog, regardless of their version prefix.
    /// This keeps RC numbering sequential even when the base version changes mid-cycle.
    private func nextRCNumber() throws -> Int {
        let lines = try FileHelpers.readLines(changelog)
        guard let unreleasedIdx = lines.firstIndex(where: { $0.hasPrefix("## [Unreleased]") }) else {
            return 1
        }
        var maxN = 0
        var i = lines[(unreleasedIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        while i < lines.count, lines[i].hasPrefix("## ["), lines[i].contains("-RC") {
            if let match = lines[i].range(of: #"-RC(\d+)"#, options: .regularExpression) {
                let digits = lines[i][match].dropFirst(3).prefix(while: { $0.isNumber })
                if let n = Int(digits) { maxN = max(maxN, n) }
            }
            i = lines[(i + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        }
        return maxN + 1
    }

    /// Returns true if there are consecutive `-RC*` sections immediately after `[Unreleased]`,
    /// regardless of their version prefix.
    private func hasRCEntries() throws -> Bool {
        let lines = try FileHelpers.readLines(changelog)
        guard let unreleasedIdx = lines.firstIndex(where: { $0.hasPrefix("## [Unreleased]") }),
              let firstSection = lines[(unreleasedIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) else {
            return false
        }
        return lines[firstSection].contains("-RC")
    }

    /// Combines all consecutive `-RC*` sections (plus any remaining [Unreleased] content)
    /// into a single new `[tagVersion]` section, then removes the RC sections.
    /// RC sections are collected by the `-RC` pattern regardless of version prefix,
    /// so a cycle that moved from 1.2.4-RC1 → 1.3.0-RC2 → 2.0.0-RC3 consolidates correctly.
    private func consolidateRCEntries(tagVersion: String) throws {
        let lines = try FileHelpers.readLines(changelog)

        guard let unreleasedIdx = lines.firstIndex(where: { $0.hasPrefix("## [Unreleased]") }) else {
            throw PrepareReleaseError.noUnreleasedSection
        }

        let unreleasedBodyEnd = lines[(unreleasedIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let unreleasedContent = lines[(unreleasedIdx + 1)..<unreleasedBodyEnd]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Collect consecutive RC sections in document order (newest RC appears first in the file).
        var rcRanges: [Range<Int>] = []
        var rcContents: [[String]] = []
        var i = unreleasedBodyEnd
        while i < lines.count {
            guard lines[i].hasPrefix("## [") && lines[i].contains("-RC") else { break }
            let end = lines[(i + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
            rcRanges.append(i..<end)
            rcContents.append(lines[(i + 1)..<end].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            i = end
        }

        // Build combined body: oldest RC first (reverse of document order), then any remaining Unreleased.
        let combined: [String] = rcContents.reversed().flatMap { $0 } + unreleasedContent

        // Remove RC sections (reverse order to keep earlier indices valid).
        var result = lines
        for range in rcRanges.reversed() {
            result.removeSubrange(range)
        }

        // Clear the Unreleased body.
        let updatedUnreleasedBodyEnd = result[(unreleasedIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? result.endIndex
        result.removeSubrange((unreleasedIdx + 1)..<updatedUnreleasedBodyEnd)

        // Insert the new release section immediately after [Unreleased].
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        let newSection: [String] = ["\n## [\(tagVersion)] \(today)"] + combined
        result.insert(contentsOf: newSection, at: unreleasedIdx + 1)

        try FileHelpers.write(result.joined(separator: "\n"), to: changelog)
    }
}

enum PrepareReleaseError: LocalizedError {
    case noUnreleasedSection
    case versionNotBumped(String)
    case emptyUnreleasedSection

    var errorDescription: String? {
        switch self {
        case .noUnreleasedSection:
            return "Could not find '## [Unreleased]' section in changelog."
        case .versionNotBumped(let v):
            return "Version \(v) was already released. Run 'make patch', 'make minor', or 'make major' to bump before deploying."
        case .emptyUnreleasedSection:
            return "The [Unreleased] section is empty. Add changelog entries before releasing."
        }
    }
}
