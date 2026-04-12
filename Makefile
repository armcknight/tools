TOOLS_BIN = .build/release
VERSION_FILE = Sources/Shared/Version.swift
VERSION_KEY = toolsVersion

# MARK: - Dev tooling

.PHONY: build
build:
	swift build -c release

# MARK: - Testing

.PHONY: test
test:
	swift test

# MARK: - Versioning

.PHONY: bump-patch bump-minor bump-major

bump-patch:
	@$(TOOLS_BIN)/prepare-release patch --file $(VERSION_FILE) --key $(VERSION_KEY) --tools-bin $(TOOLS_BIN)

bump-minor:
	@$(TOOLS_BIN)/prepare-release minor --file $(VERSION_FILE) --key $(VERSION_KEY) --tools-bin $(TOOLS_BIN)

bump-major:
	@$(TOOLS_BIN)/prepare-release major --file $(VERSION_FILE) --key $(VERSION_KEY) --tools-bin $(TOOLS_BIN)

# MARK: - Releasing

.PHONY: release
release: build
