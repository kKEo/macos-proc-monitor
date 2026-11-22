#!/bin/bash
# Releases on GitHub: list them, work out the next version, and start one. Used by the Makefile.
#
#   Support/releases.sh list                     every version tagged on GitHub, newest first
#   Support/releases.sh last                     the latest published release
#   Support/releases.sh next [patch|minor|major] the version the next release would get
#   Support/releases.sh check <version>          is the version free? (exit 1 if taken)
#   Support/releases.sh start [version]          start the Release workflow and follow it
#                                                (no version: the next one, by BUMP, default patch)
# Environment: BUMP=patch|minor|major, WATCH=0 (do not wait), DRY_RUN=1 (checks only), YES=1 (no prompt).
#
# The Release workflow bumps PmonVersion on master, tags, builds, signs and publishes; see
# docs/development.md. It releases what is on GitHub's master, so local commits must be pushed first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

die() { echo "$*" >&2; exit 1; }

need_gh() {
    command -v gh >/dev/null || die "the GitHub CLI (gh) is needed: brew install gh"
    gh auth status >/dev/null 2>&1 || die "gh is not signed in: run gh auth login"
}

# A key that sorts like semantic versions: numbers numerically, and 1.0.0-rc.1 before 1.0.0.
sort_key() {
    local v="$1" core pre=""
    core="${v%%-*}"
    [[ "$v" == *-* ]] && pre="${v#*-}"
    IFS=. read -r ma mi pa <<<"$core"
    if [ -z "$pre" ]; then printf '%06d.%06d.%06d.1.\n' "$ma" "$mi" "$pa"; else printf '%06d.%06d.%06d.0.%s\n' "$ma" "$mi" "$pa" "$pre"; fi
}

# Versions from stdin, newest first.
sort_versions() {
    while read -r v; do [ -n "$v" ] && printf '%s %s\n' "$(sort_key "$v")" "$v"; done | sort -r | cut -d' ' -f2
}

# Every version tagged on GitHub (a tag exists even when its release failed).
remote_versions() {
    git ls-remote --tags --refs origin 'v*' | sed -E 's#.*refs/tags/v##' | grep -E "$VERSION_RE" | sort_versions || true
}

# tag<TAB>date<TAB>kind for every release on GitHub.
releases_json() {
    gh release list --limit 200 --json tagName,publishedAt,isPrerelease,isDraft \
        --jq '.[] | [.tagName, (.publishedAt // "" | .[0:10]), (if .isDraft then "draft" elif .isPrerelease then "pre-release" else "release" end)] | @tsv'
}

code_version() {
    git show "${1:-HEAD}:Sources/PmonCore/Config/Config.swift" | sed -nE 's/.*public static let string = "([^"]*)".*/\1/p'
}

cmd_list() {
    need_gh
    local versions releases
    versions="$(remote_versions)"
    releases="$(releases_json)"
    if [ -z "$versions" ]; then echo "No versions released yet."; return; fi
    printf '%-16s %-12s %s\n' "VERSION" "DATE" "STATUS"
    while read -r v; do
        local row
        row="$(awk -F'\t' -v t="v$v" '$1 == t' <<<"$releases")"
        if [ -n "$row" ]; then
            printf '%-16s %-12s %s\n' "$v" "$(cut -f2 <<<"$row")" "$(cut -f3 <<<"$row")"
        else
            printf '%-16s %-12s %s\n' "$v" "-" "tag only, no release (the run failed or is still going)"
        fi
    done <<<"$versions"
}

# The newest published release of a kind ("release" or "pre-release"); empty when there is none.
last_release() {
    releases_json | awk -F'\t' -v k="${1:-release}" '$3 == k {print $1}' | sed 's/^v//' | grep -E "$VERSION_RE" | sort_versions | head -1 || true
}

cmd_last() {
    need_gh
    local v pre
    v="$(last_release release)"
    pre="$(last_release pre-release)"
    if [ -n "$v" ]; then
        gh release view "v$v" --json tagName,name,publishedAt,url --jq '"\(.tagName)  \(.publishedAt[0:10])  \(.name)\n\(.url)"'
    else
        echo "No release published yet."
    fi
    if [ -n "$pre" ] && { [ -z "$v" ] || [ "$(printf '%s\n%s\n' "$pre" "$v" | sort_versions | head -1)" = "$pre" ]; }; then
        echo "Newer pre-release: v$pre"
    fi
}

