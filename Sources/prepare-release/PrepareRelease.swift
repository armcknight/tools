import ArgumentParser
import Foundation
import Shared

@main
struct PrepareRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bump a semantic version, migrate the changelog, and tag the release.",
        version: toolsVersion
    )

    @Argument(help: "Version component to bump: patch, minor, major, or rc (release candidate).")
    var component: String

    @Option(name: [.customShort("f"), .long], help: "Path to the file containing the version.")
    var file: String

    @Option(name: [.customShort("k"), .long], help: "Key mapping to the version in the file.")
    var key: String

    @Option(name: [.customShort("l"), .long], help: "Path to the changelog file.")
    var changelog: String = "CHANGELOG.md"

    @Option(name: [.customShort("b"), .customLong("build-number")], help: "Build number to append as semver metadata (+N) in the changelog entry and git tag. The version file is not affected.")
    var buildNumber: Int?

    @Option(name: [.customShort("n"), .customLong("rc-number")], help: "Override the release candidate number (default: auto-detected by counting existing RC tags for the current version).")
    var rcNumber: Int?

    @Flag(name: .long, help: "Push the commit and tag to the remote after tagging.")
    var push = false

    @Flag(name: .long, help: "Create a GitHub release via prepare-github-release after pushing. Requires --push.")
    var githubRelease = false

    @Flag(name: .long, help: "Mark the GitHub release as a prerelease. Requires --github-release.")
    var prerelease = false

    func run() async throws {
        let isRC = component.lowercased() == "rc"
        let currentVersion = try await Shell.run("vrsn", arguments: ["-r", "-f", file, "-k", key])

        // Determine tag version, and bump the version file for non-RC releases.
        let tagVersion: String
        if isRC {
            let n: Int
            if let override = rcNumber {
                n = override
            } else {
                let existing = try await Shell.run("git", arguments: ["tag", "--list", "\(currentVersion)-RC*"])
                n = existing.isEmpty ? 1 : existing.split(separator: "\n").count + 1
            }
            let base = "\(currentVersion)-RC\(n)"
            tagVersion = buildNumber.map { "\(base)+\($0)" } ?? base
        } else {
            let coreVersion = try await Shell.run("vrsn", arguments: [component, "-t", "-f", file, "-k", key])
            tagVersion = buildNumber.map { "\(coreVersion)+\($0)" } ?? coreVersion
            try await Shell.run("vrsn", arguments: [component, "-f", file, "-k", key])
        }

        // Migrate the changelog.
        // RC: move [Unreleased] → [tagVersion].
        // Release: consolidate any [currentVersion-RC*] sections into [tagVersion],
        //          falling back to normal Unreleased migration if no RC cycle exists.
        if isRC {
            try await Shell.run("migrate-changelog", arguments: [changelog, tagVersion, "--no-commit"])
        } else if try hasRCEntries(for: currentVersion) {
            try consolidateRCEntries(currentVersion: currentVersion, tagVersion: tagVersion)
        } else {
            try await Shell.run("migrate-changelog", arguments: [changelog, tagVersion, "--no-commit"])
        }

        // Commit all staged changes and create an annotated tag.
        let commitMessage = isRC
            ? "tag release candidate \(tagVersion)"
            : "bump version from \(currentVersion) to \(tagVersion)"

        try await Shell.run("changetag", arguments: [
            changelog, tagVersion,
            "--commit", "--message", commitMessage,
        ])

        if push {
            try await Shell.run("git", arguments: ["push"])
            try await Shell.run("git", arguments: ["push", "origin", tagVersion])
        }

        if githubRelease {
            var args = [tagVersion]
            if prerelease { args.append("--prerelease") }
            try await Shell.run("prepare-github-release", arguments: args)
        }

        print(tagVersion)
    }

    // MARK: - Changelog helpers

    private func hasRCEntries(for version: String) throws -> Bool {
        let lines = try FileHelpers.readLines(changelog)
        return lines.contains { $0.hasPrefix("## [") && $0.contains("[\(version)-RC") }
    }

    /// Combines all `[currentVersion-RC*]` sections (plus any remaining [Unreleased] content)
    /// into a single new `[tagVersion]` section, then removes the RC sections.
    private func consolidateRCEntries(currentVersion: String, tagVersion: String) throws {
        var lines = try FileHelpers.readLines(changelog)

        guard let unreleasedIdx = lines.firstIndex(where: { $0.hasPrefix("## [Unreleased]") }) else {
            throw PrepareReleaseError.noUnreleasedSection
        }

        let unreleasedBodyEnd = lines[(unreleasedIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let unreleasedContent = lines[(unreleasedIdx + 1)..<unreleasedBodyEnd]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Collect RC sections in document order (newest RC appears first in the file).
        var rcRanges: [Range<Int>] = []
        var rcContents: [[String]] = []
        var i = unreleasedBodyEnd
        while i < lines.count {
            guard lines[i].hasPrefix("## [") && lines[i].contains("[\(currentVersion)-RC") else { break }
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

    var errorDescription: String? {
        switch self {
        case .noUnreleasedSection:
            return "Could not find '## [Unreleased]' section in changelog."
        }
    }
}
