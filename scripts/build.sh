#!/bin/bash
set -euo pipefail

# Select only existing public signing identities. No profile, key, certificate,
# portal registration or Keychain access-control list is created or modified.
# Kept separate from the build entry point for side-effect-free policy checks.
morph_select_release_identity() {
  local identity_listing="$1"
  local requested_identity="${2:-}"
  local identity_pattern='^[[:space:]]*[[:digit:]]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"'
  local identity_line identity_hash identity_name
  local requested_hash="" suitable_count=0 seen_hashes='|' candidates=""
  MORPH_RESOLVED_SIGN_HASH=""
  MORPH_RESOLVED_SIGN_NAME=""
  MORPH_RESOLVED_SIGN_TEAM=""

  if [[ "$requested_identity" == - ]]; then
    printf 'Release signing refuses ad hoc identity "-". Choose an existing Apple Development or Developer ID Application identity.\n' >&2
    return 1
  fi
  if [[ "$requested_identity" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    requested_hash="$(/usr/bin/tr '[:lower:]' '[:upper:]' <<< "$requested_identity")"
  fi

  while IFS= read -r identity_line; do
    [[ "$identity_line" =~ $identity_pattern ]] || continue
    identity_hash="$(/usr/bin/tr '[:lower:]' '[:upper:]' <<< "${BASH_REMATCH[1]}")"
    identity_name="${BASH_REMATCH[2]}"
    if [[ -n "$requested_identity" ]]; then
      if [[ -n "$requested_hash" ]]; then
        [[ "$identity_hash" == "$requested_hash" ]] || continue
      else
        [[ "$identity_name" == "$requested_identity" ]] || continue
      fi
    fi
    case "$identity_name" in
      'Apple Development:'*|'Developer ID Application:'*) ;;
      *)
        if [[ -n "$requested_identity" ]]; then
          printf 'MORPH_SIGN_IDENTITY is not an Apple Development or Developer ID Application identity. Store distribution signing uses scripts/store-archive.sh instead.\n' >&2
          return 1
        fi
        continue ;;
    esac
    case "$seen_hashes" in *"|$identity_hash|"*) continue ;; esac
    seen_hashes+="$identity_hash|"
    suitable_count=$((suitable_count + 1))
    candidates+="  $identity_hash  $identity_name"$'\n'
    MORPH_RESOLVED_SIGN_HASH="$identity_hash"
    MORPH_RESOLVED_SIGN_NAME="$identity_name"
  done <<< "$identity_listing"

  if [[ "$suitable_count" == 0 ]]; then
    printf 'No matching valid Apple Development or Developer ID Application identity was found. Install/select an existing identity, then set MORPH_SIGN_IDENTITY to its SHA-1 or exact name. Release will not fall back to ad hoc signing.\n' >&2
    return 1
  fi
  if [[ "$suitable_count" != 1 ]]; then
    printf 'Multiple suitable identities found. Set MORPH_SIGN_IDENTITY explicitly to one SHA-1 or exact name:\n%s' "$candidates" >&2
    return 1
  fi
}


