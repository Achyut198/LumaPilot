#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   VERSION=v0.1.1 \
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="lumapilot-notary" \
#   ./scripts/macos_notarized_release.sh
#
# Prerequisites:
# - A "Developer ID Application" certificate installed in your keychain.
# - notarytool profile stored in keychain:
#     xcrun notarytool store-credentials "lumapilot-notary" \
#       --apple-id "<apple-id>" --team-id "<TEAMID>" --password "<app-password>"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/LumaPilot.xcodeproj"
SCHEME="LumaPilot"
CONFIGURATION="Release"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="/tmp/LumaPilotDMG"

: "${VERSION:?Set VERSION, e.g. v0.1.0}"
: "${DEVELOPER_ID_APP:?Set DEVELOPER_ID_APP to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile name}"

APP_NAME="LumaPilot.app"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME"
DMG_NAME="LumaPilot-${VERSION}-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "==> Building unsigned app"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build

echo "==> Signing app with hardened runtime"
codesign --force --deep --options runtime --timestamp \
  --sign "$DEVELOPER_ID_APP" \
  "$APP_PATH"

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH" || true

echo "==> Preparing DMG"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/$APP_NAME"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create -volname "LumaPilot Installer" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"

echo "==> Signing DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "==> Submitting DMG for notarization"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler staple "$DMG_PATH"

echo "==> Final Gatekeeper checks"
spctl --assess --type execute --verbose "$APP_PATH" || true
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" || true

echo "==> Writing checksum"
shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

echo "Done:"
echo "  $DMG_PATH"
echo "  $DMG_PATH.sha256"
