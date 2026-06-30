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
DMG_LAYOUT_MOUNT_DIR="$ROOT_DIR/build/dmg-layout-mount"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$ROOT_DIR/build/sparkle-tools/bin/sign_update}"
REPO_URL="${REPO_URL:-https://github.com/ryankuah/browser}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-browser-notary}"
NOTARIZE="${NOTARIZE:-1}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
BROWSER_CONVEX_URL="${BROWSER_CONVEX_URL:-}"
ATTACHED_DMG_DEVICE=""

cleanup() {
  if [[ -n "$ATTACHED_DMG_DEVICE" ]]; then
    hdiutil detach "$ATTACHED_DMG_DEVICE" -quiet || true
  fi
  rm -rf "$DMG_VERIFY_MOUNT_DIR"
  rm -rf "$DMG_LAYOUT_MOUNT_DIR"
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
  scripts/package_release.sh

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
DMG_TEMP_PATH="$RELEASE_DIR/Browser-$VERSION.rw.dmg"
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

read_env_file_value() {
  local key="$1"
  local env_file="$ROOT_DIR/.env.local"

  [[ -f "$env_file" ]] || return 1

  awk -v key="$key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    /^[[:space:]]*(#|$)/ {
      next
    }

    {
      line = $0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      equals = index(line, "=")
      if (equals == 0) {
        next
      }

      name = trim(substr(line, 1, equals - 1))
      if (name != key) {
        next
      }

      value = trim(substr(line, equals + 1))
      sub(/[[:space:]]+#.*$/, "", value)
      if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") ||
          (substr(value, 1, 1) == "'"'"'" && substr(value, length(value), 1) == "'"'"'")) {
        value = substr(value, 2, length(value) - 2)
      }

      print value
      found = 1
      exit
    }

    END {
      if (!found) {
        exit 1
      }
    }
  ' "$env_file"
}

resolve_browser_convex_url() {
  local value="$BROWSER_CONVEX_URL"

  if [[ -z "$value" ]]; then
    value="$(read_env_file_value BROWSER_CONVEX_URL || true)"
  fi
  if [[ -z "$value" ]]; then
    value="${CONVEX_URL:-}"
  fi
  if [[ -z "$value" ]]; then
    value="$(read_env_file_value CONVEX_URL || true)"
  fi

  if [[ -z "$value" ]]; then
    cat >&2 <<'EOF'
Missing Browser Convex URL.

Set BROWSER_CONVEX_URL or CONVEX_URL in your shell, or add one of them to
.env.local, then rerun:
  scripts/package_release.sh
EOF
    exit 1
  fi

  printf '%s\n' "$value"
}

embed_release_configuration() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"

  /usr/bin/plutil -replace BrowserConvexURL -string "$BROWSER_CONVEX_URL" "$info_plist"
}

create_dmg_background() {
  local background_path="$1"

  command -v python3 >/dev/null 2>&1 || {
    echo "Missing required command for DMG background generation: python3" >&2
    exit 1
  }

  python3 - "$background_path" <<'PYTHON'
import binascii
import math
import os
import struct
import sys
import zlib

output_path = sys.argv[1]
width, height = 660, 400
pixels = bytearray()

def blend(dst, src, alpha):
    return tuple(round(dst[i] * (1 - alpha) + src[i] * alpha) for i in range(3))

def rounded_rect_alpha(x, y, left, top, right, bottom, radius):
    if x < left or x >= right or y < top or y >= bottom:
        return 0
    cx = min(max(x, left + radius), right - radius - 1)
    cy = min(max(y, top + radius), bottom - radius - 1)
    distance = math.hypot(x - cx, y - cy)
    return max(0, min(1, radius + 0.5 - distance))

def circle_alpha(x, y, cx, cy, radius):
    distance = math.hypot(x - cx, y - cy)
    return max(0, min(1, radius + 0.5 - distance))

def segment_alpha(x, y, x1, y1, x2, y2, radius):
    dx, dy = x2 - x1, y2 - y1
    length_squared = dx * dx + dy * dy
    if length_squared == 0:
        return circle_alpha(x, y, x1, y1, radius)
    t = max(0, min(1, ((x - x1) * dx + (y - y1) * dy) / length_squared))
    px, py = x1 + t * dx, y1 + t * dy
    distance = math.hypot(x - px, y - py)
    return max(0, min(1, radius + 0.5 - distance))

for y in range(height):
    for x in range(width):
        base = (244, 248, 251)
        shade = int(10 * y / height)
        color = (max(0, base[0] - shade), max(0, base[1] - shade), max(0, base[2] - shade))

        panel = rounded_rect_alpha(x, y, 28, 28, 632, 372, 28)
        if panel:
            color = blend(color, (255, 255, 255), 0.72 * panel)

        for cx, cy in ((190, 252), (470, 252)):
            glow = circle_alpha(x, y, cx, cy, 116)
            if glow:
                color = blend(color, (226, 235, 247), 0.22 * glow)

        divider = segment_alpha(x, y, 72, 120, 588, 120, 0.8)
        if divider:
            color = blend(color, (190, 198, 207), 0.38 * divider)

        for line in ((274, 252, 386, 252), (366, 234, 386, 252), (366, 270, 386, 252)):
            arrow = segment_alpha(x, y, *line, 2.4)
            if arrow:
                color = blend(color, (92, 105, 122), 0.66 * arrow)

        pixels.extend(color)

def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)

