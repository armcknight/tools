import Foundation
import Testing

@Suite("vrsn")
struct VrsnTests {
    let tmpDir: String

    init() throws {
        tmpDir = try makeTempDir()
    }

    // MARK: - xcconfig

    @Test func bumpMajorXcconfig() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 1.2.3\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["major", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "2.0.0")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("2.0.0"))
    }

    @Test func bumpMinorXcconfig() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 1.2.3\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["minor", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "1.3.0")
    }

    @Test func bumpPatchXcconfig() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 1.2.3\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["patch", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "1.2.4")
    }

    @Test func bumpNumericXcconfig() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "DYLIB_CURRENT_VERSION = 42\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["-n", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "43")
    }

    @Test func readVersionXcconfig() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 3.1.4\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["-r", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "3.1.4")
    }

    @Test func dryRunDoesNotWrite() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 1.0.0\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["-t", "major", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "2.0.0")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("1.0.0"))
    }

    @Test func customVersion() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 1.0.0\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["-u", "5.0.0-rc.1", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "5.0.0-rc.1")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("5.0.0-rc.1"))
    }

    @Test func customKey() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "MY_VERSION = 2.0.0\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["patch", "-f", path, "-k", "MY_VERSION"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "2.0.1")
    }

    @Test func withMetadata() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 1.0.0\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["patch", "-f", path, "-m", "build.42"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "1.0.1+build.42")
    }

    @Test func withIdentifier() async throws {
        let path = "\(tmpDir)/Version.xcconfig"
        try "CURRENT_PROJECT_VERSION = 1.0.0\n".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["patch", "-f", path, "-i", "beta.1"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "1.0.1-beta.1")
    }

    // MARK: - plist

    @Test func readVersionPlist() async throws {
        let path = "\(tmpDir)/Info.plist"
        let plist: NSDictionary = ["CFBundleShortVersionString": "2.5.0", "CFBundleVersion": "100"]
        plist.write(toFile: path, atomically: true)

        let result = try await ToolRunner.run("vrsn", arguments: ["-r", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "2.5.0")
    }

    @Test func bumpPatchPlist() async throws {
        let path = "\(tmpDir)/Info.plist"
        let plist: NSDictionary = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"]
        plist.write(toFile: path, atomically: true)

        let result = try await ToolRunner.run("vrsn", arguments: ["patch", "-f", path])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "1.0.1")
    }

    // MARK: - error cases

    @Test func unsupportedFileType() async throws {
        let path = "\(tmpDir)/version.json"
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await ToolRunner.run("vrsn", arguments: ["patch", "-f", path])
        #expect(result.exitCode != 0)
    }

    @Test func missingFile() async throws {
        let result = try await ToolRunner.run("vrsn", arguments: ["patch", "-f", "\(tmpDir)/nope.xcconfig"])
        #expect(result.exitCode != 0)
    }
}
