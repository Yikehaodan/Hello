#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/lightvoice-animation-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT
: > "$test_temp/empty.modulemap"
cat > "$test_temp/overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$test_temp/empty.modulemap"}]}
JSON
xcrun swiftc -vfsoverlay "$test_temp/overlay.json" -module-cache-path "${TMPDIR:-/tmp}/lightvoice-module-cache" -target arm64-apple-macos14.0 source/AppPaths.swift source/VoiceAnimation.swift tests/VoiceAnimationTests.swift -o "$test_temp/animation-tests" -framework SwiftUI
"$test_temp/animation-tests"
