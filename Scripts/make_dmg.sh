#!/usr/bin/env bash
# Wraps build/Slightshot.app in a drag-to-Applications disk image.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Slightshot.app"
[[ -d "$APP" ]] || { echo "error: run Scripts/bundle.sh first"; exit 1; }

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="$ROOT/build/Slightshot-$VERSION.dmg"
rm -f "$DMG"

if command -v create-dmg > /dev/null; then
  create-dmg \
    --volname "Slightshot $VERSION" \
    --window-pos 200 120 --window-size 620 400 --icon-size 110 \
    --icon "Slightshot.app" 165 180 \
    --app-drop-link 455 180 \
    --hide-extension "Slightshot.app" \
    --no-internet-enable \
    "$DMG" "$APP"
else
  # Plain fallback so the release still works without Homebrew's create-dmg.
  STAGING="$(mktemp -d)"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "Slightshot $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG"
  rm -rf "$STAGING"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

echo "==> Built $DMG"
