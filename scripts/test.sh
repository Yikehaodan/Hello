#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
for suite in portability core app-preferences speech-models library voice-animation gateway-retry memory voice-model; do
    print "Testing $suite"
    zsh "tests/test-$suite.sh"
done
python3 tests/test-model-downloads.py
