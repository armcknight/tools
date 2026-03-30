import Foundation
import Testing
@testable import Shared

@Suite("Shell")
struct ShellTests {
    @Test func runEcho() async throws {
        let output = try await Shell.run("echo", arguments: ["hello"])
        #expect(output == "hello")
    }

    @Test func runWithWorkingDirectory() async throws {
        let output = try await Shell.run("pwd", workingDirectory: "/tmp")
        #expect(output.contains("tmp"))
    }

    @Test func runFailingCommandThrows() async {
        await #expect(throws: ShellError.self) {
            try await Shell.run("false")
        }
    }

    @Test func runOptionalSuccess() async {
        let result = await Shell.runOptional("echo", arguments: ["ok"])
        #expect(result.success)
        #expect(result.output == "ok")
    }

    @Test func runOptionalFailure() async {
        let result = await Shell.runOptional("false")
        #expect(!result.success)
    }
}
