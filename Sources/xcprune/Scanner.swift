import Foundation
import Shared

/// Where to look. `XCPRUNE_ROOT` replaces the home directory, `/Applications` and `/Library` with
/// directories in it and turns off `simctl` and `xcode-select`, so tests do not touch the real ones.
/// With it, `XCPRUNE_MACOS_BUILD` gives the macOS build.
struct Roots: Sendable {
    let home: String
    let applicationDirectories: [String]
    let library: String
    let usesSystemTools: Bool
    /// The build of the running macOS, e.g. `25F71`. The simulator dyld caches are kept per macOS build.
    let macOSBuild: String?

    static func current() -> Roots {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["XCPRUNE_ROOT"], !root.isEmpty {
            return Roots(
                home: root + "/home", applicationDirectories: [root + "/Applications"], library: root + "/Library",
                usesSystemTools: false, macOSBuild: environment["XCPRUNE_MACOS_BUILD"])
        }
        let home = NSHomeDirectory()
        return Roots(
            home: home, applicationDirectories: ["/Applications", home + "/Applications"], library: "/Library",
            usesSystemTools: true, macOSBuild: runningMacOSBuild())
    }

    private static func runningMacOSBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

struct Scanner: Sendable {
    let roots: Roots
    let now = Date()

    /// DerivedData that no build used for this many days is suggested.
    static let staleDerivedDataDays = 30
    /// A simulator runtime that no simulator used for this many days is suggested.
    static let staleRuntimeDays = 180

    private var fileManager: FileManager { .default }
    private var developer: String { roots.home + "/Library/Developer" }

    func scan(_ categories: Set<Category>) async -> [Item] {
        var items: [Item] = []
        for category in Category.allCases where categories.contains(category) {
            switch category {
            case .xcode: items += await xcodes()
            case .runtime: items += await runtimes()
            case .simulator: items += await simulators()
            case .deviceSupport: items += deviceSupport()
            case .derivedData: items += derivedData()
            case .archive: items += archives()
            case .cache: items += await caches()
            case .download: items += downloads()
            }
        }
        await fillSizes(&items)
        // An empty cache is not worth a line.
        return items.filter { $0.category != .cache || ($0.sizeBytes ?? 0) > 0 }
    }

    // MARK: - Xcode

    func xcodes() async -> [Item] {
        var selected: String?
        if roots.usesSystemTools {
            let result = await Shell.runOptional("xcode-select", arguments: ["-p"])
            if result.success { selected = result.output }
        }
        return findXcodeApps().map { app in
            let info = Plist.readDictionary(from: app + "/Contents/version.plist")
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            var detail = (info?["ProductBuildVersion"] as? String).map { "\(version) (\($0))" } ?? version
            if let selected, selected.hasPrefix(app + "/") {
                detail += " · selected with xcode-select"
            }
            var item = Item(category: .xcode, key: app, name: displayPath(app), detail: detail, path: app, removal: .trash(path: app))
            item.info = ["version": version, "build": info?["ProductBuildVersion"] as? String ?? ""]
            if detail.hasSuffix("selected with xcode-select") { item.info["selected"] = "true" }
            return item
        }
    }

    /// Xcode apps directly in an applications directory, or one directory down, as in `/Applications/Xcode26.6/Xcode.app`.
    func findXcodeApps() -> [String] {
        var apps: [String] = []
        for directory in roots.applicationDirectories {
            for child in contents(of: directory) {
                let path = directory + "/" + child
                if child.hasSuffix(".app") {
                    if isXcode(path) { apps.append(path) }
                } else if isDirectory(path) {
                    apps += contents(of: path).filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }.filter(isXcode)
                }
            }
        }
        return apps
    }