# The trailing parentheses in an Apple Development CN can identify the
# certificate/person, not the developer team. Resolve the actual OU from the
# exact selected public certificate, never from the display-name suffix.
morph_resolve_release_team() {
  local certificate_dir certificate_file certificate_hash certificate_subject certificate_team
  local selected_team=""
  certificate_dir="$(mktemp -d)" || return 1
  if ! /usr/bin/security find-certificate -a -c "$MORPH_RESOLVED_SIGN_NAME" -p > "$certificate_dir/public-certificates.pem"; then
    rm -rf "$certificate_dir"
    printf 'Cannot read the selected public signing certificate. No build or signing was performed.\n' >&2
    return 1
  fi
  /usr/bin/awk -v certificate_dir="$certificate_dir" '
    /-----BEGIN CERTIFICATE-----/ { count++; target = certificate_dir "/certificate-" count ".pem" }
    target != "" { print > target }
    /-----END CERTIFICATE-----/ { close(target); target = "" }
  ' "$certificate_dir/public-certificates.pem"
  for certificate_file in "$certificate_dir"/certificate-*.pem; do
    [[ -f "$certificate_file" ]] || continue
    certificate_hash="$(/usr/bin/openssl x509 -in "$certificate_file" -noout -sha1 -fingerprint 2>/dev/null | /usr/bin/sed 's/.*=//' | /usr/bin/tr -d ':[:space:]' | /usr/bin/tr '[:lower:]' '[:upper:]')" || continue
    [[ "$certificate_hash" == "$MORPH_RESOLVED_SIGN_HASH" ]] || continue
    certificate_subject="$(/usr/bin/openssl x509 -in "$certificate_file" -noout -subject -nameopt sep_multiline,sname,utf8 2>/dev/null)" || continue
    certificate_team="$(/usr/bin/sed -n 's/^[[:space:]]*OU[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\)[[:space:]]*$/\1/p' <<< "$certificate_subject")"
    [[ "$certificate_team" =~ ^[A-Z0-9]{10}$ ]] || continue
    if [[ -n "$selected_team" && "$selected_team" != "$certificate_team" ]]; then
      rm -rf "$certificate_dir"
      printf 'The exact signing certificate has an ambiguous OU/Team ID.\n' >&2
      return 1
    fi
    selected_team="$certificate_team"
  done
  rm -rf "$certificate_dir"
  [[ -n "$selected_team" ]] || {
    printf 'Cannot derive a valid Team ID from the OU of the exact selected public certificate fingerprint. No CN suffix is used as a fallback.\n' >&2
    return 1
  }
  MORPH_RESOLVED_SIGN_TEAM="$selected_team"
}

morph_build_main() {
  local check_only=false
  case "${1:-}" in
    '') [[ $# == 0 ]] || { printf 'Usage: %s [--check-signing]\n' "$0" >&2; return 2; } ;;
    --check-signing) [[ $# == 1 ]] || { printf 'Usage: %s [--check-signing]\n' "$0" >&2; return 2; }; check_only=true ;;
    *) printf 'Usage: %s [--check-signing]\n' "$0" >&2; return 2 ;;
  esac
  local project_root configuration identity_listing
  project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  configuration="${MORPH_CONFIGURATION:-Release}"
  local build_overrides=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES)

  case "$configuration" in
    Debug)
      build_overrides+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= MORPH_LOCAL_TEAM=)
      printf 'Debug preview: ad hoc signing; separate preview bundle ID.\n'
      ;;
    Release)
      identity_listing="$(/usr/bin/security find-identity -v -p codesigning)" || {
        printf 'Unable to read public signing identities. No build or signing was performed.\n' >&2
        return 1
      }
      morph_select_release_identity "$identity_listing" "${MORPH_SIGN_IDENTITY:-}" || return 1
      morph_resolve_release_team || return 1
      build_overrides+=("CODE_SIGN_IDENTITY=$MORPH_RESOLVED_SIGN_HASH" "DEVELOPMENT_TEAM=$MORPH_RESOLVED_SIGN_TEAM" "MORPH_LOCAL_TEAM=$MORPH_RESOLVED_SIGN_TEAM" CODE_SIGNING_REQUIRED=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
      printf 'Private Release identity: %s\nTeam: %s\nSHA-1: %s\n' "$MORPH_RESOLVED_SIGN_NAME" "$MORPH_RESOLVED_SIGN_TEAM" "$MORPH_RESOLVED_SIGN_HASH"
      ;;
    *)
      printf 'Unsupported private-build configuration: %s. Use Debug/Release here and scripts/store-archive.sh for Store archives.\n' "$configuration" >&2
      return 2
      ;;
  esac
  if [[ "$check_only" == true ]]; then
    printf 'Signing selection checked. No build, signing, login or provisioning was performed.\n'
    return 0
  fi

  cd "$project_root"
  /usr/bin/xcodebuild \
    -project Morph.xcodeproj \
    -scheme Morph \
    -configuration "$configuration" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$project_root/work/DerivedData" \
    "${build_overrides[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  morph_build_main "$@"
fi
