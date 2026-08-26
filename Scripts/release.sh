#!/bin/bash
# Cuts a distributable release: notarized .app -> zip -> Homebrew cask formula.
#
#   ./Scripts/release.sh
#
# Requires a notarytool keychain profile (see package_app.sh header). Set
# SKIP_NOTARIZE=1 to produce an unnotarized zip for local testing only — do not
# ship one; Gatekeeper will refuse it on every machine but yours.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-gentpan/quotabar}"
DIST="${DIST:-dist}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP=QuotaBar.app
ZIP_NAME="QuotaBar-${VERSION}.zip"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  ./Scripts/package_app.sh
else
  NOTARIZE=1 ./Scripts/package_app.sh
fi

# Refuse to publish something Gatekeeper would reject on the user's machine.
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  if ! spctl -a -vv "$APP" 2>&1 | grep -q accepted; then
    echo "error: Gatekeeper still rejects the bundle — not releasing." >&2
    spctl -a -vv "$APP" || true
    exit 1
  fi
fi

rm -rf "$DIST"
mkdir -p "$DIST"
# ditto, not zip: keeps the bundle's symlinks, extended attributes and the
# stapled notarization ticket intact.
ditto -c -k --keepParent "$APP" "$DIST/$ZIP_NAME"
SHA="$(shasum -a 256 "$DIST/$ZIP_NAME" | cut -d' ' -f1)"

cat > "$DIST/quotabar.rb" <<CASK
cask "quotabar" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/${REPO}/releases/download/v#{version}/QuotaBar-#{version}.zip"
  name "QuotaBar"
  desc "Menu-bar meter for AI coding provider quotas"
  homepage "https://github.com/${REPO}"

  depends_on macos: ">= :sonoma"

  app "QuotaBar.app"

  # Preferences and the trend log. The manually entered provider credentials
  # live in the login keychain and are deliberately left alone — zap cannot
  # remove keychain items, and silently deleting a user's API keys would be
  # worse than leaving them.
  zap trash: [
    "~/.config/quotabar",
  ]
end
CASK

echo
echo "── Release ${VERSION} ─────────────────────────────"
echo "  zip     $DIST/$ZIP_NAME  ($(du -h "$DIST/$ZIP_NAME" | cut -f1))"
echo "  sha256  $SHA"
echo "  cask    $DIST/quotabar.rb"
echo
echo "Next:"
echo "  1. gh release create v${VERSION} $DIST/$ZIP_NAME --title 'QuotaBar ${VERSION}'"
echo "  2. Copy $DIST/quotabar.rb into your tap repo as Casks/quotabar.rb"
echo "     (repo must be named homebrew-tap, e.g. github.com/${REPO%%/*}/homebrew-tap)"
echo "  3. Users then run:"
echo "       brew tap ${REPO%%/*}/tap"
echo "       brew install --cask quotabar"
