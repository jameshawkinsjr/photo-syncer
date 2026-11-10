#!/bin/bash
#
# Runs the tests. With only the Command Line Tools installed (no Xcode), SwiftPM
# doesn't find Swift Testing's macro plugin and framework on its own, so this
# points it at them. With Xcode, plain `swift test` works too.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
choose_sdk

CLT=/Library/Developer/CommandLineTools
if [ "$(xcode-select -p)" = "$CLT" ]; then
    exec swift test \
        -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
        -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" "$@"
fi
exec swift test "$@"
