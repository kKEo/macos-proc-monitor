.PHONY: release

# Start a release on GitHub Actions and follow it: make release VERSION=0.2.1
# WATCH=0 starts it without waiting; DRY_RUN=1 only runs the checks. See docs/development.md, "Releasing".
release:
	@Support/start_release.sh "$(VERSION)"
