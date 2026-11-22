#!/bin/bash
# Start a release on GitHub Actions and follow it to the end.
#
#   Support/start_release.sh 0.2.1            (or: make release VERSION=0.2.1)
#   WATCH=0 Support/start_release.sh 0.2.1    start it and return
#   DRY_RUN=1 Support/start_release.sh 0.2.1  only run the checks
#
# The Release workflow bumps PmonVersion on master, tags, builds, signs and publishes; see
# docs/development.md. It releases what is on GitHub's master, so local commits must be pushed first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
VERSION="${VERSION#v}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "usage: make release VERSION=x.y.z   (x.y.z-rc.1 for a pre-release)" >&2
    exit 2
fi
command -v gh >/dev/null || { echo "the GitHub CLI (gh) is needed: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in: run gh auth login" >&2; exit 1; }

echo "== checking"
git fetch --quiet --tags origin master
AHEAD="$(git rev-list --count origin/master..master)"
if [ "$AHEAD" != 0 ]; then
    echo "master has $AHEAD commit(s) not on GitHub; push them first (git push origin master)" >&2
    exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
    echo "tag v$VERSION already exists on GitHub" >&2
    exit 1
fi
CURRENT="$(git show origin/master:Sources/PmonCore/Config/Config.swift | sed -nE 's/.*public static let string = "([^"]*)".*/\1/p')"
echo "releasing $VERSION from origin/master $(git rev-parse --short origin/master) (code is at $CURRENT)"

if [ "${DRY_RUN:-0}" = 1 ]; then echo "dry run: not starting the workflow"; exit 0; fi

echo "== starting the Release workflow"
OUT="$(gh workflow run release.yml --ref master -f "version=$VERSION" 2>&1)"
echo "$OUT"
RUN_ID="$(grep -oE 'actions/runs/[0-9]+' <<<"$OUT" | head -1 | cut -d/ -f3 || true)"

if [ "${WATCH:-1}" = 0 ] || [ -z "$RUN_ID" ]; then
    [ -z "$RUN_ID" ] && echo "follow it with: gh run list --workflow release.yml"
    exit 0
fi
gh run watch "$RUN_ID" --exit-status
echo "== released: $(gh release view "v$VERSION" --json url --jq .url)"
echo "run 'git pull' to get the version bump commit"