scanlines = b"".join(b"\x00" + pixels[row * width * 3:(row + 1) * width * 3] for row in range(height))
png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(scanlines, 9))
    + chunk(b"IEND", b"")
)

os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, "wb") as output:
    output.write(png)
PYTHON
}

set_dmg_finder_layout() {
  local volume_name="$1"
  local mount_dir="$2"
  local background_path="$mount_dir/.background/background.png"

  /usr/bin/osascript <<OSA
set targetFolder to POSIX file "$mount_dir" as alias
set backgroundImage to POSIX file "$background_path" as alias
tell application "Finder"
  activate
  open targetFolder
  delay 1
  set targetWindow to Finder window "$volume_name"
  set current view of targetWindow to icon view
  try
    set toolbar visible of targetWindow to false
  end try
  try
    set statusbar visible of targetWindow to false
  end try
  set bounds of targetWindow to {100, 100, 760, 500}
  set theViewOptions to the icon view options of targetWindow
  set arrangement of theViewOptions to not arranged
  set icon size of theViewOptions to 112
  set text size of theViewOptions to 12
  set background picture of theViewOptions to backgroundImage
  set position of item "Browser.app" of targetWindow to {190, 252}
  set position of item "Applications" of targetWindow to {470, 252}
  update targetFolder
  delay 2
  close targetWindow
end tell
OSA

  local bless_output
  if ! bless_output="$(/usr/sbin/bless --folder "$mount_dir" --openfolder "$mount_dir" 2>&1)"; then
    if [[ "$bless_output" != *"openfolder' is not supported on Apple Silicon"* ]]; then
      echo "Warning: could not set DMG auto-open folder: $bless_output" >&2
    fi
  fi

  [[ -f "$mount_dir/.DS_Store" ]] || {
    echo "Finder did not persist DMG layout metadata." >&2
    exit 1
  }
}

BROWSER_CONVEX_URL="$(resolve_browser_convex_url)"

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

embed_release_configuration "$APP_PATH"

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
  "$APP_PATH"
verify_app_signature "$APP_PATH"

rm -f "$DMG_PATH" "$DMG_TEMP_PATH"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR/.background"
cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
create_dmg_background "$DMG_STAGING_DIR/.background/background.png"

hdiutil create \
  -volname "Browser" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$DMG_TEMP_PATH"

rm -rf "$DMG_LAYOUT_MOUNT_DIR"
mkdir -p "$DMG_LAYOUT_MOUNT_DIR"
ATTACHED_DMG_DEVICE="$(
  hdiutil attach "$DMG_TEMP_PATH" \
    -readwrite \
    -noverify \
    -nobrowse \
    -mountpoint "$DMG_LAYOUT_MOUNT_DIR" |
    awk '/\/dev\// {print $1; exit}'
)"
[[ -n "$ATTACHED_DMG_DEVICE" ]] || {
  echo "Failed to attach temporary DMG for layout." >&2
  exit 1
}
set_dmg_finder_layout "Browser" "$DMG_LAYOUT_MOUNT_DIR"
sync
hdiutil detach "$ATTACHED_DMG_DEVICE" -quiet
ATTACHED_DMG_DEVICE=""
rmdir "$DMG_LAYOUT_MOUNT_DIR"

hdiutil convert "$DMG_TEMP_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"
rm -f "$DMG_TEMP_PATH"

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
