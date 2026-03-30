import Foundation

public enum FileHelpers {
    /// Read the entire contents of a file as a string.
    public static func read(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FileHelperError.fileNotFound(path)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Read a file into lines (preserving empty lines).
    public static func readLines(_ path: String) throws -> [String] {
        let content = try read(path)
        return content.components(separatedBy: "\n")
    }

    /// Write a string to a file, creating parent directories if needed.
    public static func write(_ content: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Replace all occurrences of a string in a file.
    public static func replaceInFile(_ path: String, target: String, replacement: String) throws {
        var content = try read(path)
        content = content.replacingOccurrences(of: target, with: replacement)
        try write(content, to: path)
    }
}

public enum FileHelperError: LocalizedError {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}
