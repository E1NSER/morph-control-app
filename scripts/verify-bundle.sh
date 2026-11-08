#!/bin/bash
set -euo pipefail

# Private Release verifier. Debug previews may be ad hoc and intentionally do
# not meet this release policy. Store artifacts have a separate strict verifier.
APP_PATH="${1:?Usage: verify-bundle.sh /path/to/MorphControl.app}"
INFO_PATH="$APP_PATH/Contents/Info.plist"
fail() { printf 'Private Release verification failed: %s\n' "$1" >&2; exit 1; }
[[ -f "$INFO_PATH" ]] || fail 'App bundle or Info.plist is missing.'
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PATH")
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT

/usr/bin/codesign --verify --deep --strict "$APP_PATH" || fail 'The code signature is invalid.'
SIGNATURE_INFO=$(/usr/bin/codesign --display --verbose=4 "$APP_PATH" 2>&1) || fail 'Signature identity is unreadable.'
[[ "$SIGNATURE_INFO" != *'Signature=adhoc'* ]] || fail 'Ad hoc signing is not accepted for private Release updates.'
LEAF_AUTHORITY=$(/usr/bin/sed -n 's/^Authority=//p' <<< "$SIGNATURE_INFO" | /usr/bin/head -n 1)
if ! /usr/bin/grep -Eq '^(Apple Development:|Developer ID Application:)' <<< "$LEAF_AUTHORITY"; then
    fail 'Expected an Apple Development or Developer ID Application signing authority.'
fi
SIGNING_TEAM=$(/usr/bin/sed -n 's/^TeamIdentifier=//p' <<< "$SIGNATURE_INFO")
[[ "$SIGNING_TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail 'A valid signing TeamIdentifier is missing.'

REQUIREMENT_INFO=$(/usr/bin/codesign --display --requirements - "$APP_PATH" 2>&1) || fail 'The designated requirement is unreadable.'
DESIGNATED_REQUIREMENT=$(/usr/bin/sed -n 's/^[#[:space:]]*designated => //p' <<< "$REQUIREMENT_INFO")
[[ -n "$DESIGNATED_REQUIREMENT" ]] || fail 'The designated requirement is missing.'
[[ "$DESIGNATED_REQUIREMENT" != *cdhash* ]] || fail 'The designated requirement is bound to a build-specific cdhash.'
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PATH")
[[ "$DESIGNATED_REQUIREMENT" == *"identifier \"$BUNDLE_ID\""* ]] || fail 'The designated requirement does not bind the bundle identifier.'
[[ "$DESIGNATED_REQUIREMENT" == *'anchor apple'* ]] || fail 'Expected an Apple-anchored designated requirement.'
# Apple Development commonly binds the exact leaf CN, while Developer ID
# commonly binds the leaf OU. The CN suffix is not necessarily the Team ID.
ESCAPED_LEAF_CN="${LEAF_AUTHORITY//\\/\\\\}"
ESCAPED_LEAF_CN="${ESCAPED_LEAF_CN//\"/\\\"}"
LEAF_CN_BINDING="certificate leaf[subject.CN] = \"$ESCAPED_LEAF_CN\""
LEAF_OU_BINDING="certificate leaf[subject.OU] = \"$SIGNING_TEAM\""
[[ "$DESIGNATED_REQUIREMENT" == *"$LEAF_CN_BINDING"* || "$DESIGNATED_REQUIREMENT" == *"$LEAF_OU_BINDING"* ]] || fail 'Expected an exact leaf certificate CN or OU binding in the designated requirement.'
if [[ -n "${MORPH_EXPECTED_SIGN_TEAM:-}" ]]; then
    [[ "$MORPH_EXPECTED_SIGN_TEAM" =~ ^[A-Z0-9]{10}$ && "$SIGNING_TEAM" == "$MORPH_EXPECTED_SIGN_TEAM" ]] || fail 'Signing TeamIdentifier differs from the expected team.'
fi

/usr/bin/codesign --display --entitlements - --xml "$APP_PATH" > "$CHECK_DIR/entitlements.plist" 2>/dev/null || fail 'Signed entitlements are unreadable.'
/usr/bin/plutil -lint "$CHECK_DIR/entitlements.plist" >/dev/null || fail 'Signed entitlements are invalid.'
for KEY in com.apple.security.app-sandbox com.apple.security.device.bluetooth com.apple.security.network.client; do
    VALUE=$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$CHECK_DIR/entitlements.plist" 2>/dev/null || true)
    [[ "$VALUE" == true ]] || fail "Missing entitlement: $KEY"
done
DEBUG_ALLOWED=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$CHECK_DIR/entitlements.plist" 2>/dev/null || true)
[[ "$DEBUG_ALLOWED" != true ]] || fail 'Release bundle permits debugger access.'

[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO_PATH")" == true ]] || fail 'Expected a menu bar app.'
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' "$INFO_PATH")" ]] || fail 'Bluetooth purpose string is missing.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PATH")" == '13.0' ]] || fail 'Unexpected deployment target.'
/usr/bin/lipo -verify_arch arm64 "$EXECUTABLE_PATH" || fail 'The arm64 executable is missing.'

for RESOURCE in Solarmorph-LICENSE.txt THIRD_PARTY_NOTICES.md PRIVACY.md PrivacyInfo.xcprivacy Assets.car; do
    [[ -s "$APP_PATH/Contents/Resources/$RESOURCE" ]] || fail "Resource missing: $RESOURCE"
done
/usr/bin/otool -L "$EXECUTABLE_PATH" | /usr/bin/sed '1d' > "$CHECK_DIR/libraries.txt"
if /usr/bin/grep -E '/opt/homebrew|/usr/local|dyson-solar|DerivedData' "$CHECK_DIR/libraries.txt"; then
    fail 'The app links against a development-machine library.'
fi
[[ "$(/usr/bin/find "$APP_PATH/Contents/MacOS" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 ]] || fail 'Unexpected additional executable in the app bundle.'
printf 'Private Release verified: certificate-based signature, team %s, stable non-cdhash requirement, arm64/macOS 13, sandbox, Bluetooth, network and license resources.\n' "$SIGNING_TEAM"
printf 'Designated requirement: %s\n' "$DESIGNATED_REQUIREMENT"
