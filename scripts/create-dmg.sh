#!/usr/bin/env bash
# create-dmg.sh — assemble a signed, styled DMG around a notarized .app
#
# Usage:
#   scripts/create-dmg.sh <path-to-MeetingReminder.app> <version> [output-dir]
#
# Produces: <output-dir>/MeetingReminder-<version>.dmg (default output-dir = ./dist)
#
# Dependencies: hdiutil, codesign (both built into macOS). No Node, no npm.
#
# Environment variables:
#   SIGNING_IDENTITY   required. Name of the Developer ID Application cert
#                      (e.g. "Developer ID Application: Adam Brown (XXXXXXXXXX)").
#   KEYCHAIN_PATH      optional. Path to the keychain holding the cert. Defaults
#                      to the default keychain search list.

set -euo pipefail

APP_PATH="${1:?usage: $0 <app> <version> [output-dir]}"
VERSION="${2:?usage: $0 <app> <version> [output-dir]}"
OUT_DIR="${3:-dist}"

: "${SIGNING_IDENTITY:?SIGNING_IDENTITY environment variable is required}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
DMG_NAME="MeetingReminder-${VERSION}"
DMG_PATH="${OUT_DIR}/${DMG_NAME}.dmg"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

# Stage the DMG contents: the .app plus an /Applications symlink
# so the Finder window shows "drag MeetingReminder onto Applications".
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Build the DMG. UDZO = compressed read-only.
# -fs HFS+ avoids APFS-only behaviour that some older macOS versions stumble over.
echo "==> Creating DMG at $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "MeetingReminder $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH"

# Sign the DMG itself. Notarization of the .app inside doesn't extend to the
# container, so gate-keeper treats an unsigned DMG as untrusted.
echo "==> Signing DMG with identity: $SIGNING_IDENTITY"
if [[ -n "${KEYCHAIN_PATH:-}" ]]; then
    codesign \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        --keychain "$KEYCHAIN_PATH" \
        "$DMG_PATH"
else
    codesign \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        "$DMG_PATH"
fi

echo "==> Verifying DMG signature"
codesign --verify --verbose=2 "$DMG_PATH"

# SHA256 checksum for the release body
shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "${DMG_PATH}.sha256"

echo "==> Done."
echo "    DMG:      $DMG_PATH"
echo "    SHA256:   $(cat "${DMG_PATH}.sha256")"
