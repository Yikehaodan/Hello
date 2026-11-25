#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/lightvoice-hud-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT
: > "$test_temp/empty.modulemap"
cat > "$test_temp/overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$test_temp/empty.modulemap"}]}
JSON
# Compile the production AppDelegate verbatim, excluding only its top-level CLI dispatcher.
awk '/^if let index = CommandLine.arguments.firstIndex/ { exit } { print }' source/main.swift > "$test_temp/AppDelegate.swift"
sources=(source/*.swift)
sources=("${(@)sources:#source/main.swift}")
xcrun swiftc -vfsoverlay "$test_temp/overlay.json" -module-cache-path "${TMPDIR:-/tmp}/lightvoice-module-cache" -target arm64-apple-macos14.0 "${sources[@]}" "$test_temp/AppDelegate.swift" tests/FaultTransport.swift "${HUD_TEST_SOURCE:-tests/HUDIntegrationTests.swift}" -o "$test_temp/hud-tests" -lz -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices -framework ServiceManagement
"$test_temp/hud-tests" "${HUD_OUTPUT_DIR:-$PWD/tests/hud-validation}"
