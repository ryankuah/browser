#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Browser.xcodeproj"
SCHEME="Browser"
CONFIGURATION="Release"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
RELEASE_DIR="$ROOT_DIR/build/release"
DMG_STAGING_DIR="$ROOT_DIR/build/dmg-staging"
DMG_VERIFY_MOUNT_DIR="$ROOT_DIR/build/dmg-verify-mount"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$ROOT_DIR/build/sparkle-tools/bin/sign_update}"
REPO_URL="${REPO_URL:-https://github.com/ryankuah/browser}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
NOTARIZE="${NOTARIZE:-1}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
ATTACHED_DMG_DEVICE=""

cleanup() {
  if [[ -n "$ATTACHED_DMG_DEVICE" ]]; then
    hdiutil detach "$ATTACHED_DMG_DEVICE" -quiet || true
  fi
  rm -rf "$DMG_VERIFY_MOUNT_DIR"
}
trap cleanup EXIT

mkdir -p "$RELEASE_DIR"

if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
  DEVELOPER_ID_APPLICATION="$(
    security find-identity -v -p codesigning |
      awk -F'"' '/Developer ID Application/ && $0 !~ /REVOKED|CSSMERR/ {print $2; exit}'
  )"
fi

if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
  cat >&2 <<'EOF'
Missing Developer ID Application signing identity.

Install a Developer ID Application certificate in Keychain Access, then rerun:
  scripts/package_release.sh

You can also pass an explicit identity:
  DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" scripts/package_release.sh
EOF
  exit 1
fi

if [[ "$NOTARIZE" != "0" && -z "$NOTARYTOOL_PROFILE" ]]; then
  cat >&2 <<'EOF'
Missing notarytool profile.

Create one first, for example:
  xcrun notarytool store-credentials browser-notary \
    --apple-id you@example.com \
    --team-id TEAMID \
    --password app-specific-password

Then rerun:
  NOTARYTOOL_PROFILE=browser-notary scripts/package_release.sh

For a local unsigned-by-Gatekeeper test only, bypass notarization with:
  NOTARIZE=0 scripts/package_release.sh
EOF
  exit 1
fi

VERSION="$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings |
    awk -F'= ' '/ MARKETING_VERSION = / {print $2; exit}'
)"

BUILD_NUMBER="$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings |
    awk -F'= ' '/ CURRENT_PROJECT_VERSION = / {print $2; exit}'
)"

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Browser.app"
DMG_NAME="Browser-$VERSION.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
APPCAST_PATH="$RELEASE_DIR/appcast.xml"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"

verify_app_signature() {
  local app_path="$1"

  codesign --verify --deep --strict --verbose=2 "$app_path"
}

verify_app_for_distribution() {
  local app_path="$1"

  verify_app_signature "$app_path"
  spctl --assess --type execute --verbose=4 "$app_path"
}

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  clean build

if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  find "$SPARKLE_FRAMEWORK" -type d \( -name '*.xpc' -o -name '*.app' \) -print0 |
    while IFS= read -r -d '' item; do
      codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$item"
    done
  if [[ -f "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate" ]]; then
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate"
  fi
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$SPARKLE_FRAMEWORK"
fi

xattr -cr "$APP_PATH"
codesign --force \
  --sign "$DEVELOPER_ID_APPLICATION" \
  --options runtime \
  --timestamp \
  --entitlements "$ROOT_DIR/Browser/Browser.entitlements" \
  "$APP_PATH"
verify_app_signature "$APP_PATH"

rm -f "$DMG_PATH"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

hdiutil create \
  -volname "Browser" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG_PATH"

if [[ "$NOTARIZE" != "0" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

  rm -rf "$DMG_VERIFY_MOUNT_DIR"
  mkdir -p "$DMG_VERIFY_MOUNT_DIR"
  hdiutil attach "$DMG_PATH" \
    -readonly \
    -nobrowse \
    -mountpoint "$DMG_VERIFY_MOUNT_DIR" \
    >/dev/null
  ATTACHED_DMG_DEVICE="$DMG_VERIFY_MOUNT_DIR"
  verify_app_for_distribution "$DMG_VERIFY_MOUNT_DIR/Browser.app"
  hdiutil detach "$ATTACHED_DMG_DEVICE" -quiet
  ATTACHED_DMG_DEVICE=""
  rmdir "$DMG_VERIFY_MOUNT_DIR"
else
  echo "Skipping notarization and Gatekeeper distribution assessment because NOTARIZE=0." >&2
fi

if [[ ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
  echo "Missing Sparkle sign_update tool at $SPARKLE_SIGN_UPDATE" >&2
  exit 1
fi

SIGNATURE_XML="$("$SPARKLE_SIGN_UPDATE" "$DMG_PATH")"
LENGTH="$(stat -f%z "$DMG_PATH")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
DOWNLOAD_URL="$REPO_URL/releases/download/v$VERSION/$DMG_NAME"

cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Browser Updates</title>
    <description>Updates for Browser</description>
    <language>en</language>
    <item>
      <title>Browser $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure
        url="$DOWNLOAD_URL"
        type="application/octet-stream"
        $SIGNATURE_XML />
    </item>
  </channel>
</rss>
XML

echo "$DMG_PATH"
echo "$APPCAST_PATH"
