import ArgumentParser
import Foundation
import Shared

@main
struct ReadChangelog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the contents of a changelog section to stdout.",
        version: toolsVersion
    )

    @Argument(help: "Path to the CHANGELOG.md file.")
    var changelogPath: String = "CHANGELOG.md"

    @Option(name: .long, help: "The exact tag name to look up in the changelog.")
    var tag: String?

    @Flag(name: .long, help: "Use the most recent git tag (git describe --tags --abbrev=0) as the tag name.")
    var latestTag = false

    func run() async throws {
        let resolvedTag: String
        if let t = tag {
            resolvedTag = t
        } else if latestTag {
            resolvedTag = try await Shell.run("git", arguments: ["describe", "--tags", "--abbrev=0"])
        } else {
            throw ReadChangelogError.noTagSpecified
        }

        let lines = try FileHelpers.readLines(changelogPath)

        guard let startIdx = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.contains("[\(resolvedTag)]") }) else {
            throw ReadChangelogError.entryNotFound(resolvedTag)
        }

        let endIdx = lines[(startIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex

        let content = lines[(startIdx + 1)..<endIdx]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else {
            throw ReadChangelogError.emptyEntry(resolvedTag)
        }

        print(content)
    }
}

enum ReadChangelogError: LocalizedError {
    case noTagSpecified
    case entryNotFound(String)
    case emptyEntry(String)

    var errorDescription: String? {
        switch self {
        case .noTagSpecified:
            return "Specify a tag with --tag or use --latest-tag."
        case .entryNotFound(let tag):
            return "Could not find a changelog entry for '\(tag)'."
        case .emptyEntry(let tag):
            return "Changelog entry for '\(tag)' is empty."
        }
    }
}
