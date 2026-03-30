import ArgumentParser
import Foundation
import Shared

@main
struct Xcbs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dump fully-resolved Xcode build settings to lock files for diffing.",
        version: toolsVersion
    )

    @Argument(help: "Path to the .xcodeproj file.")
    var project: String

    static let exitBuildSettingsChanged: Int32 = 66

    static let settingsToUnexpand = [
        "DEVELOPER_DIR",
        "USER_APPS_DIR",
        "MODULE_CACHE_DIR",
        "OBJROOT",
        "SYMROOT",
        "SRCROOT",
        "CCHROOT",
        "USER_LIBRARY_DIR",
        "VERSION_INFO_BUILDER",
        "LEGACY_DEVELOPER_DIR",
        "PATH",
        "MAC_OS_X_PRODUCT_BUILD_VERSION",
        "MAC_OS_X_VERSION_ACTUAL",
        "MAC_OS_X_VERSION_MAJOR",
        "MAC_OS_X_VERSION_MINOR",
        "PLATFORM_PRODUCT_BUILD_VERSION",
        "XCODE_VERSION_ACTUAL",
        "XCODE_VERSION_MAJOR",
        "XCODE_VERSION_MINOR",
        "XCODE_PRODUCT_BUILD_VERSION",
    ]

    func run() async throws {
        guard FileManager.default.fileExists(atPath: project) else {
            throw XcbsError.invalidProject(project)
        }

        let schemes = try findSchemes()
        let configurations = try await listConfigurations()
        let outputPath = (project as NSString).deletingLastPathComponent + "/.xcbs"

        var settingsChanged = false

        for config in configurations {
            for scheme in schemes {
                let outputDir = "\(outputPath)/\(config)"
                try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
                let lockFile = "\(outputDir)/\(scheme).build-settings.lock"
                let tempFile = lockFile + ".new"

                // Get build settings
                var output = try await Shell.run("xcrun", arguments: [
                    "xcodebuild", "-project", project, "-scheme", scheme,
                    "-configuration", config, "-showBuildSettings"
                ])

                // Unexpand machine-specific paths
                for setting in Self.settingsToUnexpand {
                    output = unexpand(setting: setting, in: output)
                }

                try FileHelpers.write(output, to: tempFile)

                // Compare with existing lock file
                if FileManager.default.fileExists(atPath: lockFile) {
                    let existing = try FileHelpers.read(lockFile)
                    if existing != output {
                        settingsChanged = true
                    }
                    try FileManager.default.removeItem(atPath: lockFile)
                }

                try FileManager.default.moveItem(atPath: tempFile, toPath: lockFile)
            }
        }

        if settingsChanged {
            throw ExitCode(Self.exitBuildSettingsChanged)
        }
    }

    private func findSchemes() throws -> [String] {
        let sharedDataPath = "\(project)/xcshareddata/xcschemes"
        guard FileManager.default.fileExists(atPath: sharedDataPath) else {
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: sharedDataPath)
        return contents
            .filter { $0.hasSuffix(".xcscheme") }
            .map { ($0 as NSString).deletingPathExtension }
    }

    private func listConfigurations() async throws -> [String] {
        let output = try await Shell.run("xcodebuild", arguments: ["-project", project, "-list"])
        // Parse configurations from xcodebuild -list output
        var configurations: [String] = []
        var inConfigSection = false
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Build Configurations:") {
                inConfigSection = true
                continue
            }
            if inConfigSection {
                if trimmed.isEmpty || trimmed.hasPrefix("If no") {
                    break
                }
                configurations.append(trimmed)
            }
        }
        return configurations
    }

    private func unexpand(setting: String, in content: String) -> String {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: " = ")
            if parts.count >= 2 && parts[0] == setting {
                let value = parts.dropFirst().joined(separator: " = ")
                if !value.isEmpty {
                    return content.replacingOccurrences(of: value, with: setting)
                }
            }
        }
        return content
    }
}

enum XcbsError: LocalizedError {
    case invalidProject(String)

    var errorDescription: String? {
        switch self {
        case .invalidProject(let path):
            return "\(path) is not a valid Xcode project."
        }
    }
}
