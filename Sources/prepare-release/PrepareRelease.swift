import ArgumentParser
import Foundation
import Shared

@main
struct PrepareRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bump a semantic version, migrate the changelog, and tag the release.",
        version: toolsVersion
    )

    @Argument(help: "Version component to bump: patch, minor, or major.")
    var component: String

    @Option(name: [.customShort("f"), .long], help: "Path to the file containing the version.")
    var file: String

    @Option(name: [.customShort("k"), .long], help: "Key mapping to the version in the file.")
    var key: String

    @Option(name: [.customShort("l"), .long], help: "Path to the changelog file.")
    var changelog: String = "CHANGELOG.md"

    func run() async throws {
        let currentVersion = try await Shell.run("vrsn", arguments: ["-r", "-f", file, "-k", key])
        let newVersion = try await Shell.run("vrsn", arguments: [component, "-t", "-f", file, "-k", key])
        try await Shell.run("vrsn", arguments: [component, "-f", file, "-k", key])
        try await Shell.run("migrate-changelog", arguments: [changelog, newVersion, "--no-commit"])
        try await Shell.run("changetag", arguments: [
            changelog, newVersion,
            "--commit", "--message", "bump version from \(currentVersion) to \(newVersion)",
        ])
    }
}
