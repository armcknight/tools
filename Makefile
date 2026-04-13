VERSION_FILE = Sources/Shared/Version.swift
VERSION_KEY = toolsVersion
FORMULA_PATH = homebrew-tools/tools.rb
FORMULA_PATTERN = tag: "([^"]+)"


# MARK: - Dev tooling

.PHONY: build
build:
	swift build -c release

# MARK: - Install

.PHONY: install
install: build
	brew unlink tools 2>/dev/null || true
	@BREW_PREFIX=$$(brew --prefix) && \
	for tool in changetag inject-git-info migrate-changelog prepare-github-release prepare-release psst tag-icons upload-symbols vrsn xcbs; do \
		install .build/release/$$tool $$BREW_PREFIX/bin/; \
	done
	@echo "Installed dev tools to $$(brew --prefix)/bin (run 'brew link tools' to restore Homebrew version)"

.PHONY: uninstall
uninstall:
	@BREW_PREFIX=$$(brew --prefix) && \
	for tool in changetag inject-git-info migrate-changelog prepare-github-release prepare-release psst tag-icons upload-symbols vrsn xcbs; do \
		rm -f $$BREW_PREFIX/bin/$$tool; \
	done
	brew link tools 2>/dev/null || true
	@echo "Restored Homebrew-managed tools"

# MARK: - Testing

.PHONY: test
test:
	swift test


# MARK: - Releasing

.PHONY: deploy
deploy:
	@test -n "$(BUMP)" || (echo "Usage: make deploy BUMP=patch|minor|major" && exit 1)
	@{ \
	prepare-release $(BUMP) --file $(VERSION_FILE) --key $(VERSION_KEY) && \
	NEW_VERSION=$$(vrsn -r -f $(VERSION_FILE) -k $(VERSION_KEY)) && \
	git push && git push origin "$$NEW_VERSION" && \
	prepare-github-release "$$NEW_VERSION" && \
	git clone git@github.com:armcknight/homebrew-tools.git homebrew-tools && \
	vrsn -u "$$NEW_VERSION" -f $(FORMULA_PATH) -p '$(FORMULA_PATTERN)' && \
	cd homebrew-tools && git add tools.rb && git commit -m "update to $$NEW_VERSION" && git push && cd .. && \
	rm -rf homebrew-tools ; \
	} 2>&1 | tee deploy.log
