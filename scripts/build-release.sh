#!/usr/bin/env bash
# build-release.sh — local reproduction of the CI release build.
#
# Usage:
#   scripts/build-release.sh <version>
#
# e.g.
#   scripts/build-release.sh 2.1.0
#
# Produces a signed, notarized, stapled DMG in ./dist/.
#
# Required environment variables (or a .env file in the repo root):
#   SIGNING_IDENTITY           "Developer ID Application: Your Name (TEAMID)"
#   NOTARIZATION_APPLE_ID      your Apple ID email
#   NOTARIZATION_PWD           app-specific password from appleid.apple.com
#   NOTARIZATION_TEAM_ID       your 10-char team ID
#
# Optional:
#   SKIP_NOTARIZE=1            build + sign + DMG, no notarization (for quick tests)

set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Source .env if present (for local runs).
if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

: "${SIGNING_IDENTITY:?SIGNING_IDENTITY is required (see scripts/build-release.sh header)}"

TEAM_ID="${NOTARIZATION_TEAM_ID:-}"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/MeetingReminder.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/MeetingReminder.app"

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR"

# Render the ExportOptions.plist with the real team ID.
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
if [[ -z "$TEAM_ID" ]]; then
    # Try to parse the identity string, e.g. "Developer ID Application: Adam Brown (XXXXXXXXXX)".
    TEAM_ID="$(echo "$SIGNING_IDENTITY" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/')"
fi
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "error: could not determine 10-char team ID (set NOTARIZATION_TEAM_ID or ensure SIGNING_IDENTITY contains it in parentheses)" >&2
    exit 1
fi
sed "s/__TEAM_ID__/$TEAM_ID/" "$SCRIPT_DIR/ExportOptions.plist" > "$EXPORT_PLIST"

echo "==> Archiving (version $VERSION, team $TEAM_ID)"
xcodebuild \
    -project MeetingReminder.xcodeproj \
    -scheme MeetingReminder \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    archive

echo "==> Exporting .app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: export did not produce $APP_PATH" >&2
    exit 1
fi

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
    : "${NOTARIZATION_APPLE_ID:?NOTARIZATION_APPLE_ID is required (or set SKIP_NOTARIZE=1)}"
    : "${NOTARIZATION_PWD:?NOTARIZATION_PWD is required (or set SKIP_NOTARIZE=1)}"

    NOTARIZE_ZIP="$BUILD_DIR/notarize.zip"
    echo "==> Zipping for notarization"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    echo "==> Submitting to Apple notary service (this usually takes 3-5 min)"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$NOTARIZATION_APPLE_ID" \
        --password "$NOTARIZATION_PWD" \
        --team-id "$TEAM_ID" \
        --wait

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
else
    echo "==> SKIP_NOTARIZE=1: skipping notarization & stapling"
fi

echo "==> Building DMG"
SIGNING_IDENTITY="$SIGNING_IDENTITY" "$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$VERSION" "$ROOT_DIR/dist"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
    echo "==> Stapling DMG"
    xcrun stapler staple "$ROOT_DIR/dist/MeetingReminder-${VERSION}.dmg"
fi

echo
echo "Success. Release artifact ready: dist/MeetingReminder-${VERSION}.dmg"
