# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [4.2.0] 2026-05-02

### Added
- `prepare-release` validates that the `[Unreleased]` section is non-empty before mutating anything (incrementing build number, creating tag), so a forgotten changelog entry fails fast without leaving partial state to undo

## [4.1.0] 2026-05-02

### Added
- `spm-acknowledgements` — generates a CocoaPods-compatible `PreferenceSpecifiers` acknowledgements plist from `Package.resolved` and an SPM checkouts directory; drop-in replacement for the plist CocoaPods used to generate automatically; auto-detects `Package.resolved` and the checkouts directory for both Xcode and pure-SPM projects

## [4.0.1] 2026-04-30

### Fixed
- `prepare-release` now forwards `--changelog` to `prepare-github-release`, so non-default changelog paths are respected when creating GitHub releases.

## [4.0.0] 2026-04-16

### Added
- `vrsn --commit` — after writing the new version, stages the changed file and creates a commit with the message `"bumped version from X to Y"` (or `"bumped build from X to Y"` in `--numeric` mode); errors if other changes are staged unless `--stash` is also given
- `vrsn --stash` — before committing, stashes any other staged changes via `git stash --staged`, then restores them after; requires `--commit`
- `prepare-release --build-number-key KEY` — auto-increments the numeric value at `KEY` in `--file` via `vrsn -n` and appends the result as semver build metadata (`+N`) in the changelog entry and git tag; supersedes `--build-number` when both are given
- `prepare-release` validates that the marketing version was bumped before running, using the changelog as the source of truth (compares the version file against the most recent non-RC section header); errors with an actionable message if the version was not bumped

### Changed
- `prepare-release` no longer accepts `patch`, `minor`, or `major` as arguments and no longer bumps version files internally; version bumping is now the caller's responsibility (e.g. `make patch` / `make minor` / `make major`)
- `prepare-release` component argument is now optional: pass `rc` for a release candidate, or omit it for a final release
- `prepare-release --key` is now optional; when omitted, the version file is treated as a plain `VERSION`-style file containing only the version string (no `KEY = VALUE` format required)

## [3.0.0] 2026-04-16

### Added
- `prepare-release rc` — create a release candidate tag (`<version>-RC<N>`) from the `[Unreleased]` changelog section without bumping the version or migrating the changelog; RC number is auto-detected from existing tags or overridden with `--rc-number`
- `prepare-release --build-number <N>` — append semver build metadata (`+N`) to the changelog entry heading and git tag in both release and RC modes; the version file itself is not affected (mirrors iOS `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` separation)

### Changed
- `changetag --name` now exclusively controls which changelog section to look up; the tag annotation title is always the tag name (previously `--name` also overrode the annotation title)

## [2.0.0] 2026-04-12

### Changed
- `prepare-release` no longer requires `--tools-bin`; tools are resolved from PATH (Homebrew install)

## [1.1.0] 2026-04-12

### Added
- `prepare-github-release` — create GitHub releases from git tags with changelog-derived release notes via `gh`

## [1.0.0] 2026-04-12

These tools are a Swift rewrite of a previous collection of Ruby scripts hosted at https://github.com/tworingsoft/tools.

### Added
- Homebrew tap distribution via `brew tap armcknight/tools` with `homebrew-tools` submodule and `make release` automation
- `vrsn` — bump version numbers in xcconfig, plist, podspec, gemspec, and Swift source files; supports major/minor/patch components, numeric (integer) mode, custom strings, dry-run, read modes, and `--pattern` regex for arbitrary file formats
- `migrate-changelog` — move Unreleased changelog entries to a new versioned section dated today; `--no-commit` leaves changes staged without committing
- `changetag` — extract release notes from a changelog section and write them into an annotated git tag; `--commit` stages all working tree changes and commits them with a provided message before tagging
- `prepare-release` — orchestrate a full semantic version release: bumps the version file, migrates the changelog, and creates an annotated tag in one step
- `inject-git-info` — inject commit hash, branch name, and clean-status into a built Info.plist at Xcode build time; designed for use as an Xcode Run Script build phase
- `tag-icons` — overlay version number, commit hash, or custom text onto app icon images using CoreGraphics; supports commit, version, custom, and cleanup modes; designed for use as an Xcode Run Script build phase
- `upload-symbols` — upload dSYM files to Sentry; resolves credentials from environment variables, `.sentryclirc`, or `.env`
- `psst` — inject secrets into source file placeholders; resolves values from `.psst/values`, environment variables, or a macOS keychain file
- `xcbs` — dump fully-resolved Xcode build settings to per-scheme lock files for diffing across configurations; exits with code 66 if settings changed since the last run
