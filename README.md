# tools

A collection of developer tools for Apple platform projects, all written in Swift.

## Tools

| Tool | Description |
|------|-------------|
| `migrate-changelog` | Move Unreleased changelog entries to a new versioned section |
| `changetag` | Extract changelog sections and write them as annotated git tags |
| `vrsn` | Bump semantic or numeric version numbers in xcconfig, plist, podspec, gemspec, Swift, and arbitrary files (via regex) |
| `prepare-release` | Bump version, migrate changelog, tag, push, and create a GitHub release in one step; supports RC cycles and semver build metadata |
| `prepare-github-release` | Create a GitHub release from a git tag with changelog-derived release notes |
| `read-changelog` | Print a changelog section to stdout by tag name or latest git tag |
| `xcbs` | Dump fully-resolved Xcode build settings to lock files for diffing |
| `psst` | Inject secrets from a values file, env vars, or macOS Keychain into source placeholders |
| `inject-git-info` | Write git SHA, branch, and clean status into Info.plist (Xcode build phase) |
| `upload-symbols` | Upload dSYM files to Sentry (Xcode build phase) |
| `tag-icons` | Overlay version/commit/custom text onto app icons (Xcode build phase) |

## Requirements

- Swift 6.1+
- macOS 13+

## Installation

```
brew tap armcknight/tools
brew install armcknight/tools/tools
```

## Development

### Building and testing

```bash
make build   # Release build
make test    # Run unit and integration tests
```

### Local install

```bash
make install    # Build and install dev binaries (unlinks Homebrew version)
make uninstall  # Remove dev binaries and restore Homebrew version
```

`make install` replaces the Homebrew-managed binaries with locally built ones for testing. `make uninstall` reverses this by re-linking the Homebrew version.

### Releasing

```bash
make deploy-beta             # Tag an RC from [Unreleased], push, create GitHub prerelease
make deploy BUMP=patch       # Bump patch, consolidate RC entries, tag, push, update Homebrew formula
make deploy BUMP=minor
make deploy BUMP=major
```

`deploy-beta` can be run multiple times before a final release — each run creates the next `RC` tag (e.g. `1.0.0-RC1`, `1.0.0-RC2`). When `make deploy` runs, all RC changelog sections are consolidated into the final release entry.

## Usage

Every tool supports `--help` and `--version`.

### migrate-changelog

```
migrate-changelog CHANGELOG.md 1.2.0
migrate-changelog CHANGELOG.md 1.2.0 --no-commit
```

### changetag

```
changetag CHANGELOG.md 1.2.0
changetag CHANGELOG.md 1.2.0 --commit --message "bump version to 1.2.0"
changetag CHANGELOG.md v1.2.0 --name 1.2.0
```

### vrsn

```
vrsn major -f Config.xcconfig
vrsn minor -f Config.xcconfig -k CURRENT_PROJECT_VERSION
vrsn patch -f Info.plist
vrsn -n -f Config.xcconfig                  # bump numeric version
vrsn -r -f Config.xcconfig                  # read current version
vrsn major -t -f Config.xcconfig            # dry run
vrsn -u 2.0.0-beta.1 -f Config.xcconfig     # set custom version
vrsn patch -f Sources/Shared/Version.swift -k toolsVersion   # Swift file
vrsn patch -f Formula/tools.rb -p 'tag: "([^"]+)"'          # regex pattern for any file format
```

### prepare-release

```
# Bump patch/minor/major — migrates changelog, commits, tags, pushes, creates GitHub release
prepare-release patch --file Sources/Shared/Version.swift --key toolsVersion --push --github-release
prepare-release minor --file Sources/Shared/Version.swift --key toolsVersion --push --github-release
prepare-release major --file Sources/Shared/Version.swift --key toolsVersion --push --github-release

# Release candidate — tags [Unreleased] as RC without bumping the version file
prepare-release rc --file Sources/Shared/Version.swift --key toolsVersion --push --github-release --prerelease

# iOS-style: separate marketing version and build number
# The build number is appended as semver metadata (+N) in the changelog entry and git tag only.
prepare-release rc --file Config.xcconfig --key MARKETING_VERSION --build-number 42 --push --github-release --prerelease
prepare-release patch --file Config.xcconfig --key MARKETING_VERSION --build-number 43 --push --github-release
```

`prepare-release` prints the resolved tag name to stdout, so callers can capture it:

```bash
NEW_VERSION=$(prepare-release patch --file ...)
```

RC tags are auto-numbered by counting existing RC tags for the current version. Use `--rc-number` to override.

### prepare-github-release

```
prepare-github-release 1.2.0                          # create release from tag with changelog notes
prepare-github-release 1.2.0 --draft                  # create as draft
prepare-github-release 1.2.0 --prerelease             # mark as prerelease
prepare-github-release 1.2.0 --changelog path/to/CHANGELOG.md
```

### read-changelog

```
read-changelog CHANGELOG.md --latest-tag        # print the section for the most recent git tag
read-changelog CHANGELOG.md --tag 1.2.0         # print the section for a specific tag
read-changelog CHANGELOG.md --tag 1.0-RC1+42    # works with semver metadata and RC tags
```

Useful in Fastfiles and scripts that need release notes:

```ruby
# fastlane/Fastfile
changelog_text = sh("read-changelog ../CHANGELOG.md --latest-tag").strip
upload_to_testflight(changelog: changelog_text)
```

### xcbs

```
xcbs MyProject.xcodeproj
```

Exit code 66 means build settings changed from the previous lock files.

To use as a git pre-commit hook, copy `Resources/xcbs/pre-commit.sample` to `.git/hooks/pre-commit`.

### psst

```
psst                          # use .psst/values and env vars
psst /path/to/keychain        # also check macOS Keychain
```

Keys are defined in `.psst/keys`, values in `.psst/values` (gitignored).

### inject-git-info

As an Xcode build phase:

```
${PATH_TO_TOOLS}/inject-git-info
```

Or with explicit arguments:

```
inject-git-info --plist-path /path/to/Info.plist --project-dir /path/to/project
```

### upload-symbols

As an Xcode build phase:

```
${PATH_TO_TOOLS}/upload-symbols
```

Resolves Sentry credentials from environment variables, `~/.sentryclirc`, or a `.env` file.

### tag-icons

As an Xcode build phase:

```
${PATH_TO_TOOLS}/tag-icons version /path/to/AppIcon.appiconset
${PATH_TO_TOOLS}/tag-icons commit /path/to/AppIcon.appiconset
${PATH_TO_TOOLS}/tag-icons custom /path/to/AppIcon.appiconset "beta"
${PATH_TO_TOOLS}/tag-icons cleanup /path/to/AppIcon.appiconset
```

## Testing

```
swift test
```

## License

MIT
