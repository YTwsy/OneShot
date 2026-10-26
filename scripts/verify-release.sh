#!/bin/zsh
# Structural verification of a preview app. Gatekeeper approval is intentionally not claimed.
set -euo pipefail
[[ $# == 4 ]] || { print -u2 "Usage: verify-release.sh /path/OneShot.app 0.1.0-alpha.1 1 <full-source-commit>"; exit 64; }
oneshot_app="${1:A}"
oneshot_version="$2"
oneshot_build_number="$3"
oneshot_commit="$4"
oneshot_script_root="${0:A:h:h}"
python3 "$oneshot_script_root/packaging/release_metadata.py" validate --version "$oneshot_version" \
  --build-number "$oneshot_build_number" --commit "$oneshot_commit" > /dev/null
oneshot_capture="$oneshot_app/Contents/Helpers/OneShot Capture.app"
oneshot_marketing="${oneshot_version%%-*}"

oneshot_expect_plist() {
  local oneshot_plist="$1" oneshot_key="$2" oneshot_expected="$3"
  local oneshot_actual="$(plutil -extract "$oneshot_key" raw -o - "$oneshot_plist")"
  [[ "$oneshot_actual" == "$oneshot_expected" ]] || {
    print -u2 "Invalid $oneshot_key in ${oneshot_plist:t}: expected $oneshot_expected, found $oneshot_actual"; exit 65
  }
}
for oneshot_bundle in "$oneshot_app" "$oneshot_capture"; do
  [[ -d "$oneshot_bundle" && ! -L "$oneshot_bundle" ]] || { print -u2 "Missing regular application bundle: $oneshot_bundle"; exit 65; }
  oneshot_plist="$oneshot_bundle/Contents/Info.plist"
  plutil -lint "$oneshot_plist"
  oneshot_expect_plist "$oneshot_plist" CFBundleShortVersionString "$oneshot_marketing"
  oneshot_expect_plist "$oneshot_plist" CFBundleVersion "$oneshot_build_number"
  oneshot_expect_plist "$oneshot_plist" LSMinimumSystemVersion 14.0
  oneshot_expect_plist "$oneshot_plist" OneShotReleaseTag "v$oneshot_version"
  oneshot_expect_plist "$oneshot_plist" OneShotSourceCommit "$oneshot_commit"
  oneshot_expect_plist "$oneshot_plist" OneShotDistributionChannel prerelease
  oneshot_expect_plist "$oneshot_plist" OneShotSigningStatus ad-hoc-unnotarized
  [[ -s "$oneshot_bundle/Contents/Resources/OneShot.icns" ]] || { print -u2 "Missing app icon"; exit 65; }
done
oneshot_expect_plist "$oneshot_app/Contents/Info.plist" CFBundleIdentifier io.github.ytwsy.oneshot
oneshot_expect_plist "$oneshot_app/Contents/Info.plist" CFBundleExecutable oneshot-editor
oneshot_expect_plist "$oneshot_capture/Contents/Info.plist" CFBundleIdentifier io.github.ytwsy.oneshot.capture-probe
oneshot_expect_plist "$oneshot_capture/Contents/Info.plist" CFBundleExecutable oneshot
oneshot_expect_plist "$oneshot_capture/Contents/Info.plist" LSUIElement true
[[ -s "$oneshot_app/Contents/Resources/LICENSE" && -s "$oneshot_app/Contents/Resources/INSTALL.txt" ]] || {
  print -u2 "Missing license or installation guide"; exit 65
}

oneshot_binaries=("$oneshot_app/Contents/MacOS/oneshot-editor" \
  "$oneshot_capture/Contents/MacOS/oneshot" "$oneshot_app/Contents/Helpers/oneshot-mcp")
oneshot_identifiers=(io.github.ytwsy.oneshot io.github.ytwsy.oneshot.capture-probe io.github.ytwsy.oneshot.mcp)
for oneshot_index in 1 2 3; do
  oneshot_binary="${oneshot_binaries[$oneshot_index]}"
  [[ -f "$oneshot_binary" && -x "$oneshot_binary" && ! -L "$oneshot_binary" ]] || { print -u2 "Missing executable: $oneshot_binary"; exit 65; }
  [[ "$(lipo -archs "$oneshot_binary")" == arm64 ]] || { print -u2 "Unexpected binary architecture: $oneshot_binary"; exit 65; }
  oneshot_signature="$(codesign -d --verbose=4 "$oneshot_binary" 2>&1)"
  [[ "$oneshot_signature" == *"Identifier=${oneshot_identifiers[$oneshot_index]}"* \
      && "$oneshot_signature" == *"Signature=adhoc"* \
      && "$oneshot_signature" == *"TeamIdentifier=not set"* \
      && "$oneshot_signature" == *"runtime"* ]] || {
    print -u2 "Unexpected signing identity or missing hardened runtime: $oneshot_binary"; exit 65
  }
  # Check the Mach-O deployment target as well as the user-visible Info.plist.
  oneshot_build_info="$(xcrun vtool -show-build "$oneshot_binary")"
  [[ "$oneshot_build_info" == *"minos 14.0"* ]] || { print -u2 "Unexpected Mach-O minimum macOS: $oneshot_binary"; exit 65; }
done
codesign --verify --deep --strict --verbose=2 "$oneshot_app"
print "Verified OneShot v${oneshot_version} build ${oneshot_build_number}: arm64, macOS 14.0, nested components, ad-hoc signatures, source ${oneshot_commit}."
print "This checks package structure and signature integrity, not notarization, Gatekeeper acceptance, TCC permissions or real capture behavior."
