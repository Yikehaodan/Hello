#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/hello-agent-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT
: > "$test_temp/empty.modulemap"
cat > "$test_temp/overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$test_temp/empty.modulemap"}]}
JSON
sources=(source/*.swift)
sources=("${(@)sources:#source/main.swift}")
for excluded in Views AgentViews PreviewRenderer ServiceSettingsView MemoryView PermissionsView; do
    sources=("${(@)sources:#source/${excluded}.swift}")
done
xcrun swiftc -vfsoverlay "$test_temp/overlay.json" -module-cache-path "${TMPDIR:-/tmp}/lightvoice-module-cache" -target arm64-apple-macos14.0 "${sources[@]}" tests/AgentTests.swift -o "$test_temp/agent-tests" -lz -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices -framework ServiceManagement
"$test_temp/agent-tests" "$(command -v node)"
node --test tests/agent-runtime.test.mjs
