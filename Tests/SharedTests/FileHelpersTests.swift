import Foundation
import Testing
@testable import Shared

@Suite("FileHelpers")
struct FileHelpersTests {
    let tmpDir: String

    init() throws {
        tmpDir = NSTemporaryDirectory() + "tools-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    @Test func readWriteRoundTrip() throws {
        let path = "\(tmpDir)/test.txt"
        let content = "Hello, world!\nLine 2\n"
        try FileHelpers.write(content, to: path)
        let result = try FileHelpers.read(path)
        #expect(result == content)
    }

    @Test func readLines() throws {
        let path = "\(tmpDir)/lines.txt"
        try FileHelpers.write("a\nb\nc", to: path)
        let lines = try FileHelpers.readLines(path)
        #expect(lines == ["a", "b", "c"])
    }

    @Test func readLinesPreservesEmpty() throws {
        let path = "\(tmpDir)/empty-lines.txt"
        try FileHelpers.write("a\n\nb", to: path)
        let lines = try FileHelpers.readLines(path)
        #expect(lines == ["a", "", "b"])
    }

    @Test func readNonexistentFileThrows() {
        #expect(throws: FileHelperError.self) {
            try FileHelpers.read("\(tmpDir)/nonexistent.txt")
        }
    }

    @Test func replaceInFile() throws {
        let path = "\(tmpDir)/replace.txt"
        try FileHelpers.write("foo bar foo", to: path)
        try FileHelpers.replaceInFile(path, target: "foo", replacement: "baz")
        let result = try FileHelpers.read(path)
        #expect(result == "baz bar baz")
    }

    @Test func writeCreatesIntermediateDirectories() throws {
        let path = "\(tmpDir)/deep/nested/dir/file.txt"
        try FileHelpers.write("nested", to: path)
        let result = try FileHelpers.read(path)
        #expect(result == "nested")
    }
}
