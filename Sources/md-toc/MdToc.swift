import ArgumentParser
import Foundation
import Shared

@main
struct MdToc: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write a table of contents with links to every header at the top of a Markdown file.",
        discussion: """
            The table of contents goes between `<!-- toc -->` and `<!-- tocstop -->` markers. If the markers \
            are in the file, the tool replaces what is between them. If not, it puts them after the front matter \
            and the title (an H1 that is the first line of content), or at the top of the file.

            A header that has no anchor gets one (`## <a id="slug"></a>Header`), so the links also work in \
            renderers that do not make header ids. A header keeps its anchor if it has one already, as \
            `<a id="...">`, `<a name="...">` or a trailing `{#...}`. Run the tool again after you edit the file: \
            the result does not change if the headers did not change.
            """,
        version: toolsFullVersion
    )

    @Argument(help: "Path to the Markdown file.")
    var path: String

    @Option(name: .long, help: "Do not include headers deeper than this level (1–6).")
    var maxLevel: Int = 6

    @Option(name: .long, help: "Put a header with this text above the list, e.g. \"Contents\".")
    var heading: String?

    @Flag(name: .long, help: "Do not insert anchors. Link to the ids that GitHub makes from the header text.")
    var noAnchors = false

    @Flag(name: .long, help: "Do not write the file. Exit non-zero if it is not up to date.")
    var check = false

    @Flag(name: .long, help: "Do not write the file. Print the result to stdout.")
    var dryRun = false

    func validate() throws {
        guard (1...6).contains(maxLevel) else {
            throw ValidationError("--max-level must be from 1 to 6.")
        }
    }

    func run() throws {
        let original = try FileHelpers.read(path)
        let updated = MarkdownTOC(maxLevel: maxLevel, heading: heading, insertAnchors: !noAnchors).apply(to: original)

        if dryRun {
            print(updated, terminator: "")
        } else if check {
            guard updated == original else {
                throw MdTocError.outOfDate(path)
            }
        } else if updated != original {
            try FileHelpers.write(updated, to: path)
        }
    }
}

enum MdTocError: LocalizedError {
    case outOfDate(String)

    var errorDescription: String? {
        switch self {
        case .outOfDate(let path):
            return "The table of contents in \(path) is not up to date. Run md-toc \(path)."
        }
    }
}

struct MarkdownTOC {
    static let startMarker = "<!-- toc -->"
    static let endMarker = "<!-- tocstop -->"

    let maxLevel: Int
    let heading: String?
    let insertAnchors: Bool

    private struct Header {
        let lineIndex: Int
        let level: Int
        /// The header text without the `#` characters, the closing sequence or an anchor.
        let text: String
        let explicitAnchor: String?
        /// Index in the line where the header text starts, where an anchor goes.
        let contentStart: String.Index
        var anchor = ""
    }

