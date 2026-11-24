#!/bin/bash
# Write the Homebrew formula for a release into a tap, build and test a bottle, and add the bottle block.
#
#   Support/homebrew.sh <version> <tarball-sha256> <tap> <bottle-root-url> <out-dir> [tarball-url]
#
#   version          e.g. 0.2.3
#   tarball-sha256   SHA-256 of pmon-<version>.tar.gz
#   tap              tap to write into, e.g. kkeo/tap; it must already be tapped (a clone under brew --repository)
#   bottle-root-url  where the bottles will be downloaded from, e.g. the GitHub release's download URL
#   out-dir          the bottle files are left here under the names Homebrew downloads them by
#   tarball-url      default: the GitHub release asset; a file:// URL for testing a local build
#
# BOTTLE_TAG=arm64_sonoma relabels the bottle for the oldest macOS it supports. Homebrew pours a bottle on its
# own macOS version and newer ones, and the binaries run on macOS 14, so one bottle then covers every user,
# whichever macOS the build machine has.
#
# Leaves <tap>/Formula/pmon.rb with url, sha256 and bottle block filled in, uncommitted, and pmon installed
# from the bottle. Used by the Release workflow; see docs/development.md.
#
# The binaries in the release archive are prebuilt, so the bottle only repackages them. Its point is that
# installing a bottle, unlike a formula without one, does not need current Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -ge 5 ] || { sed -n '2,13p' "$0"; exit 2; }
VERSION="$1" SHA="$2" TAP="$3" ROOT_URL="$4" OUT="$5"
URL="${6:-https://github.com/kKEo/macos-proc-monitor/releases/download/v$VERSION/pmon-$VERSION.tar.gz}"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "not a SHA-256: $SHA"; exit 1; }

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
TAP_DIR="$(brew --repository "$TAP")"
[ -d "$TAP_DIR" ] || { echo "tap $TAP is not tapped ($TAP_DIR)"; exit 1; }
FORMULA="$TAP_DIR/Formula/pmon.rb"
mkdir -p "$TAP_DIR/Formula" "$OUT"
OUT="$(cd "$OUT" && pwd)"

echo "== formula $VERSION"
# The source formula with this release's url and sha256, without any bottle block of an earlier release.
ruby -e '
  src, url, sha = File.read(ARGV[0]), ARGV[1], ARGV[2]
  src = src.sub(/^  url ".*"$/) { %(  url "#{url}") }.sub(/^  sha256 ".*"$/) { %(  sha256 "#{sha}") }
  src = src.sub(/^  bottle do\n.*?^  end\n\n?/m, "")
  print src
' Support/homebrew/pmon.rb "$URL" "$SHA" > "$FORMULA"

echo "== build the bottle"
brew uninstall --force pmon >/dev/null 2>&1 || true
brew install --build-bottle "$TAP/pmon"
brew test "$TAP/pmon"
WORK="$(mktemp -d)"
(cd "$WORK" && brew bottle --json --no-rebuild --root-url "$ROOT_URL" "$TAP/pmon")

# brew bottle names the file pmon--<version>.<tag>.bottle.tar.gz; it is downloaded as the JSON's "filename".
for json in "$WORK"/*.bottle.json; do
    if [ -n "${BOTTLE_TAG:-}" ]; then
        ruby -rjson -e '
          path, tag = ARGV
          data = JSON.parse(File.read(path))
          data.each_value do |f|
            f["bottle"]["tags"] = f["bottle"]["tags"].to_h do |old, t|
              t["filename"] = t["filename"].sub(".#{old}.bottle.", ".#{tag}.bottle.")
              [tag, t]
            end
          end
          File.write(path, JSON.pretty_generate(data))
        ' "$json" "$BOTTLE_TAG"
    fi
    ruby -rjson -e '
      JSON.parse(File.read(ARGV[0])).each_value do |f|
        f["bottle"]["tags"].each_value { |t| puts "#{t["local_filename"]}\t#{t["filename"]}" }
      end
    ' "$json" | while IFS=$'\t' read -r local remote; do
        mv "$WORK/$local" "$OUT/$remote"
        echo "bottle: $OUT/$remote"
    done
done

echo "== add the bottle block"
brew bottle --merge --write --no-commit "$WORK"/*.bottle.json
rm -rf "$WORK"

echo "== install from the bottle"
brew uninstall pmon
brew install "$TAP/pmon"
brew test "$TAP/pmon"
grep -A4 '^  bottle do' "$FORMULA"
