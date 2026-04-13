TOOLS_BIN = .build/release
VERSION_FILE = Sources/Shared/Version.swift
VERSION_KEY = toolsVersion
FORMULA_PATH = homebrew-tools/tools.rb
FORMULA_PATTERN = tag: "([^"]+)"

# MARK: - Setup

.PHONY: init
init:
	git submodule update --init --recursive

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
	@NEW_VERSION=$$($(TOOLS_BIN)/vrsn -r -f $(VERSION_FILE) -k $(VERSION_KEY)) && \
	git push && git push origin "$$NEW_VERSION" && \
	$(TOOLS_BIN)/vrsn -u "$$NEW_VERSION" -f $(FORMULA_PATH) -p '$(FORMULA_PATTERN)' && \
	cd homebrew-tools && git add tools.rb && git commit -m "update to $$NEW_VERSION" && git push && cd ..
