VERSION_FILE = Sources/Shared/Version.swift
VERSION_KEY = toolsVersion

# Keep this in sync with `binaries` in .github/workflows/release.yml. The release
# workflow writes that list into the cask's binary lines, so the tap needs no edit.
BINARIES = changetag check-release-ready inject-git-info migrate-changelog ota-publish \
           prepare-github-release prepare-release psst read-changelog \
           spm-acknowledgements tag-icons upload-symbols vrsn xcbs

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)


# MARK: - Dev tooling

.PHONY: build
build: ## Build all tools in release configuration
	swift build -c release

.PHONY: test
test: ## Run the test suite
	swift test


# MARK: - Local install

# Drops locally-built binaries into the homebrew prefix's bin/, replacing the
# cask-installed symlinks. Run `make uninstall` to restore the Homebrew cask.
.PHONY: install
install: build ## Build and install local binaries into the Homebrew prefix (shadows the cask)
	@BREW_PREFIX=$$(brew --prefix) && \
	for tool in $(BINARIES); do \
		rm -f $$BREW_PREFIX/bin/$$tool; \
		install .build/release/$$tool $$BREW_PREFIX/bin/; \
	done
	@echo "Installed local tools to $$(brew --prefix)/bin (shadows the Homebrew cask)"

.PHONY: uninstall
uninstall: ## Remove locally installed binaries and restore the Homebrew cask
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
patch: ## Bump the patch version and commit
	vrsn patch -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

.PHONY: minor
minor: ## Bump the minor version and commit
	vrsn minor -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

.PHONY: major
major: ## Bump the major version and commit
	vrsn major -f $(VERSION_FILE) -k $(VERSION_KEY) --commit

.PHONY: deploy-beta
deploy-beta: ## Tag and push a release candidate (prerelease)
	@{ \
	prepare-release rc --file $(VERSION_FILE) --key $(VERSION_KEY) --push --prerelease ; \
	} 2>&1 | tee deploy.log

.PHONY: deploy
deploy: ## Tag and push a release
	@{ \
	prepare-release --file $(VERSION_FILE) --key $(VERSION_KEY) --push ; \
	} 2>&1 | tee deploy.log
