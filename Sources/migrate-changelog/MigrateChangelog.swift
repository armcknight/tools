import ArgumentParser
import Foundation
import GitKit
import Shared

@main
struct MigrateChangelog: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move Unreleased changelog entries to a new versioned section."
    )

    @Argument(help: "Path to the CHANGELOG.md file.")
    var changelogPath: String

    @Argument(help: "Version string for the new section (e.g. 1.2.0).")
    var version: String

    @Flag(name: .shortAndLong, help: "Leave changes staged without committing.")
    var noCommit = false

    func run() throws {
        let git = Git()

        if !noCommit {
            let status = try git.run(.status(short: true))
            if !status.isEmpty {
                throw MigrateChangelogError.dirtyWorkingTree
            }
        }

        var lines = try FileHelpers.readLines(changelogPath)

        guard let unreleasedIndex = lines.firstIndex(where: { $0.hasPrefix("## [Unreleased]") }) else {
            throw MigrateChangelogError.noUnreleasedSection
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        let newHeading = "\n## [\(version)] \(today)"

        lines.insert(newHeading, at: unreleasedIndex + 1)

        let updatedContent = lines.joined(separator: "\n")
        try FileHelpers.write(updatedContent, to: changelogPath)

        if !noCommit {
            try git.run(.addAll)
            try git.run(.commit(message: "chore(changelog): moved Unreleased entries to \(version)"))
        }

        print("Migrated changelog to version \(version)")
    }
}

enum MigrateChangelogError: LocalizedError {
    case dirtyWorkingTree
    case noUnreleasedSection

    var errorDescription: String? {
        switch self {
        case .dirtyWorkingTree:
            return "Working tree has uncommitted changes. Commit or stash them first."
        case .noUnreleasedSection:
            return "Could not find '## [Unreleased]' section in changelog."
        }
    }
}
