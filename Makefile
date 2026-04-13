TOOLS_BIN = .build/release
VERSION_FILE = Sources/Shared/Version.swift
VERSION_KEY = toolsVersion
FORMULA_PATH = homebrew-tools/tools.rb
FORMULA_PATTERN = tag: "([^"]+)"


# MARK: - Dev tooling

.PHONY: build
build:
	swift build -c release

# MARK: - Testing

.PHONY: test
test:
	swift test


# MARK: - Releasing

.PHONY: deploy
deploy: build
	@test -n "$(BUMP)" || (echo "Usage: make deploy BUMP=patch|minor|major" && exit 1)
	@{ \
	$(TOOLS_BIN)/prepare-release $(BUMP) --file $(VERSION_FILE) --key $(VERSION_KEY) --tools-bin $(TOOLS_BIN) && \
	NEW_VERSION=$$($(TOOLS_BIN)/vrsn -r -f $(VERSION_FILE) -k $(VERSION_KEY)) && \
	git push && git push origin "$$NEW_VERSION" && \
	$(TOOLS_BIN)/prepare-github-release "$$NEW_VERSION" && \
	git clone git@github.com:armcknight/homebrew-tools.git homebrew-tools && \
	$(TOOLS_BIN)/vrsn -u "$$NEW_VERSION" -f $(FORMULA_PATH) -p '$(FORMULA_PATTERN)' && \
	cd homebrew-tools && git add tools.rb && git commit -m "update to $$NEW_VERSION" && git push && cd .. && \
	rm -rf homebrew-tools ; \
	} 2>&1 | tee deploy.log
