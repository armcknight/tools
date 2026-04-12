import ArgumentParser
import Foundation
import Shared

@main
struct Vrsn: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bump version numbers in project files.",
        discussion: "Supports xcconfig, plist, podspec, and gemspec files.",
        version: toolsVersion
    )

    @Argument(help: "Version component to bump: major, minor, or patch.")
    var component: String?

    @Option(name: .shortAndLong, help: "Path to the file containing the version.")
    var file: String

    @Option(name: .shortAndLong, help: "Key mapping to the version value in the file.")
    var key: String?

    @Flag(name: [.customShort("n"), .long], help: "Treat version as a single integer (numeric).")
    var numeric = false

    @Flag(name: [.customShort("t"), .customLong("try")], help: "Dry run — compute new version without writing.")
    var dryRun = false

    @Flag(name: [.customShort("r"), .customLong("read")], help: "Read and print the current version.")
    var readVersion = false

    @Option(name: [.customShort("c"), .customLong("current-version")], help: "Override the current version instead of reading from file.")
    var currentVersion: String?

    @Option(name: [.customShort("u"), .long], help: "Write a custom version string directly.")
    var custom: String?

    @Option(name: [.customShort("m"), .customLong("metadata")], help: "Build metadata string to append.")
    var metadata: String?

    @Option(name: [.customShort("i"), .customLong("identifier")], help: "Prerelease identifier to append.")
    var identifier: String?

    func run() throws {
        let fileType = try FileType.detect(from: file)
        let resolvedKey = key ?? fileType.defaultKey(numeric: numeric)

        // Read current version
        let currentVersionString: String
        if let override = currentVersion {
            currentVersionString = override
        } else {
            currentVersionString = try fileType.readVersion(from: file, key: resolvedKey)
        }

        if readVersion {
            print(currentVersionString)
            return
        }

        // Determine new version
        let newVersion: String
        if let custom {
            newVersion = custom
        } else if numeric {
            guard let value = UInt(currentVersionString) else {
                throw VrsnError.couldNotParse(currentVersionString)
            }
            newVersion = formatVersion(String(value + 1), identifier: identifier, metadata: metadata)
        } else {
            guard let comp = component else {
                throw VrsnError.missingComponent
            }
            let parts = currentVersionString.split(separator: ".").compactMap { UInt(String($0.split(separator: "-").first ?? $0)) }
            guard parts.count == 3 else {
                throw VrsnError.couldNotParse(currentVersionString)
            }
            var major = parts[0], minor = parts[1], patch = parts[2]

            switch comp.lowercased() {
            case "major":
                major += 1; minor = 0; patch = 0
            case "minor":
                minor += 1; patch = 0
            case "patch":
                patch += 1
            default:
                throw VrsnError.invalidComponent(comp)
            }
            newVersion = formatVersion("\(major).\(minor).\(patch)", identifier: identifier, metadata: metadata)
        }

        if dryRun {
            print(newVersion)
            return
        }

        try fileType.writeVersion(newVersion, to: file, key: resolvedKey)
        print(newVersion)
    }

    private func formatVersion(_ base: String, identifier: String?, metadata: String?) -> String {
        var result = base
        if let identifier { result += "-\(identifier)" }
        if let metadata { result += "+\(metadata)" }
        return result
    }
}

// MARK: - File type handling

enum FileType {
    case xcconfig
    case plist
    case podspec
    case gemspec
    case swift
    case plaintext