# The next version: the latest tag bumped by `patch`, `minor` or `major`. A pre-release bumps to its
# own final version (0.3.0-rc.1 -> 0.3.0). With no tags yet, the version in the code is released as is,
# and when the code is already ahead of the latest tag (bumped by hand) its version is used.
next_version() {
    local bump="${1:-patch}" latest code ma mi pa
    case "$bump" in patch|minor|major) ;; *) die "BUMP must be patch, minor or major, not '$bump'" ;; esac
    git fetch --quiet origin master
    latest="$(remote_versions | head -1)"
    code="$(code_version origin/master)"
    if [ -z "$latest" ]; then echo "$code"; return; fi
    if [[ "$code" =~ $VERSION_RE ]] && [ "$(printf '%s\n%s\n' "$code" "$latest" | sort_versions | head -1)" = "$code" ] && [ "$code" != "$latest" ]; then
        echo "$code"; return
    fi
    IFS=. read -r ma mi pa <<<"${latest%%-*}"
    if [[ "$latest" == *-* ]]; then
        # A pre-release: its final version is next, unless a bigger step was asked for.
        case "$bump" in
            patch) ;;
            minor) [ "$pa" = 0 ] || { mi=$((mi + 1)); pa=0; } ;;
            major) [ "$mi" = 0 ] && [ "$pa" = 0 ] || { ma=$((ma + 1)); mi=0; pa=0; } ;;
        esac
    else
        case "$bump" in
            patch) pa=$((pa + 1)) ;;
            minor) mi=$((mi + 1)); pa=0 ;;
            major) ma=$((ma + 1)); mi=0; pa=0 ;;
        esac
    fi
    echo "$ma.$mi.$pa"
}

cmd_next() {
    need_gh
    local latest next
    next="$(next_version "${1:-patch}")"
    latest="$(remote_versions | head -1)"
    echo "latest tag: ${latest:-none}; code on master: $(code_version origin/master)"
    echo "next (${1:-patch}): $next"
}

# 0 when the version is free; 1, with the reason, when it is taken.
check_version() {
    local v="${1#v}" taken=0
    [[ "$v" =~ $VERSION_RE ]] || die "'$v' is not a version such as 0.2.1 or 0.3.0-rc.1"
    if git ls-remote --exit-code --tags origin "refs/tags/v$v" >/dev/null 2>&1; then echo "v$v is already tagged on GitHub"; taken=1; fi
    if gh release view "v$v" >/dev/null 2>&1; then echo "v$v is already released: $(gh release view "v$v" --json url --jq .url)"; taken=1; fi
    if git rev-parse -q --verify "refs/tags/v$v" >/dev/null; then echo "v$v exists as a local tag (git tag -d v$v if it is stale)"; taken=1; fi
    return $taken
}

cmd_check() {
    need_gh
    [ -n "${1:-}" ] || die "usage: make check VERSION=x.y.z"
    if check_version "$1"; then echo "v${1#v} is free"; else return 1; fi
}

cmd_start() {
    need_gh
    local v="${1:-}"
    v="${v#v}"
    echo "== checking"
    git fetch --quiet --tags origin master
    local ahead
    ahead="$(git rev-list --count origin/master..master)"
    [ "$ahead" = 0 ] || die "master has $ahead commit(s) not on GitHub; push them first (git push origin master)"
    if [ -z "$v" ]; then
        v="$(next_version "${BUMP:-patch}")"
        echo "next version (${BUMP:-patch}): $v"
    fi
    [[ "$v" =~ $VERSION_RE ]] || die "usage: make release [VERSION=x.y.z | BUMP=patch|minor|major]"
    check_version "$v" >&2 || die "pick another version"
    echo "releasing $v from origin/master $(git rev-parse --short origin/master) (code is at $(code_version origin/master); latest tag $(remote_versions | head -1 | sed 's/^$/none/'))"

    if [ "${DRY_RUN:-0}" = 1 ]; then echo "dry run: not starting the workflow"; return; fi
    if [ "${YES:-0}" != 1 ] && [ -t 0 ]; then
        read -r -p "Release $v? [y/N] " answer
        [[ "$answer" =~ ^[Yy] ]] || die "not released"
    fi

    echo "== starting the Release workflow"
    local out run_id
    out="$(gh workflow run release.yml --ref master -f "version=$v" 2>&1)"
    echo "$out"
    run_id="$(grep -oE 'actions/runs/[0-9]+' <<<"$out" | head -1 | cut -d/ -f3 || true)"
    if [ "${WATCH:-1}" = 0 ] || [ -z "$run_id" ]; then
        [ -n "$run_id" ] || echo "follow it with: gh run list --workflow release.yml"
        return
    fi
    gh run watch "$run_id" --exit-status
    echo "== released: $(gh release view "v$v" --json url --jq .url)"
    echo "run 'git pull' to get the version bump commit"
}

# Sourcing the file (for tests) defines the functions without running a command.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

case "${1:-}" in
    list) cmd_list ;;
    last) cmd_last ;;
    next) cmd_next "${2:-${BUMP:-patch}}" ;;
    check) cmd_check "${2:-}" ;;
    start) cmd_start "${2:-}" ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
