#!/bin/zsh
# Structural verification of a preview app. Gatekeeper approval is intentionally not claimed.
set -euo pipefail
[[ $# -ge 4 ]] || { print -u2 -- "Usage: verify-release.sh /path/OneShot.app 0.1.0-alpha.1 1 <full-source-commit> [--signing-mode MODE] [--expected-team-id TEAMID] [--signing-report /path/report.json]"; exit 64; }
oneshot_app="${1:A}"
oneshot_version="$2"
oneshot_build_number="$3"
oneshot_commit="$4"
oneshot_script_root="${0:A:h:h}"
shift 4
oneshot_signing_mode=""
oneshot_expected_team=""
oneshot_signing_report=""
while (( $# > 0 )); do
  [[ $# -ge 2 ]] || { print -u2 -- "Missing verification option value."; exit 64; }
  case "$1" in
    --signing-mode) oneshot_signing_mode="$2" ;;
    --expected-team-id) oneshot_expected_team="$2" ;;
    --signing-report) oneshot_signing_report="$2" ;;
    *) print -u2 -- "Unknown verification option: $1"; exit 64 ;;
  esac
  shift 2
done
if [[ -z "$oneshot_signing_mode" ]]; then
  if ! oneshot_signing_mode="$(plutil -extract OneShotSigningMode raw -o - "$oneshot_app/Contents/Info.plist" 2>/dev/null)"; then
    # Older ad-hoc releases predate the explicit signing-mode metadata field.
    oneshot_legacy_status="$(plutil -extract OneShotSigningStatus raw -o - "$oneshot_app/Contents/Info.plist")"
    [[ "$oneshot_legacy_status" == ad-hoc-unnotarized ]] || { print -u2 -- "Missing signing mode."; exit 65; }
    oneshot_signing_mode=ad-hoc
  fi
fi
python3 "$oneshot_script_root/packaging/release_metadata.py" validate --version "$oneshot_version" \
  --build-number "$oneshot_build_number" --commit "$oneshot_commit" --signing-mode "$oneshot_signing_mode" > /dev/null
oneshot_capture="$oneshot_app/Contents/Helpers/OneShot Capture.app"
oneshot_marketing="${oneshot_version%%-*}"
oneshot_channel=release
[[ "$oneshot_version" != *-* ]] || oneshot_channel=prerelease

oneshot_expect_plist() {
  local oneshot_plist="$1" oneshot_key="$2" oneshot_expected="$3"
  local oneshot_actual="$(plutil -extract "$oneshot_key" raw -o - "$oneshot_plist")"
  [[ "$oneshot_actual" == "$oneshot_expected" ]] || {
    print -u2 -- "Invalid $oneshot_key in ${oneshot_plist:t}: expected $oneshot_expected, found $oneshot_actual"; exit 65
  }
}
for oneshot_bundle in "$oneshot_app" "$oneshot_capture"; do
  [[ -d "$oneshot_bundle" && ! -L "$oneshot_bundle" ]] || { print -u2 -- "Missing regular application bundle: $oneshot_bundle"; exit 65; }
  oneshot_plist="$oneshot_bundle/Contents/Info.plist"
  plutil -lint "$oneshot_plist"
  oneshot_expect_plist "$oneshot_plist" CFBundleShortVersionString "$oneshot_marketing"
  oneshot_expect_plist "$oneshot_plist" CFBundleVersion "$oneshot_build_number"
  oneshot_expect_plist "$oneshot_plist" LSMinimumSystemVersion 14.0
  oneshot_expect_plist "$oneshot_plist" OneShotReleaseTag "v$oneshot_version"
  oneshot_expect_plist "$oneshot_plist" OneShotSourceCommit "$oneshot_commit"
  oneshot_expect_plist "$oneshot_plist" OneShotDistributionChannel "$oneshot_channel"
  oneshot_expect_plist "$oneshot_plist" OneShotSigningStatus "${oneshot_signing_mode}-unnotarized"
  if oneshot_recorded_mode="$(plutil -extract OneShotSigningMode raw -o - "$oneshot_plist" 2>/dev/null)"; then
    [[ "$oneshot_recorded_mode" == "$oneshot_signing_mode" ]] || { print -u2 -- "Inconsistent signing mode in bundle."; exit 65; }
  elif [[ "$oneshot_signing_mode" != ad-hoc ]]; then
    print -u2 -- "Certificate-signed bundles require explicit signing-mode metadata."; exit 65
  fi
  [[ -s "$oneshot_bundle/Contents/Resources/OneShot.icns" ]] || { print -u2 -- "Missing app icon"; exit 65; }
done
oneshot_expect_plist "$oneshot_app/Contents/Info.plist" CFBundleIdentifier io.github.ytwsy.oneshot
oneshot_expect_plist "$oneshot_app/Contents/Info.plist" CFBundleExecutable oneshot-editor
oneshot_expect_plist "$oneshot_capture/Contents/Info.plist" CFBundleIdentifier io.github.ytwsy.oneshot.capture-probe
oneshot_expect_plist "$oneshot_capture/Contents/Info.plist" CFBundleExecutable oneshot
oneshot_expect_plist "$oneshot_capture/Contents/Info.plist" LSUIElement true
[[ -s "$oneshot_app/Contents/Resources/LICENSE" && -s "$oneshot_app/Contents/Resources/INSTALL.txt" ]] || {
  print -u2 -- "Missing license or installation guide"; exit 65
}

oneshot_binaries=("$oneshot_app/Contents/MacOS/oneshot-editor" \
  "$oneshot_capture/Contents/MacOS/oneshot" "$oneshot_app/Contents/Helpers/oneshot-mcp")
oneshot_identifiers=(io.github.ytwsy.oneshot io.github.ytwsy.oneshot.capture-probe io.github.ytwsy.oneshot.mcp)
for oneshot_index in 1 2 3; do
  oneshot_binary="${oneshot_binaries[$oneshot_index]}"
  [[ -f "$oneshot_binary" && -x "$oneshot_binary" && ! -L "$oneshot_binary" ]] || { print -u2 -- "Missing executable: $oneshot_binary"; exit 65; }
  [[ "$(lipo -archs "$oneshot_binary")" == arm64 ]] || { print -u2 -- "Unexpected binary architecture: $oneshot_binary"; exit 65; }
  oneshot_signature="$(codesign -d --verbose=4 "$oneshot_binary" 2>&1)"
  [[ "$oneshot_signature" == *"Identifier=${oneshot_identifiers[$oneshot_index]}"* \
      && "$oneshot_signature" == *"runtime"* ]] || {
    print -u2 -- "Unexpected signing identity or missing hardened runtime: $oneshot_binary"; exit 65
  }
  # Check the Mach-O deployment target as well as the user-visible Info.plist.
  oneshot_build_info="$(xcrun vtool -show-build "$oneshot_binary")"
  [[ "$oneshot_build_info" == *"minos 14.0"* ]] || { print -u2 -- "Unexpected Mach-O minimum macOS: $oneshot_binary"; exit 65; }
done
oneshot_inspect_args=(verify --app "$oneshot_app" --signing-mode "$oneshot_signing_mode")
if [[ -n "$oneshot_expected_team" ]]; then
  oneshot_inspect_args+=(--expected-team-id "$oneshot_expected_team")
fi
if [[ -n "$oneshot_signing_report" ]]; then
  [[ "$oneshot_signing_report" == /* ]] || { print -u2 -- "--signing-report must be absolute."; exit 64; }
  oneshot_inspect_args+=(--output "$oneshot_signing_report")
fi
python3 "$oneshot_script_root/packaging/signing.py" "${oneshot_inspect_args[@]}" > /dev/null
print "Verified OneShot v${oneshot_version} build ${oneshot_build_number}: arm64, macOS 14.0, nested components, ${oneshot_signing_mode} signatures, source ${oneshot_commit}."
print "This checks package structure and signature integrity, not notarization, Gatekeeper acceptance, TCC permissions or real capture behavior."
