import ArgumentParser
import Foundation
import Shared
import Subprocess
import System

@main
struct XcPrune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcprune",
        abstract: "Find old Xcode apps, simulator runtimes, simulators, device support files and caches, and delete the ones you select.",
        discussion: """
            `scan` lists what is on disk with a size and an id for each item. Items with `*` are suggested for deletion: \
            simulators whose runtime is not installed, runtimes that a newer runtime of the same major version replaces \
            or that no simulator used for \(Scanner.staleRuntimeDays) days, device support folders older than the newest \
            one for the same device model, DerivedData whose project is gone or that no build used for \
            \(Scanner.staleDerivedDataDays) days, simulator dyld caches for another macOS build or for a runtime that is not \
            installed, and downloaded `.xip` installers. Xcode apps, archives and other caches are never suggested, but \
            you can select them.

            `tree` shows the same items as a tree: each Xcode with its SDKs, runtimes and simulators, then the orphans, \
            device support, DerivedData and the rest, with a bar for each size.

            `delete` takes ids from `scan` or `tree`, or `--suggested`, and asks before it deletes. `pick` lets you select items in fzf.

            Xcode apps go to the Trash. Simulators, runtimes and the dyld caches of installed runtimes are deleted with \
            `xcrun simctl`. Everything else is deleted at once. For an item that needs administrator rights, the tool prints a `sudo` command for you to run.
            """,
        version: toolsFullVersion,
        subcommands: [Scan.self, Tree.self, Delete.self, Pick.self],
        defaultSubcommand: Scan.self
    )
}

struct CategoryOptions: ParsableArguments {
    @Option(name: [.short, .customLong("category")], help: "Look only at this category. Use the option again for more categories.")
    var categories: [Category] = []

    var selected: Set<Category> {
        categories.isEmpty ? Set(Category.allCases) : Set(categories)
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List what is on disk, with sizes. Items with * are suggested for deletion.")

    @OptionGroup var options: CategoryOptions

    @Flag(name: .long, help: "Show only the suggested items.")
    var suggested = false

    @Flag(name: .long, help: "Print the items as JSON.")
    var json = false

    func run() async throws {
        var items = await Scanner(roots: .current()).scan(options.selected)
        if suggested {
            items = items.filter(\.suggested)
        }
        if json {
            print(try Report.json(items))
            return
        }
        guard !items.isEmpty else {
            print("Nothing found.")
            return
        }
        Report.printTable(items)
        print("Total: \(Format.items(items.count)), \(Format.total(items)).")
        let suggestedItems = items.filter(\.suggested)
        if suggestedItems.isEmpty {
            print("No items are suggested for deletion.")
        } else {
            print("Suggested (*): \(Format.items(suggestedItems.count)), \(Format.total(suggestedItems)). Delete them with `xcprune delete --suggested`.")
        }
        print("Delete other items with `xcprune delete <id>...`, or select them with `xcprune pick`.")
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete items by the ids that `scan` shows.")

    @Argument(help: "Ids from `xcprune scan`.")
    var ids: [String] = []

    @Flag(name: .long, help: "Delete all suggested items (with --category, only those in the categories).")
    var suggested = false

    @OptionGroup var options: CategoryOptions

    @Flag(name: .long, help: "Show what would be deleted. Do not delete.")
    var dryRun = false

    @Flag(name: [.short, .long], help: "Do not ask for confirmation.")
    var yes = false

    func validate() throws {
        guard !ids.isEmpty || suggested else {
            throw ValidationError("Give one or more ids from `xcprune scan`, or --suggested.")
        }
    }

    func run() async throws {
        // An id can be in any category, so look in all of them when ids are given without --category.
        let items = await Scanner(roots: .current()).scan(options.selected)
        var selection = suggested ? items.filter(\.suggested) : []
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unknown = ids.filter { byID[$0.lowercased()] == nil }
        guard unknown.isEmpty else {
            throw XcPruneError.unknownIDs(unknown)
        }
        for id in ids {
            if let item = byID[id.lowercased()], !selection.contains(where: { $0.id == item.id }) {
                selection.append(item)
            }
        }
        try await Deletion.run(selection, dryRun: dryRun, confirm: !yes)
    }
}

struct Pick: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Select items in fzf, then delete them.",
        discussion: """
            `pick` scans, then shows one line per item in fzf (`brew install fzf`): the id, `*` if the item is \
            suggested, the category, the size and the name. Nothing is deleted until you confirm.

            Keys:
              type text      Show only lines that match, e.g. `runtime 17`.
              Up / Down      Move the highlight.
              TAB            Select or deselect the line, and move down.
              Shift-TAB      Select or deselect the line, and move up.
              Ctrl-A         Select all the lines that are shown.
              Ctrl-D         Deselect all lines.
              ENTER          Continue with the selected lines. If none is
                             selected, the highlighted line is used.
              ESC / Ctrl-C   Cancel. Nothing is deleted.

            A selected line has `>` at its left edge, and the counter at the top shows how many lines are selected. \
            After ENTER, `pick` lists the items with their total size and asks `Delete these items? [y/N]`. With \
            --dry-run, it lists them and deletes nothing.
            """
    )

