#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="${MORPH_DIRECT_STAGE_DIR:-$project_root/work/DirectRelease}"
output_dir="${MORPH_OUTPUT_DIR:-$project_root/outputs}"
bundle_id=at.einser.morphcontrol.direct
team="${MORPH_DIRECT_TEAM:-7752JTW37W}"
archive="$stage/MorphControl.xcarchive"
archived_app="$archive/Products/Applications/MorphControl.app"
staged_app="$stage/MorphControl.app"
submission_zip="$stage/MorphControl-notary.zip"

usage() {
    cat <<'EOF'
Usage:
  scripts/direct-release.sh build
  scripts/direct-release.sh notarize --keychain-profile PROFILE
  scripts/direct-release.sh finalize [--app /path/to/exported/MorphControl.app]

Build creates a signed Xcode archive, staged app and submission ZIP.
Notarize submits that ZIP using an existing local notarytool profile.
Finalize staples and checks the distributed app, then emits a ZIP and SHA-256.
For the Xcode Organizer route, open the staged archive, distribute via
Developer ID with notarization, export the app, and pass it to finalize.

MORPH_DIRECT_STAGE_DIR selects a fresh staging directory for each build.
MORPH_OUTPUT_DIR selects the destination for verified download files.
MORPH_SIGN_IDENTITY selects a Developer ID Application fingerprint or name.
MORPH_DIRECT_TEAM defaults to 7752JTW37W.
EOF
}

fail() {
    printf 'Direct release: %s\n' "$*" >&2
    exit 1
}

bundle_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

verify_direct_app() {
    local app="$1" signature executable
    MORPH_EXPECTED_SIGN_TEAM="$team" "$project_root/scripts/verify-bundle.sh" "$app"
    [[ "$(bundle_value "$app" CFBundleIdentifier)" == "$bundle_id" ]] || fail 'Unexpected direct-download bundle identifier.'
    signature=$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)
    /usr/bin/grep -q '^Authority=Developer ID Application:' <<< "$signature" || fail 'Developer ID Application signature required.'
    /usr/bin/grep -q '^Timestamp=.' <<< "$signature" || fail 'Secure signing timestamp missing.'
    /usr/bin/grep -Eq '^CodeDirectory .*flags=0x[[:xdigit:]]+\([^)]*runtime' <<< "$signature" || fail 'Hardened Runtime flag missing.'
    executable=$(bundle_value "$app" CFBundleExecutable)
    [[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable")" == arm64 ]] || fail 'Expected an arm64-only executable.'
    /usr/bin/cmp -s "$project_root/LICENSE" "$app/Contents/Resources/LICENSE" || fail 'Bundled project LICENSE is missing or differs from the source.'
}

build_direct() {
    local identities
    [[ -s "$project_root/LICENSE" ]] || fail 'Add the project LICENSE before building.'
    [[ ! -e "$archive" && ! -e "$staged_app" && ! -e "$submission_zip" ]] || fail 'Set MORPH_DIRECT_STAGE_DIR to a fresh directory for a new build.'
    # Reuse public certificate selection and exact leaf-OU team resolution.
    source "$project_root/scripts/build.sh"
    identities=$(/usr/bin/security find-identity -v -p codesigning)
    identities=$(/usr/bin/awk '/"Developer ID Application:/ { print }' <<< "$identities")
    morph_select_release_identity "$identities" "${MORPH_SIGN_IDENTITY:-}"
    morph_resolve_release_team
    [[ "$MORPH_RESOLVED_SIGN_TEAM" == "$team" ]] || fail 'Developer ID certificate is from a different team.'

    mkdir -p "$stage"
    /usr/bin/xcodebuild \
        -project "$project_root/Morph.xcodeproj" \
        -scheme Morph -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$stage/DerivedData" -archivePath "$archive" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
        CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
        "CODE_SIGN_IDENTITY=$MORPH_RESOLVED_SIGN_HASH" \
        "DEVELOPMENT_TEAM=$team" "MORPH_LOCAL_TEAM=$team" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES \
        OTHER_CODE_SIGN_FLAGS=--timestamp archive

    verify_direct_app "$archived_app"
    /usr/bin/ditto --rsrc --extattr "$archived_app" "$staged_app"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$submission_zip"
    printf 'Xcode archive: %s\nSubmission ZIP: %s\n' "$archive" "$submission_zip"
}

notarize_direct() {
    local profile="$1" receipt="$stage/notary-result.json" status
    [[ -f "$submission_zip" ]] || fail 'Run build before notarize.'
    verify_direct_app "$staged_app"
    /usr/bin/xcrun notarytool submit "$submission_zip" --keychain-profile "$profile" \
        --wait --output-format json > "$receipt"
    status=$(/usr/bin/plutil -extract status raw -o - "$receipt")
    [[ "$status" == Accepted ]] || fail "Notary status is $status. See $receipt for the submission ID."
    printf 'Accepted notarization: %s\n' "$receipt"
}

finalize_direct() {
    local source_app="$1" version build zip_name copied_app unpacked_app
    [[ -d "$archived_app" ]] || fail 'Run build before finalize.'
    verify_direct_app "$source_app"
    version=$(bundle_value "$source_app" CFBundleShortVersionString)
    build=$(bundle_value "$source_app" CFBundleVersion)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || fail 'Invalid release version or build number.'
    [[ "$version" == "$(bundle_value "$archived_app" CFBundleShortVersionString)" &&
       "$build" == "$(bundle_value "$archived_app" CFBundleVersion)" ]] || fail 'The exported app version differs from the staged archive.'

    # The temporary files remain on the destination volume for atomic moves.
    mkdir -p "$output_dir"
    final_dir=$(mktemp -d "$output_dir/.direct-release.XXXXXX")
    trap 'rm -rf "$final_dir"' EXIT
    copied_app="$final_dir/MorphControl.app"
    zip_name="MorphControl-$version-macOS-arm64.zip"
    /usr/bin/ditto --rsrc --extattr "$source_app" "$copied_app"
    /usr/bin/xcrun stapler staple "$copied_app"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$copied_app" "$final_dir/$zip_name"
    /usr/bin/ditto -x -k "$final_dir/$zip_name" "$final_dir/unpacked"
    unpacked_app="$final_dir/unpacked/MorphControl.app"
    verify_direct_app "$unpacked_app"
    /usr/bin/xcrun stapler validate "$unpacked_app"
    if [[ -x /usr/bin/syspolicy_check ]]; then
        /usr/bin/syspolicy_check distribution "$unpacked_app"
    else
        /usr/sbin/spctl --assess --type execute --verbose=4 "$unpacked_app"
    fi
    (cd "$final_dir" && /usr/bin/shasum -a 256 "$zip_name" > "$zip_name.sha256")
    mv -f "$final_dir/$zip_name" "$output_dir/$zip_name"
    mv -f "$final_dir/$zip_name.sha256" "$output_dir/$zip_name.sha256"
    printf 'Verified download: %s\nSHA-256: %s\n' "$output_dir/$zip_name" "$output_dir/$zip_name.sha256"
}

case "${1:-}" in
    build)
        [[ $# == 1 ]] || { usage >&2; exit 2; }
        build_direct
        ;;
    notarize)
        [[ $# == 3 && "$2" == --keychain-profile && -n "$3" ]] || { usage >&2; exit 2; }
        notarize_direct "$3"
        ;;
    finalize)
        if [[ $# == 1 ]]; then
            finalize_direct "$staged_app"
        elif [[ $# == 3 && "$2" == --app && -n "$3" ]]; then
            finalize_direct "$3"
        else
            usage >&2; exit 2
        fi
        ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
