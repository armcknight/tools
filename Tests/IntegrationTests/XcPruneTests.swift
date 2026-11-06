import Foundation
import Testing

/// Runs `xcprune` against a fake directory tree through `XCPRUNE_ROOT`, which also turns off `simctl` and
/// `xcode-select`, so the tests never read or delete anything real.
@Suite("xcprune")
struct XcPruneTests {
    let root: String
    var home: String { root + "/home" }
    var deviceSupport: String { home + "/Library/Developer/Xcode/iOS DeviceSupport" }
    var derivedData: String { home + "/Library/Developer/Xcode/DerivedData" }
    var swiftPMCache: String { home + "/Library/Caches/org.swift.swiftpm" }
    var xcode: String { root + "/Applications/Xcode-26.6.0.app" }
    var installer: String { home + "/Downloads/Xcode_26.6.xip" }
    var dyldCaches: String { root + "/Library/Developer/CoreSimulator/Caches/dyld" }

    init() throws {
        root = try makeTempDir()
        for name in ["iPhone18,4 26.5 (23F77)", "iPhone18,4 27.0.1 (24A446)", "iPhone15,2 18.7.7 (22H340)", "16.4 (20E247) arm64e"] {
            try makeFile(deviceSupport + "/" + name + "/Info.plist")
        }
        try writePlist(["WorkspacePath": "/nonexistent/Gone.xcodeproj", "LastAccessedDate": Date()], to: derivedData + "/Gone-abc/info.plist")
        try writePlist(["WorkspacePath": root, "LastAccessedDate": Date()], to: derivedData + "/Fresh-def/info.plist")
        try writePlist(
            ["WorkspacePath": root, "LastAccessedDate": Date(timeIntervalSinceNow: -90 * 86_400)],
            to: derivedData + "/Stale-ghi/info.plist")
        try writePlist(["CFBundleIdentifier": "com.apple.dt.Xcode"], to: xcode + "/Contents/Info.plist")
        try writePlist(["CFBundleShortVersionString": "26.6", "ProductBuildVersion": "17F113"], to: xcode + "/Contents/version.plist")
        let simulatorSDK = xcode + "/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.6.sdk"
        try writePlist(["Version": "26.6"], to: simulatorSDK + "/SDKSettings.plist")
        try writePlist(["ProductVersion": "26.6", "ProductBuildVersion": "23G1"], to: simulatorSDK + "/System/Library/CoreServices/SystemVersion.plist")
        try FileManager.default.createSymbolicLink(
            atPath: (simulatorSDK as NSString).deletingLastPathComponent + "/iPhoneSimulator.sdk", withDestinationPath: "iPhoneSimulator26.6.sdk")
        let toolsSDKs = root + "/Library/Developer/CommandLineTools/SDKs"
        try makeFile(toolsSDKs + "/MacOSX26.1.sdk/SDKSettings.plist")
        try FileManager.default.createSymbolicLink(atPath: toolsSDKs + "/MacOSX.sdk", withDestinationPath: "MacOSX26.1.sdk")
        try makeFile(installer)
        try makeFile(swiftPMCache + "/repositories/package/HEAD")
        try FileManager.default.createDirectory(atPath: home + "/Library/Developer/CoreSimulator/Caches", withIntermediateDirectories: true)
        try makeFile(dyldCaches + "/25E5/com.apple.CoreSimulator.SimRuntime.iOS-26-1.23B86/dyld_sim_shared_cache_arm64")
        try makeFile(dyldCaches + "/25F71/com.apple.CoreSimulator.SimRuntime.iOS-26-5.23F77/dyld_sim_shared_cache_arm64")
        try FileManager.default.createDirectory(atPath: dyldCaches + "/25F71/inc", withIntermediateDirectories: true)
    }

