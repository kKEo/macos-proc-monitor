#!/bin/bash
# Build a release, sign it and pack it into dist/pmon-<version>.tar.gz.
#
#   Support/release.sh                       ad-hoc signature (runs on this Mac)
#   SIGN_IDENTITY="Developer ID Application: …" Support/release.sh
#
# A Developer ID signature is what makes the root helper's caller check meaningful: install the
# helper with a matching requirement (see DESIGN.md, phase 8). Notarisation is not done here.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
TOOLS=(pmon pmond pmon-menu pmon-helper)

if [ "${SKIP_TESTS:-0}" != "1" ]; then
    echo "== tests"
    swift test 2>&1 | tail -1
fi

echo "== release build"
swift build -c release 2>&1 | tail -1
BIN=".build/release"
VERSION="$("$BIN/pmon" --version)"
STAGE="dist/pmon-$VERSION"
rm -rf "$STAGE" && mkdir -p "$STAGE/bin" "$STAGE/docs"

for t in "${TOOLS[@]}"; do
    cp "$BIN/$t" "$STAGE/bin/$t"
    strip -x "$STAGE/bin/$t"
    # The hardened runtime needs a real identity; an ad-hoc signature is applied plainly.
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --sign - --identifier "dev.pmon.$t" "$STAGE/bin/$t"
    else
        codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier "dev.pmon.$t" "$STAGE/bin/$t"
    fi
    codesign --verify --strict "$STAGE/bin/$t"
done

cp README.md "$STAGE/"
cp docs/*.md "$STAGE/docs/"
cat > "$STAGE/install.sh" <<'INSTALL'
#!/bin/bash
# Install or upgrade pmon for the current user. No root needed.
set -euo pipefail
exec "$(dirname "$0")/bin/pmon" install "$@"
INSTALL
chmod +x "$STAGE/install.sh"

tar -czf "dist/pmon-$VERSION.tar.gz" -C dist "pmon-$VERSION"
echo "== dist/pmon-$VERSION.tar.gz ($(du -h "dist/pmon-$VERSION.tar.gz" | cut -f1)), signed with: $IDENTITY"
shasum -a 256 "dist/pmon-$VERSION.tar.gz"
