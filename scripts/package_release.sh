#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Browser.xcodeproj"
SCHEME="Browser"
CONFIGURATION="Release"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
RELEASE_DIR="$ROOT_DIR/build/release"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$ROOT_DIR/build/sparkle-tools/bin/sign_update}"
REPO_URL="${REPO_URL:-https://github.com/ryankuah/browser}"

mkdir -p "$RELEASE_DIR"

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

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  clean build

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Browser" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

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
