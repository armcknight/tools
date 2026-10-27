import Foundation
import Testing

@Suite("md-toc")
struct MdTocTests {
    let tmpDir: String
    let path: String

    init() throws {
        tmpDir = try makeTempDir()
        path = "\(tmpDir)/README.md"
    }

    private func write(_ markdown: String) throws {
        try markdown.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test func insertsTocAfterTitleAndAnchorsHeaders() async throws {
        try write("""
        # Title

        Intro.

        ## Getting Started

        ### Install `foo` & [bar](https://example.com)

        ## Usage
        """)

        let result = try await ToolRunner.run("md-toc", arguments: [path])
        #expect(result.exitCode == 0)

        #expect(try read() == """
        # Title

        <!-- toc -->

        - [Getting Started](#getting-started)
          - [Install `foo` & bar](#install-foo--bar)
        - [Usage](#usage)

        <!-- tocstop -->

        Intro.

        ## <a id="getting-started"></a>Getting Started

        ### <a id="install-foo--bar"></a>Install `foo` & [bar](https://example.com)

        ## <a id="usage"></a>Usage
        """)
    }

    @Test func secondRunChangesNothing() async throws {
        try write("# Title\n\n## One\n\n## Two\n")
        _ = try await ToolRunner.run("md-toc", arguments: [path])
        let first = try read()

        let result = try await ToolRunner.run("md-toc", arguments: [path, "--check"])
        #expect(result.exitCode == 0)
        _ = try await ToolRunner.run("md-toc", arguments: [path])
        #expect(try read() == first)
    }

    @Test func replacesTocBetweenMarkers() async throws {
        try write("""
        Intro.

        <!-- toc -->
        - [Old](#old)
        <!-- tocstop -->

        ## New
        """)

        _ = try await ToolRunner.run("md-toc", arguments: [path])
        let content = try read()
        #expect(content.hasPrefix("Intro.\n\n<!-- toc -->\n"))
        #expect(content.contains("- [New](#new)"))
        #expect(!content.contains("#old"))
    }

    @Test func keepsExistingAnchorsAndMakesDuplicatesUnique() async throws {
        try write("""
        ## <a name="custom"></a>Anchored

        ## Attribute {#attr}

        ## Same

        ## Same
        """)

        _ = try await ToolRunner.run("md-toc", arguments: [path])
        let content = try read()
        #expect(content.contains("- [Anchored](#custom)"))
        #expect(content.contains("- [Attribute](#attr)"))
        #expect(content.contains("- [Same](#same)\n- [Same](#same-1)"))
        #expect(content.contains("## <a name=\"custom\"></a>Anchored"))
        #expect(content.contains("## Attribute {#attr}"))
        #expect(content.contains("## <a id=\"same-1\"></a>Same"))
    }

    @Test func skipsCodeBlocksAndFrontMatter() async throws {
        try write("""
        ---
        title: x
        ---

        ## Real

        ```sh
        # comment
        ```

        ~~~~
        ## also code
        ~~~~

        #hashtag
        """)

        _ = try await ToolRunner.run("md-toc", arguments: [path])
        let content = try read()
        #expect(content.hasPrefix("---\ntitle: x\n---\n\n<!-- toc -->"))
        #expect(content.contains("<!-- toc -->\n\n- [Real](#real)\n\n<!-- tocstop -->"))
    }

    @Test func noAnchorsLeavesHeadersAlone() async throws {
        try write("# Title\n\n## One\n\n### Two\n")
        _ = try await ToolRunner.run("md-toc", arguments: [path, "--no-anchors", "--max-level", "2", "--heading", "Contents"])
        #expect(try read() == """
        # Title

        <!-- toc -->

        ## Contents

        - [One](#one)

        <!-- tocstop -->

        ## One

        ### Two

        """)
    }

    @Test func checkFailsWhenOutOfDate() async throws {
        try write("## One\n")
        let result = try await ToolRunner.run("md-toc", arguments: [path, "--check"])
        #expect(result.exitCode != 0)
        #expect(try read() == "## One\n")
    }

    @Test func dryRunPrintsWithoutWriting() async throws {
        try write("## One\n")
        let result = try await ToolRunner.run("md-toc", arguments: [path, "--dry-run"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("- [One](#one)"))
        #expect(try read() == "## One\n")
    }
}
