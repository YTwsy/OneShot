#!/bin/zsh
# Build a self-contained preview from an exact, clean Git source snapshot.
set -euo pipefail
umask 022

oneshot_root="${0:A:h:h}"
oneshot_version=""
oneshot_build_number="1"
oneshot_ref="HEAD"
oneshot_output_root="$oneshot_root/artifacts"

oneshot_usage() {
  print "Usage: zsh scripts/build-release.sh --version 0.1.0-alpha.1 [--build-number 1] [--ref HEAD] [--output-dir /absolute/artifacts]"
}
while (( $# > 0 )); do
  case "$1" in
    --version|--build-number|--ref|--output-dir)
      (( $# >= 2 )) || { oneshot_usage >&2; exit 64; }
      case "$1" in
        --version) oneshot_version="$2" ;;
        --build-number) oneshot_build_number="$2" ;;
        --ref) oneshot_ref="$2" ;;
        --output-dir) oneshot_output_root="$2" ;;
      esac
      shift 2
      ;;
    --help|-h) oneshot_usage; exit 0 ;;
    *) print -u2 "Unknown release option: $1"; oneshot_usage >&2; exit 64 ;;
  esac
done
[[ -n "$oneshot_version" ]] || { oneshot_usage >&2; exit 64; }
[[ "$oneshot_output_root" == /* ]] || { print -u2 "--output-dir must be absolute."; exit 64; }
cd "$oneshot_root"
oneshot_commit="$(git rev-parse --verify "${oneshot_ref}^{commit}")"
python3 packaging/release_metadata.py validate --version "$oneshot_version" \
  --build-number "$oneshot_build_number" --commit "$oneshot_commit" > /dev/null
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
  print -u2 "Release builds require a clean working tree, including untracked source. Commit the intended files first."
  exit 65
}
for oneshot_tool in swift python3 codesign lipo plutil iconutil hdiutil shasum; do
  command -v "$oneshot_tool" > /dev/null || { print -u2 "Missing release tool: $oneshot_tool"; exit 69; }
done

oneshot_temporary="$(mktemp -d "${TMPDIR:-/private/tmp}/oneshot-release.XXXXXXXX")"
oneshot_temporary="${oneshot_temporary:A}"
trap 'rm -rf "$oneshot_temporary"' EXIT
oneshot_source="$oneshot_temporary/source"
mkdir "$oneshot_source"
git archive --format=tar "$oneshot_commit" | tar -xf - -C "$oneshot_source"
[[ -f "$oneshot_source/LICENSE" && -f "$oneshot_source/packaging/release_metadata.py" ]] || {
  print -u2 "Selected commit does not contain the complete release tooling and LICENSE."; exit 65
}
oneshot_payload="$oneshot_temporary/payload"
oneshot_app="$oneshot_payload/OneShot.app"
oneshot_capture="$oneshot_app/Contents/Helpers/OneShot Capture.app"
mkdir -p "$oneshot_app/Contents/MacOS" "$oneshot_app/Contents/Resources" \
  "$oneshot_capture/Contents/MacOS" "$oneshot_capture/Contents/Resources"
python3 "$oneshot_source/packaging/release_metadata.py" bundles --version "$oneshot_version" \
  --build-number "$oneshot_build_number" --commit "$oneshot_commit" --path "$oneshot_app"

export CLANG_MODULE_CACHE_PATH="$oneshot_temporary/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$oneshot_temporary/swift-module-cache"
export MACOSX_DEPLOYMENT_TARGET=14.0
cd "$oneshot_source"
oneshot_swift_args=(-c release --arch arm64 --scratch-path "$oneshot_temporary/swift-build" --disable-sandbox)
for oneshot_product in oneshot-editor oneshot oneshot-mcp; do
  swift build "${oneshot_swift_args[@]}" --product "$oneshot_product"
done
oneshot_binary_directory="$(swift build "${oneshot_swift_args[@]}" --show-bin-path)"
cp "$oneshot_binary_directory/oneshot-editor" "$oneshot_app/Contents/MacOS/oneshot-editor"
cp "$oneshot_binary_directory/oneshot" "$oneshot_capture/Contents/MacOS/oneshot"
cp "$oneshot_binary_directory/oneshot-mcp" "$oneshot_app/Contents/Helpers/oneshot-mcp"
swiftc "$oneshot_source/packaging/render-icon.swift" -o "$oneshot_temporary/render-icon"
"$oneshot_temporary/render-icon" "$oneshot_temporary/OneShot.iconset"
iconutil -c icns "$oneshot_temporary/OneShot.iconset" -o "$oneshot_app/Contents/Resources/OneShot.icns"
cp "$oneshot_app/Contents/Resources/OneShot.icns" "$oneshot_capture/Contents/Resources/OneShot.icns"
cp "$oneshot_source/LICENSE" "$oneshot_app/Contents/Resources/LICENSE"
cp "$oneshot_source/packaging/INSTALL.txt" "$oneshot_app/Contents/Resources/INSTALL.txt"

# Sign nested code first. --deep is used only by verification, never as a signing shortcut.
codesign --force --sign - --options runtime --timestamp=none \
  --identifier io.github.ytwsy.oneshot.mcp "$oneshot_app/Contents/Helpers/oneshot-mcp"
codesign --force --sign - --options runtime --timestamp=none \
  --identifier io.github.ytwsy.oneshot.capture-probe "$oneshot_capture"
codesign --force --sign - --options runtime --timestamp=none \
  --identifier io.github.ytwsy.oneshot "$oneshot_app"
zsh "$oneshot_source/scripts/verify-release.sh" "$oneshot_app" "$oneshot_version" "$oneshot_build_number" "$oneshot_commit"
cp "$oneshot_source/packaging/INSTALL.txt" "$oneshot_payload/README.txt"
cp "$oneshot_source/LICENSE" "$oneshot_payload/LICENSE"
ln -s /Applications "$oneshot_payload/Applications"

oneshot_artifact_name="OneShot-${oneshot_version}-macos-arm64-ad-hoc-unnotarized"
oneshot_release_directory="$oneshot_output_root/OneShot-${oneshot_version}-build${oneshot_build_number}-${oneshot_commit[1,12]}"
# Reserve a fresh final directory before creating any artifact. Existing releases survive unchanged.
mkdir -p "$oneshot_output_root"
mkdir "$oneshot_release_directory" || { print -u2 "Release destination already exists; choose a new version or build number."; exit 73; }
oneshot_image="$oneshot_release_directory/${oneshot_artifact_name}.dmg"
hdiutil create -fs HFS+ -format UDZO -volname "OneShot ${oneshot_version}" \
  -srcfolder "$oneshot_payload" "$oneshot_image"
ditto "$oneshot_app" "$oneshot_release_directory/OneShot.app"
git -C "$oneshot_root" archive --format=tar.gz --prefix="OneShot-${oneshot_version}/" \
  -o "$oneshot_release_directory/OneShot-${oneshot_version}-source.tar.gz" "$oneshot_commit"
cd "$oneshot_release_directory"
shasum -a 256 "${oneshot_artifact_name}.dmg" > "${oneshot_artifact_name}.dmg.sha256"
shasum -a 256 -c "${oneshot_artifact_name}.dmg.sha256"
python3 "$oneshot_source/packaging/release_metadata.py" manifest --version "$oneshot_version" \
  --build-number "$oneshot_build_number" --commit "$oneshot_commit" --path "$oneshot_release_directory"
print "Release source: $oneshot_commit"
print "Release app: $oneshot_release_directory/OneShot.app"
print "Release DMG: $oneshot_image"
print "Signing: ad-hoc; Developer ID: no; notarized: no; architecture: arm64; minimum macOS: 14.0"
