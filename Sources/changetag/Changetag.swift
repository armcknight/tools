import ArgumentParser
import Foundation
import GitKit
import Shared

@main
struct Changetag: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract release notes from a changelog and write them into a git tag annotation."
    )

    @Argument(help: "Path to the CHANGELOG.md file.")
    var changelogPath: String

    @Argument(help: "Git tag name.")
    var tagName: String

    @Option(name: .shortAndLong, help: "Override the changelog entry name if it differs from the tag name.")
    var name: String?

    @Flag(name: .shortAndLong, help: "Overwrite an existing tag annotation.")
    var force = false

    func run() throws {
        let git = Git()

        // Ensure comment character won't conflict with markdown headings
        try git.run(.writeConfig(name: "core.commentchar", value: "@"))

        guard FileManager.default.fileExists(atPath: changelogPath) else {
            throw ChangetagError.invalidChangelogPath(changelogPath)
        }

        // Check existing tag
        let existingAnnotation: String? = {
            guard let result = try? git.run(.raw("tag -n \(tagName)")),
                  !result.isEmpty, result != tagName else { return nil }
            return result
        }()

        let tagExists = existingAnnotation != nil
        if tagExists && !force {
            throw ChangetagError.annotationExists(tagName)
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

        // Replace the heading line with just the tag name
        entryLines[0] = entryName

        // Strip two leading # from markdown headings (they were at ## level)
        entryLines = entryLines.map { line in
            if line.hasPrefix("##") {
                return String(line.dropFirst(2))
            }
            return line
        }

        let message = entryLines.joined(separator: "\n").escapedForShell

        if tagExists {
            try git.run(.raw("tag \(tagName) \(tagName) -f -m \"\(message)\""))
        } else {
            try git.run(.raw("tag \(tagName) -m \"\(message)\""))
        }

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
    case annotationExists(String)
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidChangelogPath(let path):
            return "The path '\(path)' does not point to a valid file."
        case .annotationExists(let tag):
            return "The tag \(tag) already has an annotation. Use -f/--force to overwrite."
        case .entryNotFound(let name):
            return "Could not find an entry in the changelog named '\(name)'."
        }
    }
}