    private func makeFile(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: path))
    }

    private func writePlist(_ dictionary: [String: Any], to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func run(_ arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await ToolRunner.run("xcprune", arguments: arguments, environment: ["XCPRUNE_ROOT": root, "XCPRUNE_MACOS_BUILD": "25F71"])
    }

    private func scan() async throws -> [[String: Any]] {
        let result = try await run(["scan", "--json"])
        #expect(result.exitCode == 0, "\(result.stderr)")
        return try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] ?? []
    }

    private func suggestedNames(_ items: [[String: Any]]) -> Set<String> {
        Set(items.filter { $0["suggested"] as? Bool == true }.compactMap { $0["name"] as? String })
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    @Test func scanSuggestsOnlyReplaceableItems() async throws {
        let items = try await scan()
        #expect(suggestedNames(items) == [
            "iPhone18,4 26.5 (23F77)", "Gone-abc", "Stale-ghi", "Xcode_26.6.xip", "Simulator dyld caches for macOS 25E5",
        ])

        let names = Set(items.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: [
            "iPhone18,4 27.0.1 (24A446)", "iPhone15,2 18.7.7 (22H340)", "16.4 (20E247) arm64e",
            "Fresh-def", "SwiftPM caches",
        ]))
        #expect(items.contains { $0["category"] as? String == "xcode" && ($0["detail"] as? String)?.hasPrefix("26.6 (17F113)") == true })
        // The empty CoreSimulator cache is left out.
        #expect(!names.contains("CoreSimulator caches"))
    }

    @Test func idsAreTheSameInEachScan() async throws {
        let first = try await scan().compactMap { $0["id"] as? String }
        let second = try await scan().compactMap { $0["id"] as? String }
        #expect(first == second)
        #expect(Set(first).count == first.count)
    }

    @Test func dryRunDeletesNothing() async throws {
        let result = try await run(["delete", "--suggested", "--dry-run"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("Would delete 5 items"))
        #expect(exists(deviceSupport + "/iPhone18,4 26.5 (23F77)"))
        #expect(exists(installer))
        #expect(exists(dyldCaches + "/25E5"))
    }

    @Test func deleteSuggestedRemovesOnlySuggestedItems() async throws {
        let result = try await run(["delete", "--suggested", "--yes"])
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(!exists(deviceSupport + "/iPhone18,4 26.5 (23F77)"))
        #expect(!exists(derivedData + "/Gone-abc"))
        #expect(!exists(derivedData + "/Stale-ghi"))
        #expect(!exists(installer))
        #expect(exists(deviceSupport + "/iPhone18,4 27.0.1 (24A446)"))
        #expect(exists(deviceSupport + "/iPhone15,2 18.7.7 (22H340)"))
        #expect(exists(derivedData + "/Fresh-def"))
        #expect(exists(xcode))
        #expect(try await scan().allSatisfy { $0["suggested"] as? Bool == false })
    }

    @Test func deleteSuggestedInOneCategory() async throws {
        let result = try await run(["delete", "--suggested", "--category", "device-support", "--yes"])
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(!exists(deviceSupport + "/iPhone18,4 26.5 (23F77)"))
        #expect(exists(derivedData + "/Gone-abc"))
        #expect(exists(installer))
    }

    @Test func deleteByIDEmptiesACacheButKeepsItsDirectory() async throws {
        let cache = try #require(try await scan().first { $0["name"] as? String == "SwiftPM caches" })
        let id = try #require(cache["id"] as? String)

        let result = try await run(["delete", id, "--yes"])
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(exists(swiftPMCache))
        #expect(try FileManager.default.contentsOfDirectory(atPath: swiftPMCache).isEmpty)
        #expect(exists(installer))
    }

    @Test func unknownIDFails() async throws {
        let result = try await run(["delete", "zzzzzz", "--yes"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("No item has the id zzzzzz"))
    }

    @Test func deleteWithoutATerminalNeedsYes() async throws {
        let result = try await run(["delete", "--suggested"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("--yes"))
        #expect(exists(installer))
    }

    @Test func treeGroupsEachXcodeWithItsSDKsAndRuntimes() async throws {
        let result = try await run(["tree", "--no-color"])
        #expect(result.exitCode == 0, "\(result.stderr)")
        let output = result.stdout
        #expect(output.contains("Xcode 26.6 (17F113)"))
        #expect(output.contains("iOS SDK 26.6"))
        // No runtimes in the fake tree, so the runtime that the simulator SDK asks for is not installed.
        #expect(output.contains("iOS runtime 23G1  for the iOS 26.6 SDK · not installed"))
        #expect(output.contains("Device support"))
        #expect(output.contains("iPhone18,4 (iOS)"))
        #expect(output.contains("DerivedData"))
        #expect(output.contains("Downloaded installers"))
        // Command Line Tools lists real SDK folders, not the symbolic links to them.
        #expect(output.contains("MacOSX26.1.sdk"))
        #expect(!output.contains("MacOSX.sdk"))
        #expect(!output.contains("\u{1B}["))
    }

    @Test func treeShowsTheSameIDsAsScan() async throws {
        let ids = try await scan().compactMap { $0["id"] as? String }
        let output = try await run(["tree", "--no-color"]).stdout
        for id in ids {
            #expect(output.contains(id), "id \(id) is missing from the tree")
        }
        let suggested = try await scan().filter { $0["suggested"] as? Bool == true }.compactMap { $0["id"] as? String }
        for id in suggested {
            #expect(output.contains("\(id) * "), "suggested id \(id) has no *")
        }
    }

    @Test func treeDepthOneShowsOnlyTheGroups() async throws {
        let output = try await run(["tree", "--no-color", "--depth", "1"]).stdout
        #expect(output.contains("Device support"))
        #expect(!output.contains("├─"))
        #expect(!output.contains("└─"))
    }

    @Test func deleteNeedsIDsOrSuggested() async throws {
        let result = try await run(["delete"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("--suggested"))
    }

    @Test func dyldCachesAreListedPerMacOSBuildAndRuntime() async throws {
        let caches = try await scan().filter { ($0["name"] as? String)?.hasPrefix("Simulator dyld cache") == true }
        let byName = Dictionary(uniqueKeysWithValues: caches.compactMap { item in (item["name"] as? String).map { ($0, item) } })
        #expect(Set(byName.keys) == ["Simulator dyld caches for macOS 25E5", "Simulator dyld cache: iOS 26.5 (23F77)"])
        // A folder for another macOS build is never used again. The running build's caches come back, so they are not suggested.
        #expect(byName["Simulator dyld caches for macOS 25E5"]?["suggested"] as? Bool == true)
        #expect(byName["Simulator dyld cache: iOS 26.5 (23F77)"]?["suggested"] as? Bool == false)

        let id = try #require(byName["Simulator dyld caches for macOS 25E5"]?["id"] as? String)
        let result = try await run(["delete", id, "--yes"])
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(!exists(dyldCaches + "/25E5"))
        #expect(exists(dyldCaches + "/25F71/com.apple.CoreSimulator.SimRuntime.iOS-26-5.23F77"))
    }
}
