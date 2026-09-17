#!/usr/bin/env bash
# Submit a signed app or disk image, then staple and verify Apple's ticket.
# Use NOTARY_PROFILE, or APPLE_ID + TEAM_ID + APP_PASSWORD.
set -euo pipefail

TARGET="${1:?usage: notarize.sh <path-to-.app-or-.dmg>}"
[[ -e "$TARGET" ]] || { echo "error: $TARGET does not exist" >&2; exit 1; }
case "$TARGET" in
  *.app|*.dmg) ;;
  *) echo "error: expected .app or .dmg; ZIP files cannot be stapled" >&2; exit 1 ;;
esac

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
  CREDENTIALS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  echo "error: set NOTARY_PROFILE, or APPLE_ID + TEAM_ID + APP_PASSWORD" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SUBMISSION="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  codesign --verify --deep --strict "$TARGET"
  SUBMISSION="$WORK_DIR/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
fi

# Preserve Apple's response next to the artifact, including after failure.
RESULT="${TARGET}.notary-result.json"
LOG="${TARGET}.notary-log.json"
echo "==> Submitting $(basename "$SUBMISSION") to Apple"
SUBMIT_EXIT=0
xcrun notarytool submit "$SUBMISSION" "${CREDENTIALS[@]}" \
  --wait --timeout 30m --output-format json > "$RESULT" || SUBMIT_EXIT=$?
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
SUBMISSION_ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"

if [[ "$SUBMIT_EXIT" != 0 || "$STATUS" != Accepted ]]; then
  echo "error: notarisation did not complete successfully (status: ${STATUS:-unknown})" >&2
  echo "Apple's response: $RESULT" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Submission ID: $SUBMISSION_ID" >&2
    if xcrun notarytool log "$SUBMISSION_ID" "${CREDENTIALS[@]}" "$LOG"; then
      echo "Apple's diagnostic log: $LOG" >&2
    fi
  fi
  exit 1
fi

echo "==> Stapling $(basename "$TARGET")"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.dmg ]]; then
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
else
  spctl --assess --type execute --verbose=2 "$TARGET"
fi
echo "==> Notarised and verified $TARGET"
