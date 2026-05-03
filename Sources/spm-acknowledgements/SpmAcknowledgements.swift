import ArgumentParser
import Foundation
import Shared

@main
struct SpmAcknowledgements: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a CocoaPods-compatible acknowledgements plist from SPM dependencies.",
        version: toolsVersion
    )

    @Option(name: [.customShort("p"), .customLong("package-resolved")],
            help: "Path to Package.resolved. Auto-detected: ./Package.resolved, then *.xcodeproj/.../swiftpm/Package.resolved.")
    var packageResolved: String?

    @Option(name: [.customShort("c"), .long],
            help: "Path to the SPM checkouts directory. Auto-detected: $BUILD_DIR/../../SourcePackages/checkouts (Xcode), then .build/checkouts (SPM).")
    var checkouts: String?

    @Option(name: [.customShort("o"), .long],
            help: "Output path for the generated plist.")
    var output: String = "acknowledgements.plist"

    @Flag(name: [.customShort("v"), .long],
          help: "Print detailed progress to stderr.")
    var verbose = false

    func run() throws {
        log("working directory: \(FileManager.default.currentDirectoryPath)")

        let resolvedPath = try packageResolved ?? resolvePackageResolvedPath()
        log("package-resolved: \(resolvedPath)")

        let checkoutsPath = try checkouts ?? resolveCheckoutsPath()
        log("checkouts: \(checkoutsPath)")

        log("output: \(output)")

        let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
        let resolved = try JSONDecoder().decode(PackageResolved.self, from: data)

        log("pins in Package.resolved: \(resolved.pins.count)")

        var entries: [(name: String, license: String, text: String)] = []
        for pin in resolved.pins {
            guard pin.kind == "remoteSourceControl" else {
                log("  skipping \(pin.identity) (kind: \(pin.kind))")
                continue
            }

            let dirName = pin.location
                .components(separatedBy: "/").last?
                .replacingOccurrences(of: ".git", with: "") ?? pin.identity

            let checkoutDir = (checkoutsPath as NSString).appendingPathComponent(dirName)
            guard let licenseText = findLicenseText(in: checkoutDir) else {
                log("  warning: no license found for \(pin.identity) in \(checkoutDir)")
                print("warning: no license found for \(pin.identity) in \(checkoutDir)")
                continue
            }

            let licenseType = detectLicenseType(from: licenseText)
            log("  \(dirName): \(licenseType)")
            entries.append((
                name: dirName,
                license: licenseType,
                text: licenseText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        entries.sort { $0.name.lowercased() < $1.name.lowercased() }

        let header: [String: String] = [
            "Type": "PSGroupSpecifier",
            "Title": "Acknowledgements",
            "FooterText": "This application makes use of the following third party libraries:"
        ]
        let libraryEntries = entries.map { e -> [String: String] in
            ["Type": "PSGroupSpecifier", "Title": e.name, "License": e.license, "FooterText": e.text]
        }
        let plist: [String: Any] = [
            "PreferenceSpecifiers": [header] + libraryEntries,
            "StringsTable": "Acknowledgements",
            "Title": "Acknowledgements"
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: URL(fileURLWithPath: output))
        print("Wrote \(entries.count) entr\(entries.count == 1 ? "y" : "ies") to \(output)")
    }

    // MARK: - Path resolution

    private func resolvePackageResolvedPath() throws -> String {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath

        let plain = (cwd as NSString).appendingPathComponent("Package.resolved")
        if fm.fileExists(atPath: plain) {
            log("  found Package.resolved at cwd root")
            return plain
        }

        let contents = (try? fm.contentsOfDirectory(atPath: cwd)) ?? []
        log("  scanning cwd for *.xcodeproj: \(contents.filter { $0.hasSuffix(".xcodeproj") })")
        if let proj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let embedded = ((cwd as NSString).appendingPathComponent(proj) as NSString)
                .appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
            if fm.fileExists(atPath: embedded) {
                log("  found Package.resolved inside \(proj)")
                return embedded
            }
            log("  no Package.resolved inside \(proj) at \(embedded)")
        }

        throw SpmAcknowledgementsError.packageResolvedNotFound(cwd)
    }

    private func resolveCheckoutsPath() throws -> String {
        let fm = FileManager.default

        if let buildDir = ProcessInfo.processInfo.environment["BUILD_DIR"] {
            let path = ((buildDir as NSString).appendingPathComponent("../..") as NSString)
                .appendingPathComponent("SourcePackages/checkouts")
            let resolved = (path as NSString).standardizingPath
            log("  BUILD_DIR set — trying \(resolved)")
            if fm.fileExists(atPath: resolved) {
                log("  found checkouts via BUILD_DIR")
                return resolved
            }
            log("  checkouts not found at BUILD_DIR-derived path")
        } else {
            log("  BUILD_DIR not set")
        }

        let spm = (fm.currentDirectoryPath as NSString).appendingPathComponent(".build/checkouts")
        log("  trying .build/checkouts at \(spm)")
        if fm.fileExists(atPath: spm) {
            log("  found checkouts via .build/checkouts")
            return spm
        }

        throw SpmAcknowledgementsError.checkoutsNotFound
    }

    // MARK: - Logging

    private func log(_ message: String) {
        guard verbose else { return }
        fputs("spm-acknowledgements: \(message)\n", stderr)
    }

    // MARK: - License helpers

    private func findLicenseText(in dir: String) -> String? {
        let candidates = ["LICENSE", "LICENSE.txt", "LICENSE.md",
                          "License", "License.txt", "License.md",
                          "LICENCE", "LICENCE.txt",
                          "COPYING", "COPYING.txt"]
        return candidates.lazy
            .map { (dir as NSString).appendingPathComponent($0) }
            .compactMap { try? FileHelpers.read($0) }
            .first
    }

    private func detectLicenseType(from text: String) -> String {
        let u = text.uppercased()
        if u.contains("MIT LICENSE") || (u.contains("MIT") && u.contains("PERMISSION IS HEREBY GRANTED")) { return "MIT" }
        if u.contains("APACHE LICENSE") { return "Apache 2.0" }
        if u.contains("BSD 3-CLAUSE") { return "BSD 3-Clause" }
        if u.contains("BSD 2-CLAUSE") { return "BSD 2-Clause" }
        if u.contains("REDISTRIBUTION AND USE IN SOURCE AND BINARY FORMS") { return "BSD" }
        if u.contains("ISC LICENSE") || (u.contains("ISC") && u.contains("PERMISSION TO USE")) { return "ISC" }
        if u.contains("MOZILLA PUBLIC LICENSE") { return "MPL 2.0" }
        if u.contains("GNU LESSER GENERAL PUBLIC LICENSE") { return "LGPL" }
        if u.contains("GNU GENERAL PUBLIC LICENSE") { return "GPL" }
        return "Unknown"
    }
}

// MARK: - Package.resolved model

struct PackageResolved: Decodable {
    let pins: [Pin]

    struct Pin: Decodable {
        let identity: String
        let kind: String
        let location: String
        let state: State

        struct State: Decodable {
            let revision: String
            let version: String?
        }
    }
}

// MARK: - Errors

enum SpmAcknowledgementsError: LocalizedError {
    case packageResolvedNotFound(String)
    case checkoutsNotFound

    var errorDescription: String? {
        switch self {
        case .packageResolvedNotFound(let cwd):
            return "Could not find Package.resolved in '\(cwd)'. Pass --package-resolved explicitly."
        case .checkoutsNotFound:
            return "Could not find a checkouts directory. Pass --checkouts explicitly."
        }
    }
}
