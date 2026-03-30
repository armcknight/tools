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
- [ ] Create `Package.swift` with executable targets and shared library
- [ ] Create `Sources/Shared/` with common utilities:
  - [ ] `Shell.swift` — run shell commands, capture output
  - [ ] `Git.swift` — status checks, commit, tag operations
  - [ ] `FileHelpers.swift` — file read/write, string replacement

### Phase 1: Changelog & versioning tools (no external dependencies)
- [ ] **migrate-changelog** — rewrite from Ruby to Swift
  - [ ] Parse Keep a Changelog format
  - [ ] Insert versioned heading with date below `## [Unreleased]`
  - [ ] `--no-commit` flag support
  - [ ] Git stage + commit
- [ ] **changetag** — rewrite from Ruby to Swift
  - [ ] Extract section for a given version from changelog
  - [ ] Create annotated git tag with extracted content
  - [ ] `--force` and `--name` flag support
  - [ ] Handle `core.commentchar` git config
- [ ] **vrsn** — port existing Swift to new package
  - [ ] Move version types (SemanticVersion, NumericVersion)
  - [ ] Move file type parsers (xcconfig, plist, podspec, gemspec)
  - [ ] Move CLI argument parsing (consider using swift-argument-parser)
  - [ ] Verify all flags work: `-f`, `-k`, `-n`, `-t`, `-r`, `-c`, `-u`, `-m`, `-i`

### Phase 2: Build & secret tools
- [ ] **xcbs** — rewrite from Bash to Swift
  - [ ] Enumerate schemes and configurations from `xcodebuild -list`
  - [ ] Run `xcodebuild -showBuildSettings` per scheme/config pair
  - [ ] Write output to `.xcbs/<config>/<scheme>.build-settings.lock`
  - [ ] Replace machine-specific paths with build setting variable names
  - [ ] Diff against existing lock files, exit 66 on changes
  - [ ] Generate pre-commit hook sample
- [ ] **psst** — rewrite from Bash to Swift
  - [ ] Read keys from `.psst/keys`
  - [ ] Resolve values from `.psst/values` → env vars → macOS Keychain (fix the `PSST_KEYCHAIN_PATH` bug from original)
  - [ ] Recursive find-and-replace in repo files
  - [ ] Skip `.psst/` directory during replacement

### Phase 3: Xcode build phase scripts & icon tagging
- [ ] **inject-git-info** — rewrite from Bash to Swift
  - [ ] Read Xcode env vars (`TARGET_BUILD_DIR`, `INFOPLIST_PATH`, `PROJECT_DIR`, `CONFIGURATION`)
  - [ ] Get git SHA, branch, clean status
  - [ ] Write to Info.plist via PlistBuddy or native plist APIs
  - [ ] Skip for "Testing" configuration
- [ ] **upload-symbols** — rewrite from Bash to Swift
  - [ ] Resolve Sentry config from env vars → `.sentryclirc` → `.env`
  - [ ] Validate `sentry-cli` is installed
  - [ ] Run `sentry-cli upload-dif` with resolved credentials
  - [ ] Skip for "Testing" configuration
- [ ] **tag-icons** — rewrite from Bash/Quartz Composer to Swift with CoreGraphics
  - [ ] Discover icons from `.appiconset` (parse `Contents.json`) or `Info.plist` `CFBundleIconFiles`
  - [ ] Modes: `commit` (git short SHA), `version` (CFBundleShortVersionString+CFBundleVersion), `custom` (arbitrary string)
  - [ ] Render text overlay onto icon using CoreGraphics (replaces Quartz Composer + Automator pipeline)
  - [ ] Scale rendering to icon dimensions
  - [ ] `cleanup` command to restore originals via `git checkout`
  - [ ] Read Xcode env vars (`INFOPLIST_FILE`, `CONFIGURATION`) for build phase usage

### Phase 4: Polish
- [ ] Add `--help` output to all tools (via swift-argument-parser)
- [ ] Add `--version` flag to all tools
- [ ] Write README.md with install/usage instructions
- [ ] Add tests for shared utilities
- [ ] Add tests for each tool's core logic (parsing, version bumping, etc.)
- [ ] Set up CI (GitHub Actions)

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI flag/argument parsing for all tools |

## Notes

- **vrsn** is already Swift — main work is porting into this package structure and modernizing (e.g., adopting swift-argument-parser instead of hand-rolled flag parsing).
- **psst** original has a bug: keychain lookup uses `${KEYCHAIN_PATH}` but the variable is set as `PSST_KEYCHAIN_PATH`. Fix during migration.
- Build phase scripts (inject-git-info, upload-symbols, tag-icons) depend on Xcode environment variables. They'll need to be compiled first, then invoked from the build phase as a binary path.
- **tag-icons** is a significant rewrite: the original uses a Quartz Composer composition + Automator workflow to render text onto images. The Swift version should use CoreGraphics directly, which is cleaner and eliminates the `.qtz`/`.workflow` dependencies. This also makes it possible to run headless in CI.
