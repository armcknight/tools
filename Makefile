VERSION_FILE = Sources/Shared/Version.swift
VERSION_KEY = toolsVersion

# Keep this in sync with the cask in armcknight/homebrew-tools.
BINARIES = changetag inject-git-info migrate-changelog ota-publish \
           prepare-github-release prepare-release psst read-changelog \
           spm-acknowledgements tag-icons upload-symbols vrsn xcbs


# MARK: - Dev tooling

.PHONY: build
build:
	swift build -c release

.PHONY: test
test:
	swift test


# MARK: - Local install

# Drops locally-built binaries into the homebrew prefix's bin/, replacing the
# cask-installed symlinks. Run `make uninstall` to restore the Homebrew cask.
.PHONY: install
install: build
	@BREW_PREFIX=$$(brew --prefix) && \
	for tool in $(BINARIES); do \
		rm -f $$BREW_PREFIX/bin/$$tool; \
		install .build/release/$$tool $$BREW_PREFIX/bin/; \
	done
	@echo "Installed local tools to $$(brew --prefix)/bin (shadows the Homebrew cask)"

.PHONY: uninstall
uninstall:
	@BREW_PREFIX=$$(brew --prefix) && \
	for tool in $(BINARIES); do \
		rm -f $$BREW_PREFIX/bin/$$tool; \
	done
	@if brew list --cask tools >/dev/null 2>&1; then \
		brew reinstall --cask tools; \
	else \
		echo "No Homebrew cask version to restore — run \`brew install --cask armcknight/tools/tools\` if you want one."; \
	fi


# MARK: - Releasing

# Bumps the version + git tag + push. The release workflow on this repo picks
# up the tag, builds the binaries, uploads them to armcknight/homebrew-tools
# as release assets, and updates the cask there.

.PHONY: patch
patch:
	vrsn patch -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

.PHONY: minor
minor:
	vrsn minor -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

.PHONY: major
major:
	vrsn major -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

.PHONY: deploy-beta
deploy-beta:
	@{ \
	prepare-release rc --file $(VERSION_FILE) --key $(VERSION_KEY) --push --prerelease ; \
	} 2>&1 | tee deploy.log

.PHONY: deploy
deploy:
	@{ \
	prepare-release --file $(VERSION_FILE) --key $(VERSION_KEY) --push ; \
	} 2>&1 | tee deploy.log
