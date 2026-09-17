#!/usr/bin/env bash
# Builds Slightshot.app from the SwiftPM executable, signing it if a
# Developer ID identity is available.
#
#   VERSION            marketing version          (default: git describe, else 0.0.0)
#   BUILD              CFBundleVersion            (default: git commit count)
#   SIGN_IDENTITY      codesign identity          (default: auto-detect Developer ID)
#   SPARKLE_FEED_URL   appcast URL                (default: GitHub Pages)
#   SPARKLE_PUBLIC_KEY EdDSA public key           (default: read .sparkle-public-key)
#   ARCHS              space-separated arch list  (default: arm64)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="Slightshot"
BUNDLE_ID="com.jmpijll.slightshot"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://jmpijll.github.io/slightshot/appcast.xml}"
ARCHS="${ARCHS:-arm64}"

if [[ -z "${SPARKLE_PUBLIC_KEY:-}" && -f "$ROOT/.sparkle-public-key" ]]; then
  SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$ROOT/.sparkle-public-key")"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi

echo "==> $APP_NAME $VERSION ($BUILD) for: $ARCHS"

# ---------------------------------------------------------------- build
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release "${ARCH_FLAGS[@]}"

BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
[[ -x "$BIN/$APP_NAME" ]] || { echo "error: $BIN/$APP_NAME not found"; exit 1; }

# ---------------------------------------------------------------- layout
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

SPARKLE_SRC="$(find "$ROOT/.build" -type d -name Sparkle.framework -path '*xcframework*' | head -n 1)"
[[ -n "$SPARKLE_SRC" ]] || { echo "error: Sparkle.framework not found in .build"; exit 1; }
cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
# Headers are dead weight in a shipping bundle and only slow signing down.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/PrivateHeaders" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Modules" \
       "$APP/Contents/Frameworks/Sparkle.framework/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/PrivateHeaders" \
       "$APP/Contents/Frameworks/Sparkle.framework/Modules"

# ---------------------------------------------------------------- Info.plist
PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>          <string>en</string>
  <key>CFBundleExecutable</key>                 <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>                   <string>AppIcon</string>
  <key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
  <key>CFBundleName</key>                       <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>                <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>                <string>APPL</string>
  <key>CFBundleShortVersionString</key>         <string>$VERSION</string>
  <key>CFBundleVersion</key>                    <string>$BUILD</string>
  <key>LSApplicationCategoryType</key>          <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>             <string>27.0</string>
  <key>LSUIElement</key>                        <true/>
  <key>NSHighResolutionCapable</key>            <true/>
  <key>NSPrincipalClass</key>                   <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>           <string>MIT licensed. Inspired by Lightshot; not affiliated with Skillbrains.</string>
  <key>SUFeedURL</key>                          <string>$SPARKLE_FEED_URL</string>
  <key>SUEnableInstallerLauncherService</key>   <false/>
</dict>
</plist>
PLISTEOF

if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$PLIST"
  echo "==> Embedded Sparkle public key"
else
  echo "==> No Sparkle public key; updates will not verify (see docs/RELEASING.md)"
fi
plutil -lint "$PLIST" > /dev/null

# ---------------------------------------------------------------- signing
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "==> No Developer ID found; ad-hoc signing"
  SIGN_IDENTITY="-"
  TIMESTAMP=()
else
  echo "==> Signing as: $SIGN_IDENTITY"
  TIMESTAMP=(--timestamp)
fi

sign() {
  codesign --force --options runtime "${TIMESTAMP[@]}" \
    --sign "$SIGN_IDENTITY" "$@"
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
# Innermost first: XPC services, then the helpers, then the framework, then the app.
for xpc in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
  [[ -e "$xpc" ]] && sign "$xpc"
done
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B"
sign "$SPARKLE"
sign "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Built $APP"
