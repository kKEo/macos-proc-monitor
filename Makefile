.DEFAULT_GOAL := help
.PHONY: help releases last-release next-version check release

# Releases run on GitHub Actions (.github/workflows/release.yml); see docs/development.md, "Releasing".
# Options for release: VERSION=x.y.z, or BUMP=patch|minor|major (default patch) to take the next one;
# WATCH=0 returns without waiting, DRY_RUN=1 only runs the checks, YES=1 skips the confirmation.

help: ## Show this list of targets
	@echo "usage: make <target> [VERSION=x.y.z] [BUMP=patch|minor|major] [WATCH=0] [DRY_RUN=1] [YES=1]"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

releases: ## List every released version, newest first
	@Support/releases.sh list

last-release: ## Show the latest published release
	@Support/releases.sh last

next-version: ## Show the version the next release would get (BUMP=patch|minor|major)
	@Support/releases.sh next "$(BUMP)"

check: ## Check that VERSION is not tagged or released yet
	@Support/releases.sh check "$(VERSION)"

release: ## Start a release: VERSION=x.y.z, or the next version by BUMP (default patch)
	@Support/releases.sh start "$(VERSION)"
