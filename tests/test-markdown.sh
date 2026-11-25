#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/hello-markdown-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT
: > "$test_temp/empty.modulemap"
cat > "$test_temp/overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$test_temp/empty.modulemap"}]}
JSON
xcrun swiftc -vfsoverlay "$test_temp/overlay.json" source/MarkdownDocument.swift tests/MarkdownTests.swift -o "$test_temp/tests"
"$test_temp/tests"