    static func detect(from path: String) throws -> FileType {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "xcconfig": return .xcconfig
        case "plist": return .plist
        case "podspec": return .podspec
        case "gemspec": return .gemspec
        case "swift": return .swift
        default: return .plaintext
        }
    }

    func defaultKey(numeric: Bool) -> String {
        switch self {
        case .xcconfig:
            return numeric ? "DYLIB_CURRENT_VERSION" : "CURRENT_PROJECT_VERSION"
        case .plist:
            return numeric ? "CFBundleVersion" : "CFBundleShortVersionString"
        case .podspec, .gemspec:
            return "version"
        case .swift, .plaintext:
            return ""
        }
    }

    func readVersion(from path: String, key: String) throws -> String {
        switch self {
        case .xcconfig:
            return try readFromTextFile(path: path, key: key, separator: " = ", commentPrefix: "//")
        case .plist:
            guard let dict = Plist.readDictionary(from: path),
                  let value = dict[key] as? String else {
                throw VrsnError.noVersionFound(key, path)
            }
            return value
        case .podspec, .gemspec:
            return try readFromTextFile(path: path, key: key, separator: "=", commentPrefix: "#")
        case .swift:
            return try readFromTextFile(path: path, key: key, separator: " = ", commentPrefix: "//")
        case .plaintext:
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw VrsnError.noVersionFound("", path)
            }
            return trimmed
        }
    }

    func writeVersion(_ version: String, to path: String, key: String) throws {
        switch self {
        case .xcconfig:
            try writeToTextFile(path: path, key: key, value: version, separator: " = ", commentPrefix: "//")
        case .plist:
            guard let dict = Plist.readDictionary(from: path)?.mutableCopy() as? NSMutableDictionary else {
                throw VrsnError.couldNotReadFile(path)
            }
            dict[key] = version
            guard Plist.writeDictionary(dict, to: path) else {
                throw VrsnError.couldNotWriteFile(path)
            }
        case .podspec, .gemspec:
            try writeToTextFile(path: path, key: key, value: "'\(version)'", separator: "=", commentPrefix: "#")
        case .swift:
            try writeToTextFile(path: path, key: key, value: "\"\(version)\"", separator: " = ", commentPrefix: "//")
        case .plaintext:
            try FileHelpers.write(version + "\n", to: path)
        }
    }

    private func readFromTextFile(path: String, key: String, separator: String, commentPrefix: String) throws -> String {
        let lines = try FileHelpers.readLines(path)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(commentPrefix) || trimmed.isEmpty { continue }
            if trimmed.contains(key) && trimmed.contains(separator) {
                let parts = trimmed.components(separatedBy: separator)
                if parts.count >= 2 {
                    var value = parts.dropFirst().joined(separator: separator)
                        .trimmingCharacters(in: .whitespaces)
                    // Strip inline comments
                    if let commentRange = value.range(of: commentPrefix) {
                        value = String(value[..<commentRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                    }
                    // Strip quotes
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    return value
                }
            }
        }
        throw VrsnError.noVersionFound(key, path)
    }

    private func writeToTextFile(path: String, key: String, value: String, separator: String, commentPrefix: String) throws {
        var lines = try FileHelpers.readLines(path)
        var found = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(commentPrefix) || trimmed.isEmpty { continue }
            if trimmed.contains(key) && trimmed.contains(separator) {
                let parts = trimmed.components(separatedBy: separator)
                if parts.count >= 2 {
                    lines[i] = "\(parts[0])\(separator)\(value)"
                    found = true
                    break
                }
            }
        }
        guard found else {
            throw VrsnError.noVersionFound(key, path)
        }
        try FileHelpers.write(lines.joined(separator: "\n"), to: path)
    }
}

enum VrsnError: LocalizedError {
    case missingComponent
    case invalidComponent(String)
    case couldNotParse(String)
    case unsupportedFileType(String)
    case noVersionFound(String, String)
    case couldNotReadFile(String)
    case couldNotWriteFile(String)

    var errorDescription: String? {
        switch self {
        case .missingComponent:
            return "Specify a version component to bump: major, minor, or patch."
        case .invalidComponent(let c):
            return "Invalid component '\(c)'. Use major, minor, or patch."
        case .couldNotParse(let v):
            return "Could not parse version string: \(v)"
        case .unsupportedFileType(let ext):
            return "Unsupported file type: .\(ext)"
        case .noVersionFound(let key, let path):
            return "No version found for key '\(key)' in \(path)"
        case .couldNotReadFile(let path):
            return "Could not read file: \(path)"
        case .couldNotWriteFile(let path):
            return "Could not write file: \(path)"
        }
    }
}
