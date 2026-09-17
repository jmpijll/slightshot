#!/usr/bin/env bash
# Notarises and staples a built artifact (.app, .dmg or .zip).
#
# Credentials, in order of preference:
#   NOTARY_PROFILE                     a `notarytool store-credentials` profile
#   APPLE_ID + TEAM_ID + APP_PASSWORD  an app-specific password (used by CI)
set -euo pipefail

TARGET="${1:?usage: notarize.sh <path-to-.app-or-.dmg>}"
[[ -e "$TARGET" ]] || { echo "error: $TARGET does not exist"; exit 1; }

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
  CREDENTIALS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  echo "error: set NOTARY_PROFILE, or APPLE_ID + TEAM_ID + APP_PASSWORD" >&2
  exit 1
fi

# notarytool only accepts archives, so wrap a bare .app first.
SUBMISSION="$TARGET"
CLEANUP=""
if [[ "$TARGET" == *.app ]]; then
  SUBMISSION="${TARGET%.app}-notarize.zip"
  CLEANUP="$SUBMISSION"
  ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
fi

echo "==> Submitting $(basename "$SUBMISSION") to Apple"
xcrun notarytool submit "$SUBMISSION" "${CREDENTIALS[@]}" --wait --timeout 30m

echo "==> Stapling $(basename "$TARGET")"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
spctl --assess --type execute --verbose=2 "$TARGET" 2>&1 || true

[[ -n "$CLEANUP" ]] && rm -f "$CLEANUP"
echo "==> Notarised $TARGET"