    @OptionGroup var options: CategoryOptions

    @Flag(name: .long, help: "Show only the suggested items.")
    var suggested = false

    @Flag(name: .long, help: "Show what would be deleted. Do not delete.")
    var dryRun = false

    func run() async throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw XcPruneError.notInteractive
        }
        var items = await Scanner(roots: .current()).scan(options.selected)
        if suggested {
            items = items.filter(\.suggested)
        }
        guard !items.isEmpty else {
            print("Nothing found.")
            return
        }
        let lines = Report.rows(items, showCategory: true)
        let chosen = try await FuzzyFinder.choose(
            lines,
            header: """
                Type to filter · TAB select · Shift-TAB select, move up · Ctrl-A select all shown · Ctrl-D deselect all
                ENTER continue (you confirm before anything is deleted) · ESC cancel · * = suggested
                """)
        let ids = Set(chosen.compactMap { $0.split(separator: " ").first.map(String.init) })
        guard !ids.isEmpty else {
            print("Nothing selected.")
            return
        }
        try await Deletion.run(items.filter { ids.contains($0.id) }, dryRun: dryRun, confirm: true)
    }
}

enum Deletion {
    static func run(_ items: [Item], dryRun: Bool, confirm: Bool) async throws {
        guard !items.isEmpty else {
            print("Nothing to delete.")
            return
        }
        let ordered = items.enumerated()
            .sorted { ($0.element.category.removalRank, $0.offset) < ($1.element.category.removalRank, $1.offset) }
            .map(\.element)

        print("\(dryRun ? "Would delete" : "Will delete") \(Format.items(ordered.count)), \(Format.total(ordered)):")
        for row in Report.rows(ordered, showCategory: true) {
            print("  " + row)
        }
        if dryRun {
            print("Dry run: nothing was deleted.")
            return
        }
        if confirm {
            guard isatty(STDIN_FILENO) != 0 else {
                throw XcPruneError.needsConfirmation
            }
            print("Delete these items? [y/N] ", terminator: "")
            fflush(nil)
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), ["y", "yes"].contains(answer) else {
                print("Nothing was deleted.")
                return
            }
        }

        var freed: Int64 = 0
        var adminCommands: [String] = []
        var failures = 0
        for item in ordered {
            switch await Remover.remove(item) {
            case .removed:
                freed += item.sizeBytes ?? 0
                print("Deleted \(item.id)  \(item.name)")
            case .needsAdmin(let command):
                adminCommands.append(command)
                print("Needs administrator rights: \(item.id)  \(item.name)")
            case .failed(let message):
                failures += 1
                FileHandle.standardError.write(Data("Could not delete \(item.id)  \(item.name): \(message)\n".utf8))
            }
        }
        print("Freed about \(Format.size(freed)).")
        if !adminCommands.isEmpty {
            print("\nTo delete the other items, run:")
            for command in adminCommands {
                print("  \(command)")
            }
        }
        if failures > 0 || !adminCommands.isEmpty {
            throw ExitCode.failure
        }
    }
}

enum FuzzyFinder {
    static func choose(_ lines: [String], header: String) async throws -> [String] {
        guard let fzf = executable(named: "fzf") else {
            throw XcPruneError.fzfMissing
        }
        // fzf draws its interface on /dev/tty, so it must stay in the terminal's foreground process group.
        // Foundation's Process puts the child in a new group, where the kernel stops fzf when it uses the
        // terminal (SIGTTOU), and the read of its output waits forever. Subprocess keeps the parent's group.
        let result = try await Subprocess.run(
            .path(FilePath(fzf)),
            arguments: [
                "--multi", "--reverse", "--no-sort", "--header", header, "--prompt", "select> ",
                "--marker", ">", "--bind", "ctrl-a:select-all,ctrl-d:deselect-all",
            ],
            input: .string(lines.joined(separator: "\n")),
            output: .string(limit: Shell.defaultMaxOutput),
            error: .standardError
        )
        switch result.terminationStatus {
        case .exited(0):
            return (result.standardOutput ?? "").split(separator: "\n").map(String.init)
        case .exited(1), .exited(130):
            return []  // no match, or cancelled
        case .exited(let status), .signaled(let status):
            throw XcPruneError.fzfFailed(status)
        }
    }

    private static func executable(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum XcPruneError: LocalizedError {
    case unknownIDs([String])
    case needsConfirmation
    case notInteractive
    case fzfMissing
    case fzfFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unknownIDs(let ids):
            return "No item has the id \(ids.joined(separator: ", ")). Run `xcprune scan` to see the ids."
        case .needsConfirmation:
            return "Cannot ask for confirmation because stdin is not a terminal. Use --yes to delete without confirmation."
        case .notInteractive:
            return "`xcprune pick` needs a terminal. Use `xcprune scan` and `xcprune delete <id>...` instead."
        case .fzfMissing:
            return "`xcprune pick` needs fzf (`brew install fzf`). Or use `xcprune scan` and `xcprune delete <id>...`."
        case .fzfFailed(let status):
            return "fzf failed with exit status \(status)."
        }
    }
}
