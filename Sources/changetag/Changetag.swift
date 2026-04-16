import ArgumentParser
import Foundation
import GitKit
import Shared

@main
struct Changetag: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract release notes from a changelog and write them into a git tag annotation.",
        version: toolsVersion
    )

    @Argument(help: "Path to the CHANGELOG.md file.")
    var changelogPath: String

    @Argument(help: "Git tag name.")
    var tagName: String

    @Option(name: .shortAndLong, help: "Look up this changelog section name instead of the tag name. The tag annotation title is always the tag name.")
    var name: String?

    @Flag(name: .long, help: "Stage all working tree changes and commit them before tagging.")
    var commit = false

    @Option(name: [.customShort("m"), .long], help: "Commit message. Required when --commit is used.")
    var message: String?

    func run() throws {
        let git = Git()

        // Ensure comment character won't conflict with markdown headings
        try git.run(.writeConfig(name: "core.commentchar", value: "@"))

        guard FileManager.default.fileExists(atPath: changelogPath) else {
            throw ChangetagError.invalidChangelogPath(changelogPath)
        }

        // Check existing tag
        if let result = try? git.run(.raw("tag -n \(tagName)")),
           !result.isEmpty, result != tagName {
            throw ChangetagError.tagExists(tagName)
        }

        let lines = try FileHelpers.readLines(changelogPath)
        let entryName = name ?? tagName

        // Find the start of the matching section
        guard let startIdx = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.contains("[\(entryName)]") }) else {
            throw ChangetagError.entryNotFound(entryName)
        }

        // Find the end (next ## heading or end of file)
        let endIdx = lines[(startIdx + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex

        // Extract and clean up the entry
        var entryLines = Array(lines[startIdx..<endIdx])
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Replace the heading line with the tag name
        entryLines[0] = tagName

        // Strip two leading # from markdown headings (they were at ## level)
        entryLines = entryLines.map { line in
            if line.hasPrefix("##") {
                return String(line.dropFirst(2))
            }
            return line
        }

        if commit {
            guard let commitMessage = message else {
                throw ChangetagError.missingCommitMessage
            }
            try git.run(.addAll)
            try git.run(.commit(message: commitMessage))
        }

        let tagMessage = entryLines.joined(separator: "\n").escapedForShell
        try git.run(.raw("tag \(tagName) -m \"\(tagMessage)\""))

        print("Tagged \(tagName) with changelog entry for \(entryName)")
    }
}

private extension String {
    var escapedForShell: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

enum ChangetagError: LocalizedError {
    case invalidChangelogPath(String)
    case tagExists(String)
    case entryNotFound(String)
    case missingCommitMessage

    var errorDescription: String? {
        switch self {
        case .invalidChangelogPath(let path):
            return "The path '\(path)' does not point to a valid file."
        case .tagExists(let tag):
            return "Tag '\(tag)' already exists."
        case .entryNotFound(let name):
            return "Could not find an entry in the changelog named '\(name)'."
        case .missingCommitMessage:
            return "--message is required when --commit is used."
        }
    }
}
