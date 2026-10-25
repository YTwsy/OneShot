#!/bin/zsh
set -euo pipefail
oneshot_root="${0:A:h:h}"
cd "$oneshot_root"
export CLANG_MODULE_CACHE_PATH="$oneshot_root/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$oneshot_root/.build/swift-module-cache"
swift build --disable-sandbox --product oneshot-editor
oneshot_editor_bundle="$oneshot_root/.build/OneShot Editor.app"
mkdir -p "$oneshot_editor_bundle/Contents/MacOS"
cp .build/debug/oneshot-editor "$oneshot_editor_bundle/Contents/MacOS/oneshot-editor"
cat > "$oneshot_editor_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.oneshot.editor</string>
<key>CFBundleName</key><string>OneShot Editor</string>
<key>CFBundleDisplayName</key><string>OneShot Editor</string>
<key>CFBundleExecutable</key><string>oneshot-editor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>OneShot Annotation Project</string>
<key>CFBundleTypeExtensions</key><array><string>oneshot</string></array>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSTypeIsPackage</key><true/>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign "${ONESHOT_SIGN_IDENTITY:--}" --identifier dev.oneshot.editor "$oneshot_editor_bundle"
print "$oneshot_editor_bundle"
