# tools

A collection of developer tools for Apple platform projects, all written in Swift.

## Tools

| Tool | Description |
|------|-------------|
| `migrate-changelog` | Move Unreleased changelog entries to a new versioned section |
| `changetag` | Extract changelog sections and write them as annotated git tags |
| `vrsn` | Bump semantic or numeric version numbers in xcconfig, plist, podspec, gemspec, Swift, and arbitrary files (via regex) |
| `prepare-release` | Bump version, migrate changelog, tag, push, and create a GitHub release in one step; supports RC cycles and semver build metadata |
| `check-release-ready` | Exit non-zero unless the checkout is clean, has an upstream, and is not behind it; put it in front of a deploy command |
| `prepare-github-release` | Create a GitHub release from a git tag with changelog-derived release notes |
| `read-changelog` | Print a changelog section to stdout by tag name or latest git tag |
| `xcbs` | Dump fully-resolved Xcode build settings to lock files for diffing |
| `psst` | Inject secrets from a values file, env vars, or macOS Keychain into source placeholders |
| `inject-git-info` | Write git SHA, branch, and clean status into Info.plist (Xcode build phase) |
| `upload-symbols` | Upload dSYM files to Sentry (Xcode build phase) |
| `tag-icons` | Overlay version/commit/custom text onto app icons (Xcode build phase) |
| `ota-publish` | Upload an ad-hoc iOS `.ipa` to S3 and emit a short-lived itms-services OTA install landing page |
| `spm-acknowledgements` | Generate an acknowledgements file from SPM dependency licenses |

## Requirements

- Swift 6.1+
- macOS 13+

## Installation

Shipped as a binary-only Homebrew cask. Source lives in this (private) repo; built binaries are uploaded to releases on `armcknight/homebrew-tools` and installed via cask. Apple Silicon only (`aarch64-apple-darwin`).

```
brew tap armcknight/tools
brew trust armcknight/tools   # third-party taps require explicit trust
brew install --cask armcknight/tools/tools
```

## Development

### Building and testing

```bash
make build   # Release build
make test    # Run unit and integration tests
```

### Local install

```bash
make install    # Build and install dev binaries (shadows the Homebrew cask)
make uninstall  # Remove dev binaries; reinstalls the Homebrew cask if one was present
```

`make install` replaces the cask-installed binary symlinks at `$(brew --prefix)/bin/` with locally built ones for testing. `make uninstall` removes them and reinstalls the cask via `brew reinstall --cask tools`.

### Releasing

```bash
make patch                   # Bump patch version (must run before first deploy-beta in a cycle)
make minor                   # Bump minor version
make major                   # Bump major version
make deploy-beta             # Tag an RC from [Unreleased] and push
make deploy                  # Consolidate RC entries, tag, push
```

The `release` GitHub Actions workflow runs on every numeric tag push. It builds the binaries on `macos-14` (arm64), tarballs them, creates a release on `armcknight/homebrew-tools` with the tarball attached, and updates the appropriate cask there:

- tag `X.Y.Z` → `Casks/tools.rb` (stable channel — what `brew install --cask tools` gets)
- tag `X.Y.Z-RCN` → `Casks/tools-rc.rb` (release-candidate channel — opt-in via `brew install --cask armcknight/tools/tools-rc`)

So `make deploy` and `make deploy-beta` only handle the source-side tag push — the homebrew side is fully automated. (`tools` and `tools-rc` casks are marked `conflicts_with` each other, so brew won't let you have both installed at once.)

#### One-time secret setup

The workflow needs a `TAP_RELEASE_TOKEN` repo secret on `tools`. Create a **fine-grained personal access token** with:

- **Repository access**: `armcknight/homebrew-tools` only
- **Permissions**:
  - `Contents`: Read and write (for `git push` of the cask bump + creating releases)
  - `Metadata`: Read-only (auto-granted)

Add it at `Settings → Secrets and variables → Actions → New repository secret` with name `TAP_RELEASE_TOKEN`. (The same PAT used for `workr` can be reused — fine-grained tokens may grant access to multiple repos.)

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

With `--push`, it fetches first and errors before it changes anything if the current branch is behind its upstream, or has no upstream. Pull, then run it again.

```
# Final release — migrates changelog, commits, tags, pushes, creates GitHub release
# (version must already be bumped in the file)
prepare-release --file Sources/Shared/Version.swift --key toolsVersion --push --github-release

# Plain VERSION file — --key is optional
prepare-release --file VERSION --push --github-release

# JSON and other formats --key cannot read — locate the version by regex instead.
# Same capture-group semantics as `vrsn --pattern`.
prepare-release --file plugin.json --pattern '"version": "([^"]+)"' --push --github-release

# Release candidate — tags [Unreleased] as RC; pass rc as the first argument
prepare-release rc --file Sources/Shared/Version.swift --key toolsVersion --push --github-release --prerelease

# iOS-style: separate marketing version and build number
# --build-number-key auto-increments CURRENT_PROJECT_VERSION and appends it as +N.
prepare-release rc --file Config.xcconfig --key MARKETING_VERSION --build-number-key CURRENT_PROJECT_VERSION --push --github-release --prerelease
prepare-release --file Config.xcconfig --key MARKETING_VERSION --build-number-key CURRENT_PROJECT_VERSION --push --github-release

# Or supply the build number explicitly instead of auto-incrementing:
prepare-release rc --file Config.xcconfig --key MARKETING_VERSION --build-number 42 --push --github-release --prerelease

# A second tag family in the same repository: the version file holds 1.0.0, the tag,
# changelog section and commit message use v1.0.0 (v1.1.0-RC1 for a release candidate).
prepare-release --file templates/VERSION --changelog templates/CHANGELOG.md --tag-prefix v --push --github-release
```

`prepare-release` prints the resolved tag name to stdout, so callers can capture it:

```bash
NEW_VERSION=$(prepare-release --file ...)
```

`--tag-prefix` keeps two families of tags apart in one repository. Give each family its own version file and changelog. The "forgot to bump" check removes the prefix from the changelog section before it compares it to the version file. `--pattern` cannot do this, because vrsn reads the capture, so the tag would still be the bare version.

RC tags are auto-numbered by scanning consecutive RC sections in the changelog — numbering is sequential even when the base version changes mid-cycle (e.g. `1.2.4-RC1` → `1.3.0-RC2` → `2.0.0-RC3`). Use `--rc-number` to override.

When a final release follows an RC cycle, `prepare-release` detects the existing RC sections and consolidates all of them into the final release entry regardless of their version prefix. A final release after an RC cycle requires an empty `[Unreleased]` section, so it ships only changes that a release candidate tested. A release candidate, or a final release with no RC cycle, requires entries in `[Unreleased]`.

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

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) for the full text.
