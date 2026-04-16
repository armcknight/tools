# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
