#!/bin/zsh
set -euo pipefail
oneshot_root="${0:A:h:h}"
cd "$oneshot_root"
export CLANG_MODULE_CACHE_PATH="$oneshot_root/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$oneshot_root/.build/swift-module-cache"
oneshot_developer="$(xcode-select -p)"
oneshot_frameworks="$oneshot_developer/Library/Developer/Frameworks"
if [[ -d "$oneshot_frameworks/Testing.framework" ]]; then
  # Command Line Tools ships Swift Testing, but no XCTest framework.
  swift test --disable-sandbox --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$oneshot_frameworks" \
    -Xlinker -F -Xlinker "$oneshot_frameworks" \
    -Xlinker -rpath -Xlinker "$oneshot_frameworks" "$@"
else
  swift test --disable-sandbox --disable-xctest --enable-swift-testing "$@"
fi