    private func isXcode(_ app: String) -> Bool {
        Plist.readDictionary(from: app + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode"
    }

    // MARK: - Simulator runtimes

    private struct DiskImageRuntime: Decodable {
        let identifier: String
        let version: String?
        let build: String?
        let sizeBytes: Int64?
        let state: String?
        let lastUsedAt: String?
        let runtimeIdentifier: String?
    }

    private struct RuntimeList: Decodable {
        struct Runtime: Decodable {
            let identifier: String
            let version: String?
            let buildversion: String?
            let bundlePath: String?
        }
        let runtimes: [Runtime]
    }

    private struct RuntimeFacts {
        let platform: String
        let version: String
        let build: String
        let lastUsed: Date?
    }

    func runtimes() async -> [Item] {
        guard roots.usesSystemTools else { return [] }
        var items: [Item] = []
        var facts: [RuntimeFacts] = []

        if let images: [String: DiskImageRuntime] = await simctlJSON(["runtime", "list", "-j"]) {
            for runtime in images.values {
                let platform = runtime.runtimeIdentifier.flatMap(Self.platform(fromRuntimeIdentifier:)) ?? "?"
                let version = runtime.version ?? "?"
                let build = runtime.build ?? ""
                let lastUsed = Format.date(runtime.lastUsedAt)
                var detail = [runtime.state, lastUsed.map { "last used \(Format.day($0))" }].compactMap { $0 }.joined(separator: " · ")
                if detail.isEmpty { detail = "disk image" }
                var item = Item(
                    category: .runtime, key: runtime.identifier, name: "\(platform) \(version) (\(build))", detail: detail,
                    path: nil, sizeBytes: runtime.sizeBytes, removal: .simctlRuntime(identifier: runtime.identifier))
                item.info = ["platform": platform, "version": version, "build": build, "runtimeIdentifier": runtime.runtimeIdentifier ?? ""]
                items.append(item)
                facts.append(RuntimeFacts(platform: platform, version: version, build: build, lastUsed: lastUsed))
            }
        }

        // Runtimes from before Xcode 15 are bundles in /Library, not disk images.
        let bundleDirectory = roots.library + "/Developer/CoreSimulator/Profiles/Runtimes/"
        if let list: RuntimeList = await simctlJSON(["list", "runtimes", "-j"]) {
            for runtime in list.runtimes {
                guard let bundle = runtime.bundlePath, bundle.hasPrefix(bundleDirectory) else { continue }
                let platform = Self.platform(fromRuntimeIdentifier: runtime.identifier) ?? "?"
                let version = runtime.version ?? "?"
                let build = runtime.buildversion ?? ""
                var item = Item(
                    category: .runtime, key: bundle, name: "\(platform) \(version) (\(build))", detail: "bundle in \(bundleDirectory)",
                    path: bundle, removal: .remove(path: bundle))
                item.info = ["platform": platform, "version": version, "build": build, "runtimeIdentifier": runtime.identifier]
                items.append(item)
                facts.append(RuntimeFacts(platform: platform, version: version, build: build, lastUsed: nil))
            }
        }

        for (index, fact) in facts.enumerated() {
            let major = fact.version.split(separator: ".").first
            let newer = facts.filter {
                $0.platform == fact.platform && $0.version.split(separator: ".").first == major
                    && VersionOrder.isOlder(version: fact.version, build: fact.build, than: $0.version, build: $0.build)
            }
            if let newest = newer.max(by: { VersionOrder.isOlder(version: $0.version, build: $0.build, than: $1.version, build: $1.build) }) {
                items[index].suggest("\(newest.platform) \(newest.version) is installed")
            }
            if let lastUsed = fact.lastUsed, days(since: lastUsed) >= Self.staleRuntimeDays {
                items[index].suggest("not used for \(days(since: lastUsed)) days")
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1` → `iOS`
    static func platform(fromRuntimeIdentifier identifier: String) -> String? {
        guard let range = identifier.range(of: "SimRuntime.") else { return nil }
        return identifier[range.upperBound...].split(separator: "-").first.map(String.init)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1` → `iOS 26.1`
    static func runtimeName(fromRuntimeIdentifier identifier: String) -> String {
        guard let range = identifier.range(of: "SimRuntime.") else { return identifier }
        let parts = identifier[range.upperBound...].split(separator: "-")
        guard let platform = parts.first else { return identifier }
        return parts.count > 1 ? "\(platform) \(parts.dropFirst().joined(separator: "."))" : String(platform)
    }

    // MARK: - Simulators

    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String?
            let isAvailable: Bool?
            let availabilityError: String?
            let dataPath: String?
            let dataPathSize: Int64?
            let lastBootedAt: String?
        }
        let devices: [String: [Device]]
    }

    func simulators() async -> [Item] {
        guard roots.usesSystemTools, let list: DeviceList = await simctlJSON(["list", "devices", "-j"]) else { return [] }
        var items: [(runtime: String, item: Item)] = []
        for (runtime, devices) in list.devices {
            let runtimeName = Self.runtimeName(fromRuntimeIdentifier: runtime)
            for device in devices {
                let lastBooted = Format.date(device.lastBootedAt)
                let detail = [runtimeName, device.state, lastBooted.map { "last booted \(Format.day($0))" }]
                    .compactMap { $0 }.joined(separator: " · ")
                let directory = device.dataPath.map { ($0 as NSString).deletingLastPathComponent }
                var item = Item(
                    category: .simulator, key: device.udid, name: device.name, detail: detail,
                    path: directory, sizeBytes: device.dataPathSize, removal: .simctlDevice(udid: device.udid))
                item.info = ["runtimeIdentifier": runtime, "available": device.isAvailable == false ? "false" : "true"]
                if device.isAvailable == false {
                    let error = device.availabilityError ?? ""
                    item.suggest(error.isEmpty || error.contains("runtime profile not found") ? "its runtime is not installed" : error)
                }
                items.append((runtimeName, item))
            }
        }
        return items.sorted { lhs, rhs in
            lhs.runtime != rhs.runtime
                ? lhs.runtime.localizedStandardCompare(rhs.runtime) == .orderedAscending
                : lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }
        .map(\.item)
    }

    // MARK: - Device support

    /// A folder name such as `iPhone18,4 26.5 (23F77)`, `16.4 (20E247) arm64e` or `26.5 (23F77)`.
    struct DeviceSupportName: Equatable {
        let model: String?
        let version: String
        let build: String

        init?(_ name: String) {
            guard let open = name.range(of: " ("), let close = name[open.upperBound...].firstIndex(of: ")") else { return nil }
            let words = name[..<open.lowerBound].split(separator: " ")
            guard let version = words.last, version.split(separator: ".").allSatisfy({ Int($0) != nil }) else { return nil }
            self.version = String(version)
            self.model = words.count > 1 ? words.dropLast().joined(separator: " ") : nil
            self.build = String(name[open.upperBound..<close])
        }
    }

    func deviceSupport() -> [Item] {
        let base = developer + "/Xcode"
        var items: [Item] = []
        var parsed: [(index: Int, group: String, name: DeviceSupportName)] = []
        for directory in contents(of: base) where directory.hasSuffix(" DeviceSupport") {
            let platform = String(directory.dropLast(" DeviceSupport".count))
            for child in contents(of: base + "/" + directory) {
                let path = base + "/" + directory + "/" + child
                guard isDirectory(path) else { continue }
                var item = Item(category: .deviceSupport, key: path, name: child, detail: platform, path: path, removal: .remove(path: path))
                item.info = ["platform": platform]
                if let name = DeviceSupportName(child) {
                    parsed.append((items.count, platform + "|" + (name.model ?? ""), name))
                    item.info["model"] = name.model ?? platform
                    item.info["version"] = name.version
                    item.info["build"] = name.build
                }
                items.append(item)
            }
        }
        // Keep the newest folder for each device model. Xcode makes the folder again when a device with that version connects.
        for entry in parsed {
            let newer = parsed.filter {
                $0.group == entry.group
                    && VersionOrder.isOlder(version: entry.name.version, build: entry.name.build, than: $0.name.version, build: $0.name.build)
            }
            if let newest = newer.max(by: {
                VersionOrder.isOlder(version: $0.name.version, build: $0.name.build, than: $1.name.version, build: $1.name.build)
            }) {
                items[entry.index].suggest("\(newest.name.model ?? "this platform") has \(newest.name.version)")
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - DerivedData

    func derivedData() -> [Item] {
        let base = developer + "/Xcode/DerivedData"
        return contents(of: base).compactMap { child -> Item? in
            let path = base + "/" + child
            guard isDirectory(path) else { return nil }
            let info = Plist.readDictionary(from: path + "/info.plist")
            let workspace = info?["WorkspacePath"] as? String
            let lastUsed = info?["LastAccessedDate"] as? Date ?? modificationDate(path + "/info.plist") ?? modificationDate(path)
            let detail = [workspace.map(displayPath), lastUsed.map { "last used \(Format.day($0))" }].compactMap { $0 }.joined(separator: " · ")
            var item = Item(category: .derivedData, key: path, name: child, detail: detail, path: path, removal: .remove(path: path))
            if let workspace, !fileManager.fileExists(atPath: workspace) {
                item.suggest("the project is not on disk")
            } else if let lastUsed, days(since: lastUsed) >= Self.staleDerivedDataDays {
                item.suggest("not used for \(days(since: lastUsed)) days")
            }
            return item
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Archives

    func archives() -> [Item] {
        let base = developer + "/Xcode/Archives"
        var items: [Item] = []
        for day in contents(of: base) where isDirectory(base + "/" + day) {
            for archive in contents(of: base + "/" + day) where archive.hasSuffix(".xcarchive") {
                let path = base + "/" + day + "/" + archive
                let info = Plist.readDictionary(from: path + "/Info.plist")
                let properties = info?["ApplicationProperties"] as? [String: Any]
                let version = properties?["CFBundleShortVersionString"] as? String
                let build = properties?["CFBundleVersion"] as? String
                let created = info?["CreationDate"] as? Date
                let versionText = version.map { v in build.map { "\(v) (\($0))" } ?? v }
                let detail = [versionText, created.map(Format.day) ?? day].compactMap { $0 }.joined(separator: " · ")
                let name = info?["Name"] as? String ?? String(archive.dropLast(".xcarchive".count))
                var item = Item(category: .archive, key: path, name: name, detail: detail, path: path, removal: .remove(path: path))
                item.info = ["app": name]
                items.append(item)
            }
        }
        return items.sorted { ($0.name, $0.detail) < ($1.name, $1.detail) }
    }

    // MARK: - Caches

    func caches() async -> [Item] {
        let candidates = [
            (roots.home + "/Library/Caches/com.apple.dt.Xcode", "Xcode caches"),
            (developer + "/Xcode/DocumentationCache", "Documentation cache"),
            (roots.home + "/Library/Caches/org.swift.swiftpm", "SwiftPM caches"),
        ]
        var items = candidates.filter { isDirectory($0.0) }.map { path, name in
            Item(category: .cache, key: path, name: name, detail: displayPath(path), path: path, removal: .removeContents(path: path))
        }
        let installed = await installedRuntimes()
        for (base, name) in [
            (developer + "/CoreSimulator/Caches", "CoreSimulator caches"),
            (roots.library + "/Developer/CoreSimulator/Caches", "CoreSimulator caches (system)"),
        ] where isDirectory(base) {
            for child in contents(of: base) {
                let path = base + "/" + child
                if child == "dyld", isDirectory(path) {
                    items += dyldCaches(in: path, installedRuntimes: installed)
                } else {
                    items.append(Item(category: .cache, key: path, name: "\(name): \(child)", detail: displayPath(path), path: path, removal: .remove(path: path)))
                }
            }
        }
        return items
    }

    /// The simulator dyld shared caches, in `dyld/<macOS build>/<runtime identifier>.<runtime build>`.
    /// CoreSimulator makes a runtime's cache when one of its simulators boots, under the running macOS build.
    /// A folder for another macOS build is never used again, and neither is a cache for a runtime that is not installed.
    func dyldCaches(in base: String, installedRuntimes: Set<String>?) -> [Item] {
        var items: [Item] = []
        for build in contents(of: base) {
            let buildPath = base + "/" + build
            guard isDirectory(buildPath) else { continue }
            guard build == roots.macOSBuild else {
                var item = Item(
                    category: .cache, key: buildPath, name: "Simulator dyld caches for macOS \(build)", detail: displayPath(buildPath),
                    path: buildPath, removal: .remove(path: buildPath))
                item.info = ["dyldMacOSBuild": build]
                if let running = roots.macOSBuild {
                    item.suggest("this Mac runs macOS \(running)")
                }
                items.append(item)
                continue
            }
            for folder in contents(of: buildPath) where folder.hasPrefix("com.apple.CoreSimulator.SimRuntime.") {
                let path = buildPath + "/" + folder
                guard isDirectory(path), let dot = folder.lastIndex(of: ".") else { continue }
                let runtime = String(folder[..<dot])
                let runtimeBuild = String(folder[folder.index(after: dot)...])
                let isInstalled = installedRuntimes?.contains(runtime + "." + runtimeBuild)
                var item = Item(
                    category: .cache, key: path,
                    name: "Simulator dyld cache: \(Self.runtimeName(fromRuntimeIdentifier: runtime)) (\(runtimeBuild))",
                    detail: "macOS \(build) · " + displayPath(path), path: path,
                    removal: isInstalled == true ? .simctlDyldCache(runtime: runtime, path: path) : .remove(path: path))
                item.info = ["dyldMacOSBuild": build, "runtime": "\(Self.runtimeName(fromRuntimeIdentifier: runtime)) (\(runtimeBuild))"]
                if isInstalled == false {
                    item.suggest("its runtime is not installed")
                }
                items.append(item)
            }
        }
        return items
    }

    /// `<runtime identifier>.<build>` for each installed runtime, or nil when `simctl` cannot tell.
    private func installedRuntimes() async -> Set<String>? {
        guard roots.usesSystemTools, let list: RuntimeList = await simctlJSON(["list", "runtimes", "-j"]) else { return nil }
        return Set(list.runtimes.compactMap { runtime in runtime.buildversion.map { runtime.identifier + "." + $0 } })
    }

    // MARK: - Downloads

    func downloads() -> [Item] {
        let directories = [
            roots.home + "/Downloads",
            roots.home + "/Library/Application Support/com.robotsandpencils.xcodes",
        ]
        return directories.flatMap { directory in
            contents(of: directory).filter { $0.hasSuffix(".xip") }.map { file in
                let path = directory + "/" + file
                var item = Item(category: .download, key: path, name: file, detail: displayPath(directory), path: path, removal: .remove(path: path))
                item.suggest("an installer archive; you can download it again")
                return item
            }
        }
    }

    // MARK: - Helpers

    private func simctlJSON<T: Decodable>(_ arguments: [String]) async -> T? {
        let result = await Shell.runOptional("xcrun", arguments: ["simctl"] + arguments)
        guard result.success else {
            FileHandle.standardError.write(Data("warning: `xcrun simctl \(arguments.joined(separator: " "))` failed\n".utf8))
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: Data(result.output.utf8))
    }

    private func fillSizes(_ items: inout [Item]) async {
        let pending = items.indices.compactMap { index in
            items[index].sizeBytes == nil ? items[index].path.map { (index, $0) } : nil
        }
        var sizes: [Int: Int64] = [:]
        await withTaskGroup(of: (Int, Int64?).self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<8 {
                guard let next = iterator.next() else { break }
                group.addTask { (next.0, await Self.diskUsage(next.1)) }
            }
            while let result = await group.next() {
                if let size = result.1 { sizes[result.0] = size }
                if let next = iterator.next() {
                    group.addTask { (next.0, await Self.diskUsage(next.1)) }
                }
            }
        }
        for (index, size) in sizes {
            items[index].sizeBytes = size
        }
    }

    /// The allocated size from `du`. Folders that cannot be read are left out, so the size can be low for a root-owned folder.
    static func diskUsage(_ path: String) async -> Int64? {
        let result = await Shell.runOptional("du", arguments: ["-sk", path])
        guard let first = result.output.split(whereSeparator: \.isWhitespace).first, let kilobytes = Int64(first) else { return nil }
        return kilobytes * 1024
    }

    func contents(of directory: String) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func modificationDate(_ path: String) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func days(since date: Date) -> Int {
        Int(now.timeIntervalSince(date) / 86_400)
    }

    func displayPath(_ path: String) -> String {
        path.hasPrefix(roots.home + "/") ? "~" + path.dropFirst(roots.home.count) : path
    }
}
