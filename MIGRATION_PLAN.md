# Tools Migration Plan

Central collection of developer tools, all as Swift scripts.

## Tool Inventory

| # | Tool | Source | Original Language | Description |
|---|------|--------|-------------------|-------------|
| 1 | `migrate-changelog` | [TwoRingSoft/tools](https://github.com/TwoRingSoft/tools/blob/master/bin/migrate-changelog) | Ruby | Moves the "Unreleased" section in a Keep a Changelog file into a new versioned entry with today's date. Optionally commits. |
| 2 | `changetag` | [TwoRingSoft/tools](https://github.com/TwoRingSoft/tools/blob/master/bin/changetag) | Ruby | Extracts release notes from a changelog and writes them as a git tag annotation. |
| 3 | `xcbs` | [TwoRingSoft/xcbs](https://github.com/TwoRingSoft/xcbs) | Bash | Dumps fully-resolved Xcode build settings per scheme/config to `.lock` files for diffing. Replaces machine-specific paths with variable names. |
| 4 | `vrsn` | [TwoRingSoft/Vrsnr](https://github.com/TwoRingSoft/Vrsnr) | Swift | Bumps semantic or numeric version numbers in xcconfig, plist, podspec, gemspec files. |
| 5 | `psst` | [TwoRingSoft/psst](https://github.com/TwoRingSoft/psst) | Bash | Injects secrets from `.psst/values`, env vars, or macOS Keychain into source file placeholders. |
| 6 | `inject-git-info` | trigonometry/scripts | Bash | Xcode build phase script that writes git SHA, branch, and clean status into Info.plist. |
| 7 | `upload-symbols` | trigonometry/scripts | Bash | Xcode build phase script that uploads dSYM files to Sentry via `sentry-cli`. |
| 8 | `tag-icons` | [TwoRingSoft/XcodeIconTagger](https://github.com/TwoRingSoft/XcodeIconTagger) | Bash | Overlays version/commit/custom text onto app icons for beta builds. Uses Quartz Composer + Automator — reimplement with CoreGraphics. |

## Project Structure

```
tools/
├── Package.swift
├── Sources/
│   ├── Shared/              # Common utilities (shell exec, git helpers, file I/O)
│   ├── migrate-changelog/   # Tool 1
│   ├── changetag/           # Tool 2
│   ├── xcbs/                # Tool 3
│   ├── vrsn/                # Tool 4 (port existing Swift code)
│   ├── psst/                # Tool 5
│   ├── inject-git-info/     # Tool 6
│   ├── upload-symbols/      # Tool 7
│   └── tag-icons/           # Tool 8
├── Tests/
│   └── ...
├── MIGRATION_PLAN.md
└── README.md
```

Each tool is a separate executable target in a single Swift package. Shared code (process execution, git operations, file manipulation) lives in a library target.

## Migration Checklist

### Phase 0: Project scaffolding
- [x] Create `Package.swift` with executable targets and shared library
- [x] Create `Sources/Shared/` with common utilities:
  - [x] `Shell.swift` — wrapper around swift-subprocess for running commands
  - [x] `Plist.swift` — read/write plist files via PlistBuddy
  - [x] `FileHelpers.swift` — file read/write, string replacement
  - Note: git operations use [armcknight/git-kit](https://github.com/armcknight/git-kit) instead of a custom Git.swift

### Phase 1: Changelog & versioning tools (no external dependencies)
- [x] **migrate-changelog** — rewrite from Ruby to Swift
  - [x] Parse Keep a Changelog format
  - [x] Insert versioned heading with date below `## [Unreleased]`
  - [x] `--no-commit` flag support
  - [x] Git stage + commit
- [x] **changetag** — rewrite from Ruby to Swift
  - [x] Extract section for a given version from changelog
  - [x] Create annotated git tag with extracted content
  - [x] `--force` and `--name` flag support
  - [x] Handle `core.commentchar` git config
- [x] **vrsn** — rewrite with swift-argument-parser
  - [x] Version types (semantic + numeric)
  - [x] File type parsers (xcconfig, plist, podspec, gemspec)
  - [x] All flags: `-f`, `-k`, `-n`, `-t`, `-r`, `-c`, `-u`, `-m`, `-i`

### Phase 2: Build & secret tools
- [x] **xcbs** — rewrite from Bash to Swift
  - [x] Enumerate schemes and configurations from `xcodebuild -list`
  - [x] Run `xcodebuild -showBuildSettings` per scheme/config pair
  - [x] Write output to `.xcbs/<config>/<scheme>.build-settings.lock`
  - [x] Replace machine-specific paths with build setting variable names
  - [x] Diff against existing lock files, exit 66 on changes
  - [x] Generate pre-commit hook sample
- [x] **psst** — rewrite from Bash to Swift
  - [x] Read keys from `.psst/keys`
  - [x] Resolve values from `.psst/values` → env vars → macOS Keychain (fixed the `PSST_KEYCHAIN_PATH` bug from original)
  - [x] Recursive find-and-replace in repo files
  - [x] Skip `.psst/` directory during replacement

### Phase 3: Xcode build phase scripts & icon tagging
- [x] **inject-git-info** — rewrite from Bash to Swift
  - [x] Read Xcode env vars (`TARGET_BUILD_DIR`, `INFOPLIST_PATH`, `PROJECT_DIR`, `CONFIGURATION`)
  - [x] Get git SHA, branch, clean status
  - [x] Write to Info.plist via PlistBuddy
  - [x] Skip for "Testing" configuration
- [x] **upload-symbols** — rewrite from Bash to Swift
  - [x] Resolve Sentry config from env vars → `.sentryclirc` → `.env`
  - [x] Validate `sentry-cli` is installed
  - [x] Run `sentry-cli upload-dif` with resolved credentials
  - [x] Skip for "Testing" configuration
- [x] **tag-icons** — rewrite from Bash/Quartz Composer to Swift with CoreGraphics
  - [x] Discover icons from `.appiconset` (parse `Contents.json`) or directory of PNGs
  - [x] Modes: `commit` (git short SHA), `version` (CFBundleShortVersionString+CFBundleVersion), `custom` (arbitrary string)
  - [x] Render text overlay onto icon using CoreGraphics + CoreText
  - [x] Scale rendering to icon dimensions
  - [x] `cleanup` command to restore originals via `git checkout`
  - [x] Read Xcode env vars (`INFOPLIST_FILE`) for build phase usage

### Phase 4: Polish
- [x] Add `--help` output to all tools (via swift-argument-parser — automatic)
- [x] Add `--version` flag to all tools (shared `toolsVersion` constant)
- [x] Write README.md with install/usage instructions
- [x] Add tests for shared utilities (FileHelpers, Shell, Version)
- [ ] Add tests for each tool's core logic (parsing, version bumping, etc.)
- [ ] Set up CI (GitHub Actions)

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI flag/argument parsing for all tools |
| [swift-subprocess](https://github.com/swiftlang/swift-subprocess) | Shell command execution (via Shared library) |
| [git-kit](https://github.com/armcknight/git-kit) | Git operations wrapper |

## Notes

- **vrsn** was rewritten from scratch using swift-argument-parser rather than porting the original hand-rolled CLI parsing.
- **psst** original had a bug: keychain lookup used `${KEYCHAIN_PATH}` but the variable was set as `PSST_KEYCHAIN_PATH`. Fixed in the Swift version.
- Build phase scripts (inject-git-info, upload-symbols, tag-icons) depend on Xcode environment variables. They need to be compiled first, then invoked from the build phase as a binary path.
- **tag-icons** was significantly rewritten: the original used a Quartz Composer composition + Automator workflow to render text onto images. The Swift version uses CoreGraphics + CoreText directly, eliminating the `.qtz`/`.workflow` dependencies and enabling headless CI usage.