    func apply(to markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")

        // Remove an old table of contents, and remember where it was.
        let insertionIndex: Int
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.startMarker }),
           let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.endMarker }) {
            lines.removeSubrange(start...end)
            insertionIndex = start
        } else {
            insertionIndex = Self.titleLineIndex(lines).map { $0 + 1 } ?? Self.frontMatterEnd(lines)
        }

        var headers = parseHeaders(lines)
        assignAnchors(&headers)

        // Do not list the title.
        let title = Self.titleLineIndex(lines)
        let entries = headers.filter { $0.level <= maxLevel && $0.lineIndex != title }

        if insertAnchors {
            for header in entries where header.explicitAnchor == nil {
                var line = lines[header.lineIndex]
                line.insert(contentsOf: "<a id=\"\(header.anchor)\"></a>", at: header.contentStart)
                lines[header.lineIndex] = line
            }
        }

        // Make sure there is a blank line on each side of the block.
        var block = [Self.startMarker, ""]
        if let heading {
            block += ["## \(heading)", ""]
        }
        let minLevel = entries.map(\.level).min() ?? 1
        for header in entries {
            let indent = String(repeating: "  ", count: header.level - minLevel)
            block.append("\(indent)- [\(Self.linkText(header.text))](#\(header.anchor))")
        }
        if !entries.isEmpty {
            block.append("")
        }
        block.append(Self.endMarker)

        if insertionIndex > 0, !lines[insertionIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            block.insert("", at: 0)
        }
        if insertionIndex == lines.count || !lines[insertionIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            block.append("")
        }
        lines.insert(contentsOf: block, at: insertionIndex)

        return lines.joined(separator: "\n")
    }

    /// The line after the YAML front matter, or 0 if there is none.
    private static func frontMatterEnd(_ lines: [String]) -> Int {
        guard lines.first == "---",
              let close = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return 0 }
        return close + 1
    }

    /// The first line of content, if it is an H1.
    private static func titleLineIndex(_ lines: [String]) -> Int? {
        let start = frontMatterEnd(lines)
        guard let first = lines[start...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let header = parseHeader(lines[first], lineIndex: first), header.level == 1 else { return nil }
        return first
    }

    private func parseHeaders(_ lines: [String]) -> [Header] {
        var headers: [Header] = []
        var fence: (character: Character, count: Int)?
        var index = Self.frontMatterEnd(lines)
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix(while: { $0 == marker }).count
                if let open = fence {
                    if marker == open.character, run >= open.count,
                       trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                        fence = nil
                    }
                } else if run >= 3 {
                    fence = (marker, run)
                }
            } else if fence == nil, let header = Self.parseHeader(line, lineIndex: index) {
                headers.append(header)
            }
            index += 1
        }
        return headers
    }

    private static func parseHeader(_ line: String, lineIndex: Int) -> Header? {
        let afterIndent = line.drop(while: { $0 == " " })
        guard line.count - afterIndent.count <= 3 else { return nil }
        let hashes = afterIndent.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = afterIndent[hashes.endIndex...]
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }

        let contentStart = rest.firstIndex(where: { $0 != " " && $0 != "\t" }) ?? rest.endIndex
        var content = String(rest[contentStart...]).trimmingCharacters(in: .whitespaces)

        // Remove a closing sequence of `#` characters.
        if let closing = content.range(of: #"(^|[ \t])#+$"#, options: .regularExpression) {
            content = String(content[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        var explicitAnchor: String?
        if let match = firstCapture(#"<a\s+(?:id|name)\s*=\s*["']([^"']+)["'][^>]*>\s*</a>"#, in: content) {
            explicitAnchor = match.capture
            content.removeSubrange(match.range)
        } else if let match = firstCapture(#"\s*\{#([^}\s]+)[^}]*\}$"#, in: content) {
            explicitAnchor = match.capture
            content.removeSubrange(match.range)
        }
        content = content.trimmingCharacters(in: .whitespaces)

        guard !content.isEmpty else { return nil }
        return Header(lineIndex: lineIndex, level: hashes.count, text: content,
                      explicitAnchor: explicitAnchor, contentStart: contentStart)
    }

    private static func firstCapture(_ pattern: String, in string: String) -> (range: Range<String.Index>, capture: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range, in: string),
              let captureRange = Range(match.range(at: 1), in: string) else { return nil }
        return (range, String(string[captureRange]))
    }

    /// Give each header a unique anchor: its own if it has one, else a GitHub-style slug of its text.
    private func assignAnchors(_ headers: inout [Header]) {
        var used = Set(headers.compactMap(\.explicitAnchor))
        for i in headers.indices {
            if let explicit = headers[i].explicitAnchor {
                headers[i].anchor = explicit
                continue
            }
            let base = Self.slug(headers[i].text)
            var candidate = base
            var suffix = 1
            while used.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            headers[i].anchor = candidate
        }
    }

    /// The id GitHub makes from a header: lowercase, punctuation removed, each space changed to a hyphen.
    static func slug(_ text: String) -> String {
        let plain = linkText(text).replacingOccurrences(of: #"[*`~]"#, with: "", options: .regularExpression)
        var result = ""
        for scalar in plain.lowercased().unicodeScalars {
            if scalar == " " {
                result.append("-")
            } else if scalar == "-" || scalar == "_"
                        || CharacterSet.letters.contains(scalar)
                        || CharacterSet.decimalDigits.contains(scalar)
                        || CharacterSet.nonBaseCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "section" : result
    }

    /// Header text that can go inside a link: links become their text and HTML tags are removed.
    static func linkText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
