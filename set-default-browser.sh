#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/Browser.app"
BUNDLE_ID="com.ryankuah.browser"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$APP" ]]; then
  echo "Missing app: $APP" >&2
  exit 1
fi

"$LSREGISTER" -f "$APP"

osascript -l JavaScript <<'JXA'
ObjC.import('CoreServices')

function setDefault(scheme, bundleId) {
  const result = $.LSSetDefaultHandlerForURLScheme($(scheme), $(bundleId))
  console.log(scheme + ': ' + result)
}

setDefault('http', 'com.ryankuah.browser')
setDefault('https', 'com.ryankuah.browser')
JXA

echo
echo "Current Launch Services entries:"
defaults read "$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure" LSHandlers 2>/dev/null \
  | grep -A 4 -B 1 -E 'LSHandlerURLScheme = (http|https)|LSHandlerRoleAll = "'"$BUNDLE_ID"'"' || true
