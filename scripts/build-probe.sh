#!/bin/zsh
set -euo pipefail
oneshot_root="${0:A:h:h}"
cd "$oneshot_root"
export CLANG_MODULE_CACHE_PATH="$oneshot_root/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$oneshot_root/.build/swift-module-cache"
swift build --disable-sandbox
oneshot_bundle="$oneshot_root/.build/OneShot Probe.app"
mkdir -p "$oneshot_bundle/Contents/MacOS"
cp .build/debug/oneshot "$oneshot_bundle/Contents/MacOS/oneshot"
cat > "$oneshot_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.oneshot.capture-probe</string>
<key>CFBundleName</key><string>OneShot Probe</string>
<key>CFBundleDisplayName</key><string>OneShot Probe</string>
<key>CFBundleExecutable</key><string>oneshot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Capture the window explicitly selected for a OneShot context experiment.</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier dev.oneshot.capture-probe "$oneshot_bundle"
print "$oneshot_bundle"
