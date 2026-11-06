import ArgumentParser
import Foundation
import Shared

struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show disk usage as a tree: each Xcode with its SDKs, runtimes and simulators, then orphans, device support and DerivedData.",
        discussion: """
            Each Xcode group holds the app (with a size for each platform's SDKs) and the simulator runtimes that its SDKs \
            match, from `xcrun simctl runtime match list`, with their simulators. A runtime that no installed Xcode matches \
            goes in its own group; an Xcode can still use an older runtime, so these are not suggested only for that. \
            Simulators whose runtime is not installed are in their own group too.

            The ids are the same as in `scan`, so `xcprune delete <id>...` deletes what you see. Rows with no id are \
            parts of another item, such as the SDKs in an Xcode app, or are only notes.
            """
    )

    @OptionGroup var options: CategoryOptions

    @Flag(name: .long, help: "Show all items. Without it, a group shows its \(TreeRenderer.defaultLimit) largest items.")
    var all = false

    @Option(name: .long, help: "Show this many levels under each group (1 = the groups only).")
    var depth: Int?

    @Flag(name: .long, help: "Do not use colors. Colors are also off when stdout is not a terminal or NO_COLOR is set.")
    var noColor = false

    func validate() throws {
        if let depth, depth < 1 {
            throw ValidationError("--depth must be 1 or more.")
        }
    }

    func run() async throws {
        let roots = Roots.current()
        let scanner = Scanner(roots: roots)
        let categories = options.selected
        async let scanned = scanner.scan(categories)
        async let inspected = categories.contains(.xcode)
            ? XcodeInspector.inspect(apps: scanner.findXcodeApps(), roots: roots)
            : XcodeInspector.Result(details: [:], commandLineTools: nil)
        let (items, inspection) = await (scanned, inspected)

        let nodes = TreeBuilder(items: items, inspection: inspection, categories: categories, scanner: scanner).build()
        guard !nodes.isEmpty else {
            print("Nothing found.")
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let color = !noColor && isatty(STDOUT_FILENO) != 0 && environment["NO_COLOR"] == nil
        let renderer = TreeRenderer(
            width: TreeRenderer.terminalWidth(), color: color, limit: all ? nil : TreeRenderer.defaultLimit, maxDepth: depth)
        for line in renderer.render(nodes, volume: VolumeInfo.read(at: roots.home), itemsTotal: items.compactMap(\.sizeBytes).reduce(0, +)) {
            print(line)
        }
        let suggested = items.filter(\.suggested)
        print()
        if !suggested.isEmpty {
            print("* = suggested for deletion: \(Format.items(suggested.count)), \(Format.total(suggested)). Delete them with `xcprune delete --suggested`.")
        }
        print("Delete items with `xcprune delete <id>...`, or select them with `xcprune pick`.")
    }
}

// MARK: - Xcode details

/// What `tree` reads from each Xcode app: the size of each platform's SDKs and the runtime builds that the SDKs match.
enum XcodeInspector {
    struct Platform: Sendable {
        let family: String
        var sdkVersions: [String]
        var sizeBytes: Int64
    }

    struct Match: Sendable {
        let family: String
        let sdkVersion: String
        let build: String
    }

    struct Details: Sendable {
        var platforms: [Platform] = []
        var matches: [Match] = []
        /// True when `simctl` could not say, so the matches come from the SDKs' own build numbers.
        var matchesAreEstimated = false
    }

    struct SDK: Sendable {
        let name: String
        let sizeBytes: Int64?
    }

    struct CommandLineTools: Sendable {
        let path: String
        let sizeBytes: Int64?
        let sdks: [SDK]
    }

    struct Result: Sendable {
        let details: [String: Details]
        let commandLineTools: CommandLineTools?
    }

    static let familyOrder = ["iOS", "macOS", "tvOS", "watchOS", "visionOS", "DriverKit"]

    static func inspect(apps: [String], roots: Roots) async -> Result {
        async let commandLineTools = commandLineTools(roots: roots)
        var details: [String: Details] = [:]
        await withTaskGroup(of: (String, Details).self) { group in
            for app in apps {
                group.addTask { (app, await inspect(app: app, roots: roots)) }
            }
            for await (app, detail) in group {
                details[app] = detail
            }
        }
        return Result(details: details, commandLineTools: await commandLineTools)
    }

