import ArgumentParser
import Foundation
import Shared

@main
struct PrepareGithubRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a GitHub release from a git tag using the changelog as release notes.",
        version: toolsVersion
    )

    @Argument(help: "The git tag to create a release for.")
    var tag: String

    @Option(name: [.customShort("l"), .long], help: "Path to the changelog file.")
    var changelog: String = "CHANGELOG.md"

    @Flag(name: .long, help: "Mark the release as a draft.")
    var draft = false

    @Flag(name: .long, help: "Mark the release as a prerelease.")
    var prerelease = false

    func run() async throws {
        // Extract release notes from changelog
        let notes = try extractReleaseNotes(tag: tag, from: changelog)

        // Build gh release create arguments
        var args = ["release", "create", tag, "--notes", notes]
        if draft { args.append("--draft") }
        if prerelease { args.append("--prerelease") }

        let output = try await Shell.run("gh", arguments: args)
        print(output)
    }

    private func extractReleaseNotes(tag: String, from changelogPath: String) throws -> String {
        let lines = try FileHelpers.readLines(changelogPath)

        // Find the section matching the tag (with or without leading "v")
        let candidates = [tag, "v\(tag)", tag.hasPrefix("v") ? String(tag.dropFirst()) : nil].compactMap { $0 }
        guard let startIdx = lines.firstIndex(where: { line in
            guard line.hasPrefix("## ") else { return false }
            return candidates.contains(where: { line.contains("[\($0)]") })
        }) else {
            throw PrepareGithubReleaseError.entryNotFound(tag)
        }

        // Find the end (next ## heading or end of file)
        let endIdx = lines[(startIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex

        // Extract content lines (skip the heading itself)
        let content = lines[(startIdx + 1)..<endIdx]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else {
            throw PrepareGithubReleaseError.emptyEntry(tag)
        }

        return content
    }
}

enum PrepareGithubReleaseError: LocalizedError {
    case entryNotFound(String)
    case emptyEntry(String)

    var errorDescription: String? {
        switch self {
        case .entryNotFound(let tag):
            return "Could not find a changelog entry for '\(tag)'."
        case .emptyEntry(let tag):
            return "Changelog entry for '\(tag)' is empty."
        }
    }
}
