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
make patch                   # Bump patch version (must run before first deploy-beta in a cycle)
make minor                   # Bump minor version
make major                   # Bump major version
make deploy-beta             # Tag an RC from [Unreleased], push, create GitHub prerelease
make deploy                  # Consolidate RC entries, tag, push, update Homebrew formula
```

Version bumping and deploying are separate steps. Bump first, then deploy as many RCs as needed:

```bash
make minor                   # 1.2.3 → 1.3.0
make deploy-beta             # tags 1.3.0-RC1
make deploy-beta             # tags 1.3.0-RC2 (new RC, no version re-bump needed)
make deploy                  # consolidates all RC sections into 1.3.0
```

To change the target version mid-cycle, bump again before the next RC:

```bash
make minor                   # 1.2.3 → 1.3.0
make deploy-beta             # 1.3.0-RC1
make major                   # 1.3.0 → 2.0.0  (scope grew)
make deploy-beta             # 2.0.0-RC2
make deploy                  # consolidates all RC sections into 2.0.0
```

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
vrsn minor -f Config.xcconfig -k MARKETING_VERSION --commit  # bump and commit in one step
vrsn minor -f Config.xcconfig -k MARKETING_VERSION --commit --stash  # stash other staged changes first
```

### prepare-release

Version bumping is the caller's responsibility. Run `vrsn` (or `make patch/minor/major`) before calling `prepare-release`. It will error if the version in `--file` matches the most recent non-RC changelog section, catching the "forgot to bump" case.

```
# Final release — migrates changelog, commits, tags, pushes, creates GitHub release
# (version must already be bumped in the file)
prepare-release --file Sources/Shared/Version.swift --key toolsVersion --push --github-release

# Plain VERSION file — --key is optional
prepare-release --file VERSION --push --github-release

# Release candidate — tags [Unreleased] as RC; pass rc as the first argument
prepare-release rc --file Sources/Shared/Version.swift --key toolsVersion --push --github-release --prerelease

# iOS-style: separate marketing version and build number
# --build-number-key auto-increments CURRENT_PROJECT_VERSION and appends it as +N.
prepare-release rc --file Config.xcconfig --key MARKETING_VERSION --build-number-key CURRENT_PROJECT_VERSION --push --github-release --prerelease
prepare-release --file Config.xcconfig --key MARKETING_VERSION --build-number-key CURRENT_PROJECT_VERSION --push --github-release

# Or supply the build number explicitly instead of auto-incrementing:
prepare-release rc --file Config.xcconfig --key MARKETING_VERSION --build-number 42 --push --github-release --prerelease
```

`prepare-release` prints the resolved tag name to stdout, so callers can capture it:

```bash
NEW_VERSION=$(prepare-release --file ...)
```

RC tags are auto-numbered by scanning consecutive RC sections in the changelog — numbering is sequential even when the base version changes mid-cycle (e.g. `1.2.4-RC1` → `1.3.0-RC2` → `2.0.0-RC3`). Use `--rc-number` to override.

When a final release follows an RC cycle, `prepare-release` detects the existing RC sections and consolidates all of them into the final release entry regardless of their version prefix.

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