    static func inspect(app: String, roots: Roots) async -> Details {
        let platformsDirectory = app + "/Contents/Developer/Platforms"
        let platformDirectories = contents(of: platformsDirectory).filter { $0.hasSuffix(".platform") }

        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64?).self) { group in
            for directory in platformDirectories {
                group.addTask { (directory, await Scanner.diskUsage(platformsDirectory + "/" + directory)) }
            }
            for await (directory, size) in group {
                sizes[directory] = size ?? 0
            }
        }

        var byFamily: [String: Platform] = [:]
        for directory in platformDirectories {
            let family = family(forPlatformDirectory: String(directory.dropLast(".platform".count)))
            let sdkDirectory = platformsDirectory + "/" + directory + "/Developer/SDKs"
            let versions = realSDKs(in: sdkDirectory).compactMap {
                Plist.readDictionary(from: sdkDirectory + "/" + $0 + "/SDKSettings.plist")?["Version"] as? String
            }
            var platform = byFamily[family] ?? Platform(family: family, sdkVersions: [], sizeBytes: 0)
            platform.sdkVersions = Array(Set(platform.sdkVersions + versions)).sorted { VersionOrder.isOlder($1, than: $0) }
            platform.sizeBytes += sizes[directory] ?? 0
            byFamily[family] = platform
        }

        var details = Details()
        details.platforms = byFamily.values.sorted { familyRank($0.family) < familyRank($1.family) }
        if roots.usesSystemTools, let matches = await simctlMatches(app: app) {
            details.matches = matches
        } else {
            details.matches = estimatedMatches(platformsDirectory: platformsDirectory, platformDirectories: platformDirectories, roots: roots)
            details.matchesAreEstimated = true
        }
        details.matches.sort { familyRank($0.family) < familyRank($1.family) }
        return details
    }

    private struct MatchEntry: Decodable {
        let chosenRuntimeBuild: String?
        let defaultBuild: String?
        let platform: String?
        let sdkVersion: String?
    }

    private static func simctlMatches(app: String) async -> [Match]? {
        let result = await Shell.runOptional(
            "env", arguments: ["DEVELOPER_DIR=\(app)/Contents/Developer", "xcrun", "simctl", "runtime", "match", "list", "-j"])
        guard result.success, let entries = try? JSONDecoder().decode([String: MatchEntry].self, from: Data(result.output.utf8)) else {
            return nil
        }
        return entries.values.compactMap { entry in
            guard let build = entry.chosenRuntimeBuild ?? entry.defaultBuild, !build.isEmpty else { return nil }
            return Match(family: family(forPlatformIdentifier: entry.platform ?? ""), sdkVersion: entry.sdkVersion ?? "?", build: build)
        }
    }

    /// Without `simctl` (for example, before the Xcode license is accepted), each simulator SDK's build is the runtime build
    /// it wants, translated through Xcode's SDK-to-simulator mapping when the mapping has the build.
    private static func estimatedMatches(platformsDirectory: String, platformDirectories: [String], roots: Roots) -> [Match] {
        let mappingPath = roots.home + "/Library/Developer/Xcode/SDKToSimulatorIndexMapping.plist"
        let mapping = (NSArray(contentsOfFile: mappingPath) as? [[String: Any]]) ?? []
        var matches: [Match] = []
        for directory in platformDirectories where directory.hasSuffix("Simulator.platform") {
            let family = family(forPlatformDirectory: String(directory.dropLast(".platform".count)))
            let sdkDirectory = platformsDirectory + "/" + directory + "/Developer/SDKs"
            for sdk in realSDKs(in: sdkDirectory) {
                let version = Plist.readDictionary(from: sdkDirectory + "/" + sdk + "/System/Library/CoreServices/SystemVersion.plist")
                guard let build = version?["ProductBuildVersion"] as? String else { continue }
                let mapped = mapping.first { $0["sdkBuildUpdate"] as? String == build }?["simulatorBuildUpdate"] as? String
                matches.append(Match(family: family, sdkVersion: version?["ProductVersion"] as? String ?? "?", build: mapped ?? build))
            }
        }
        return matches
    }

    private static func commandLineTools(roots: Roots) async -> CommandLineTools? {
        let path = roots.library + "/Developer/CommandLineTools"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let sdkDirectory = path + "/SDKs"
        async let total = Scanner.diskUsage(path)
        var sdks: [SDK] = []
        await withTaskGroup(of: SDK.self) { group in
            for name in realSDKs(in: sdkDirectory) {
                group.addTask { SDK(name: name, sizeBytes: await Scanner.diskUsage(sdkDirectory + "/" + name)) }
            }
            for await sdk in group {
                sdks.append(sdk)
            }
        }
        return CommandLineTools(path: path, sizeBytes: await total, sdks: sdks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// The `.sdk` folders that are not symbolic links, e.g. `iPhoneSimulator26.5.sdk` and not `iPhoneSimulator.sdk`.
    private static func realSDKs(in directory: String) -> [String] {
        contents(of: directory).filter {
            $0.hasSuffix(".sdk") && (try? FileManager.default.destinationOfSymbolicLink(atPath: directory + "/" + $0)) == nil
        }
    }

    private static func contents(of directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    static func familyRank(_ family: String) -> Int {
        familyOrder.firstIndex(of: family) ?? familyOrder.count
    }

    /// `iPhoneSimulator` → `iOS`
    static func family(forPlatformDirectory name: String) -> String {
        switch name {
        case "iPhoneOS", "iPhoneSimulator": "iOS"
        case "AppleTVOS", "AppleTVSimulator": "tvOS"
        case "WatchOS", "WatchSimulator": "watchOS"
        case "XROS", "XRSimulator": "visionOS"
        case "MacOSX": "macOS"
        default: name
        }
    }

    /// `com.apple.platform.iphoneos` → `iOS`
    static func family(forPlatformIdentifier identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        switch last {
        case "iphoneos", "iphonesimulator": return "iOS"
        case "appletvos", "appletvsimulator": return "tvOS"
        case "watchos", "watchsimulator": return "watchOS"
        case "xros", "xrsimulator": return "visionOS"
        case "macosx": return "macOS"
        default: return last
        }
    }

    /// A runtime's platform as `simctl` names it (`xrOS`) → `visionOS`
    static func family(forRuntimePlatform platform: String) -> String {
        platform == "xrOS" ? "visionOS" : platform
    }
}

// MARK: - Tree model

struct Node {
    enum Style {
        case normal, suggested, warning, note
    }

    var label: String
    var detail = ""
    var size: Int64?
    var id: String?
    var style = Style.normal
    var children: [Node] = []

    init(label: String, detail: String = "", size: Int64? = nil, id: String? = nil, style: Style = .normal, children: [Node] = []) {
        self.label = label
        self.detail = detail
        self.size = size
        self.id = id
        self.style = style
        self.children = children
    }

    /// A row for an item that `delete` can take.
    init(item: Item, label: String? = nil, detail: String? = nil, children: [Node] = []) {
        var text = detail ?? item.detail
        if item.suggested, let reason = item.reason {
            text += text.isEmpty ? "→ \(reason)" : "  → \(reason)"
        }
        self.init(label: label ?? item.name, detail: text, size: item.sizeBytes, id: item.id, style: item.suggested ? .suggested : .normal, children: children)
    }

    /// A row that holds other rows. Its size is the sum of theirs.
    static func group(_ label: String, detail: String = "", children: [Node], sorted: Bool = true) -> Node {
        let ordered = sorted ? children.sorted { ($0.size ?? 0) > ($1.size ?? 0) } : children
        return Node(label: label, detail: detail, size: ordered.compactMap(\.size).reduce(0, +), children: ordered)
    }
}

struct TreeBuilder {
    let items: [Item]
    let inspection: XcodeInspector.Result
    let categories: Set<Category>
    let scanner: Scanner

    private func items(_ category: Category) -> [Item] {
        items.filter { $0.category == category }
    }

    func build() -> [Node] {
        var nodes: [Node] = []
        let runtimes = items(.runtime)
        let simulators = items(.simulator)
        var simulatorsByRuntime = Dictionary(grouping: simulators) { $0.info["runtimeIdentifier"] ?? "" }
        var claimed = Set<String>()  // runtime item ids that an Xcode group shows
        var claimedBy: [String: String] = [:]

        func runtimeNode(_ runtime: Item, detail: String? = nil) -> Node {
            let key = runtime.info["runtimeIdentifier"] ?? ""
            let attached = simulatorsByRuntime.removeValue(forKey: key) ?? []
            guard !attached.isEmpty else {
                return Node(item: runtime, label: "\(runtime.name) runtime", detail: detail.map { "\($0) · no simulators" } ?? "no simulators")
            }
            let children = [Node(item: runtime, label: "runtime image")] + attached.map { Node(item: $0, detail: simulatorDetail($0)) }
            return .group("\(runtime.name) runtime", detail: [detail, "\(Format.items(attached.count).replacingOccurrences(of: "item", with: "simulator"))"].compactMap { $0 }.joined(separator: " · "), children: children)
        }

        // Each Xcode, newest first, with the runtimes its SDKs match.
        let xcodes = items(.xcode).sorted { VersionOrder.isOlder($1.info["version"] ?? "", than: $0.info["version"] ?? "") }
        for xcode in xcodes {
            let details = inspection.details[xcode.path ?? ""] ?? XcodeInspector.Details()
            let platformRows = details.platforms.map { platform in
                Node(label: "\(platform.family) SDK \(platform.sdkVersions.joined(separator: ", "))", size: platform.sizeBytes)
            }
            let platformTotal = details.platforms.map(\.sizeBytes).reduce(0, +)
            var appChildren = platformRows
            if let size = xcode.sizeBytes, size > platformTotal, !platformRows.isEmpty {
                appChildren.append(Node(label: "Other: toolchains, tools, documentation", size: size - platformTotal))
            }
            var children = [Node(item: xcode, label: "Xcode.app", detail: "", children: appChildren)]

            if categories.contains(.runtime) {
                for match in details.matches {
                    let sameFamily = runtimes.filter { XcodeInspector.family(forRuntimePlatform: $0.info["platform"] ?? "") == match.family }
                    var runtime = sameFamily.first { $0.info["build"] == match.build }
                    var usedBy = "for the \(match.family) \(match.sdkVersion) SDK"
                    // Without the exact build, Xcode uses an installed runtime of the same major.minor version.
                    if runtime == nil {
                        let minor = Self.majorMinor(match.sdkVersion)
                        runtime = sameFamily.filter { Self.majorMinor($0.info["version"] ?? "") == minor && !claimed.contains($0.id) }.max {
                            VersionOrder.isOlder(version: $0.info["version"] ?? "", build: $0.info["build"] ?? "", than: $1.info["version"] ?? "", build: $1.info["build"] ?? "")
                        }
                        if runtime != nil {
                            usedBy += " · nearest installed; Xcode asks for \(match.build)"
                        }
                    }
                    if let runtime, !claimed.contains(runtime.id) {
                        claimed.insert(runtime.id)
                        claimedBy[runtime.id] = xcode.info["version"]
                        children.append(runtimeNode(runtime, detail: usedBy))
                    } else if let runtime {
                        children.append(Node(
                            label: "\(runtime.name) runtime", detail: "\(usedBy) · counted under Xcode \(claimedBy[runtime.id] ?? "?")", style: .note))
                    } else {
                        children.append(Node(label: "\(match.family) runtime \(match.build)", detail: "\(usedBy) · not installed", style: .warning))
                    }
                }
            }

            var detail = scanner.displayPath(xcode.path ?? "")
            if xcode.info["selected"] == "true" { detail += " · selected with xcode-select" }
            if details.matchesAreEstimated && categories.contains(.runtime) && scanner.roots.usesSystemTools {
                detail += " · runtime matches estimated (`simctl` failed; is the license accepted?)"
            }
            nodes.append(.group("Xcode \(xcode.info["version"] ?? "?") (\(xcode.info["build"] ?? "?"))", detail: detail, children: children, sorted: false))
        }

        let unclaimed = runtimes.filter { !claimed.contains($0.id) }
        if !unclaimed.isEmpty {
            let label = categories.contains(.xcode) ? "Runtimes that no installed Xcode matches" : "Simulator runtimes"
            let detail = categories.contains(.xcode) ? "an Xcode can still use an older runtime" : ""
            nodes.append(.group(label, detail: detail, children: unclaimed.map { runtimeNode($0) }))
        }

        // What is left: simulators whose runtime is not installed (or was not scanned).
        let leftover = simulatorsByRuntime.flatMap { runtime, simulators in
            simulators.map { (Scanner.runtimeName(fromRuntimeIdentifier: runtime), $0) }
        }
        if !leftover.isEmpty {
            let byRuntime = Dictionary(grouping: leftover, by: \.0).map { name, pairs in
                Node.group(name, children: pairs.map { Node(item: $0.1, detail: simulatorDetail($0.1)) })
            }
            let label = categories.contains(.runtime) ? "Simulators with no installed runtime" : "Simulators"
            nodes.append(.group(label, children: byRuntime))
        }

        let deviceSupport = items(.deviceSupport)
        if !deviceSupport.isEmpty {
            let byModel = Dictionary(grouping: deviceSupport) { "\($0.info["model"] ?? $0.name) (\($0.info["platform"] ?? "?"))" }
            nodes.append(.group("Device support", detail: "Xcode makes a folder again when a device with that version connects", children: byModel.map { model, folders in
                let newestFirst = folders.sorted { VersionOrder.isOlder($1.info["version"] ?? "", than: $0.info["version"] ?? "") }
                return .group(model, children: newestFirst.map { Node(item: $0, detail: "") }, sorted: false)
            }))
        }

        let derivedData = items(.derivedData)
        if !derivedData.isEmpty {
            nodes.append(.group("DerivedData", detail: "Xcode makes it again on the next build", children: derivedData.map { Node(item: $0) }))
        }

        let archives = items(.archive)
        if !archives.isEmpty {
            let byApp = Dictionary(grouping: archives) { $0.info["app"] ?? $0.name }
            nodes.append(.group("Archives", detail: "they hold the dSYMs for crash reports", children: byApp.map { app, archives in
                .group(app, detail: Format.items(archives.count).replacingOccurrences(of: "item", with: "archive"),
                       children: archives.reversed().map { Node(item: $0, label: $0.detail, detail: "") }, sorted: false)
            }))
        }

        let caches = items(.cache)
        let dyldCaches = caches.filter { $0.info["dyldMacOSBuild"] != nil }
        if !dyldCaches.isEmpty {
            let byBuild = Dictionary(grouping: dyldCaches) { $0.info["dyldMacOSBuild"] ?? "?" }
            nodes.append(.group("Simulator dyld caches", detail: "CoreSimulator makes a runtime's cache again when one of its simulators boots", children: byBuild.map { build, caches in
                .group(build == scanner.roots.macOSBuild ? "macOS \(build) (this Mac)" : "macOS \(build)", children: caches.map { Node(item: $0, label: $0.info["runtime"] ?? "all runtimes", detail: $0.path.map(scanner.displayPath) ?? "") })
            }))
        }
        let otherCaches = caches.filter { $0.info["dyldMacOSBuild"] == nil }
        if !otherCaches.isEmpty {
            nodes.append(.group("Caches", children: otherCaches.map { Node(item: $0) }))
        }

        if let tools = inspection.commandLineTools {
            var children = tools.sdks.map { Node(label: $0.name, size: $0.sizeBytes) }
            let sdkTotal = children.compactMap(\.size).reduce(0, +)
            if let total = tools.sizeBytes, total > sdkTotal {
                children.append(Node(label: "Other: compilers and tools", size: total - sdkTotal))
            }
            nodes.append(.group("Command Line Tools", detail: "\(tools.path) · remove with `sudo rm -rf` and reinstall with `xcode-select --install`", children: children))
        }

        let downloads = items(.download)
        if !downloads.isEmpty {
            nodes.append(.group("Downloaded installers", children: downloads.map { Node(item: $0) }))
        }
        return nodes
    }

    /// `26.5.1` → `26.5`
    static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    private func simulatorDetail(_ simulator: Item) -> String {
        // The runtime is the parent row, so leave it out of the detail.
        simulator.detail.split(separator: "·").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
    }
}

// MARK: - Rendering

struct VolumeInfo {
    let total: Int64
    let available: Int64

    static func read(at path: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return VolumeInfo(total: Int64(total), available: available)
    }
}

struct TreeRenderer {
    static let defaultLimit = 10

    let width: Int
    let color: Bool
    let limit: Int?
    let maxDepth: Int?

    static func terminalWidth() -> Int {
        var size = winsize()
        if isatty(STDOUT_FILENO) != 0, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 120
    }

    private var barWidth: Int { width >= 110 ? 24 : width >= 80 ? 14 : 8 }
    private let idWidth = 6
    private let sizeWidth = 9

    private func paint(_ text: String, _ code: String) -> String {
        color && !text.isEmpty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    func render(_ nodes: [Node], volume: VolumeInfo?, itemsTotal: Int64) -> [String] {
        var lines: [String] = []
        if let volume {
            lines += summary(volume: volume, xcodeRelated: itemsTotal)
        }
        let scale = max(nodes.compactMap(\.size).max() ?? 1, 1)
        for node in nodes {
            lines.append("")
            lines += render(node, prefix: "", childPrefix: "", depth: 1, scale: scale, isGroup: true)
        }
        return lines
    }

    private func summary(volume: VolumeInfo, xcodeRelated: Int64) -> [String] {
        let used = max(volume.total - volume.available, 0)
        let other = max(used - xcodeRelated, 0)
        let length = max(min(width - 2, 72), 20)
        let xcodeCells = Int((Double(xcodeRelated) / Double(volume.total) * Double(length)).rounded())
        let freeCells = Int((Double(volume.available) / Double(volume.total) * Double(length)).rounded())
        let otherCells = max(length - xcodeCells - freeCells, 0)
        let percent = { (part: Int64) in "\(Int((Double(part) / Double(volume.total) * 100).rounded()))%" }
        return [
            paint("Disk: \(Format.size(volume.total))", "1"),
            paint(String(repeating: "█", count: xcodeCells), "36") + paint(String(repeating: "▒", count: otherCells), "2")
                + paint(String(repeating: "░", count: freeCells), "32"),
            "\(paint("█", "36")) Xcode-related \(Format.size(xcodeRelated)) (\(percent(xcodeRelated)))   "
                + "\(paint("▒", "2")) other \(Format.size(other)) (\(percent(other)))   "
                + "\(paint("░", "32")) free \(Format.size(volume.available)) (\(percent(volume.available)))",
        ]
    }

    private func render(_ node: Node, prefix: String, childPrefix: String, depth: Int, scale: Int64, isGroup: Bool) -> [String] {
        var lines = [line(node, prefix: prefix, scale: scale, isGroup: isGroup)]
        guard maxDepth.map({ depth < $0 }) ?? true, !node.children.isEmpty else { return lines }

        var children = node.children
        if let limit, children.count > limit + 1 {
            let hidden = children[limit...]
            children = Array(children[..<limit])
            children.append(Node(
                label: "… \(hidden.count) more", detail: "use --all to show them",
                size: hidden.compactMap(\.size).reduce(0, +), style: .note))
        }
        for (index, child) in children.enumerated() {
            let last = index == children.count - 1
            lines += render(
                child, prefix: childPrefix + (last ? "└─ " : "├─ "), childPrefix: childPrefix + (last ? "   " : "│  "),
                depth: depth + 1, scale: scale, isGroup: false)
        }
        return lines
    }

    private func line(_ node: Node, prefix: String, scale: Int64, isGroup: Bool) -> String {
        let id = Format.padRight(node.id ?? "", idWidth)
        let mark = switch node.style {
        case .suggested: paint("*", "33")
        case .warning: paint("!", "31")
        default: " "
        }
        let labelWidth = max(width - idWidth - 1 - 2 - 1 - sizeWidth - 1 - barWidth, 20)

        var label = prefix + node.label
        var detail = ""
        if label.count > labelWidth {
            label = String(label.prefix(labelWidth - 1)) + "…"
        } else if !node.detail.isEmpty, labelWidth - label.count - 2 >= 8 {
            let room = labelWidth - label.count - 2
            detail = node.detail.count > room ? String(node.detail.prefix(room - 1)) + "…" : node.detail
        }
        let visible = label.count + (detail.isEmpty ? 0 : detail.count + 2)
        let padding = String(repeating: " ", count: max(labelWidth - visible, 0))

        let treePart = String(label.prefix(prefix.count))
        var namePart = String(label.dropFirst(prefix.count))
        namePart = switch node.style {
        case .suggested: paint(namePart, "33")
        case .warning: paint(namePart, "31")
        case .note: paint(namePart, "2")
        case .normal: isGroup ? paint(namePart, "1") : namePart
        }
        let detailPart = detail.isEmpty ? "" : "  " + paint(detail, "2")
        let size = node.size.map { Format.padLeft(Format.size($0), sizeWidth) } ?? String(repeating: " ", count: sizeWidth)
        let bar = node.size.map { paint(self.bar($0, scale: scale), node.style == .suggested ? "33" : "36") } ?? ""

        return "\(paint(id, "2")) \(mark) \(paint(treePart, "2"))\(namePart)\(detailPart)\(padding) \(size) \(bar)"
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    private func bar(_ size: Int64, scale: Int64) -> String {
        let eighths = Int((Double(size) / Double(scale) * Double(barWidth * 8)).rounded())
        let partial = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        return String(repeating: "█", count: eighths / 8) + partial[eighths % 8]
    }
}
