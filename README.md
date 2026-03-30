# tools

A collection of developer tools for Apple platform projects, all written in Swift.

## Tools

| Tool | Description |
|------|-------------|
| `migrate-changelog` | Move Unreleased changelog entries to a new versioned section |
| `changetag` | Extract changelog sections and write them as git tag annotations |
| `vrsn` | Bump semantic or numeric version numbers in xcconfig, plist, podspec, gemspec files |
| `xcbs` | Dump fully-resolved Xcode build settings to lock files for diffing |
| `psst` | Inject secrets from a values file, env vars, or macOS Keychain into source placeholders |
| `inject-git-info` | Write git SHA, branch, and clean status into Info.plist (Xcode build phase) |
| `upload-symbols` | Upload dSYM files to Sentry (Xcode build phase) |
| `tag-icons` | Overlay version/commit/custom text onto app icons (Xcode build phase) |

## Requirements

- Swift 6.1+
- macOS 13+

## Installation

Build all tools:

```
swift build -c release
```

Binaries are output to `.build/release/`. Copy individual tools to a directory on your `$PATH`:

```
cp .build/release/vrsn /usr/local/bin/
```

Or build and install a specific tool:

```
swift build -c release --product vrsn
cp .build/release/vrsn /usr/local/bin/
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
changetag CHANGELOG.md 1.2.0 --force
changetag CHANGELOG.md v1.2.0 --name 1.2.0
```

### vrsn

```
vrsn major -f Config.xcconfig
vrsn minor -f Config.xcconfig -k CURRENT_PROJECT_VERSION
vrsn patch -f Info.plist
vrsn -n -f Config.xcconfig                  # bump numeric version
vrsn -r -f Config.xcconfig                  # read current version
vrsn -t major -f Config.xcconfig             # dry run
vrsn -u 2.0.0-beta.1 -f Config.xcconfig     # set custom version
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
