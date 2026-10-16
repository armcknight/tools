import ArgumentParser
import Foundation
import Shared

@main
struct CheckReleaseReady: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Exit non-zero unless the checkout is safe to ship: clean, with an upstream, and not behind it.",
        discussion: "Put it in front of a deploy command that ships the local checkout, e.g. `check-release-ready --branch main && fly deploy`.",
        version: toolsVersion
    )

    @Option(name: [.customShort("b"), .long], help: "Also require HEAD to be on this branch.")
    var branch: String?

    func run() async throws {
        if let branch {
            try await GitChecks.validateBranch(branch)
        }
        try await GitChecks.validateCleanWorkingTree()
        try await GitChecks.validateUpToDateWithUpstream()
    }
}
