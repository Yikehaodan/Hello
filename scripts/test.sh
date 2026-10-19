#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
for suite in portability core app-preferences speech-models library voice-animation gateway-retry memory voice-model agent; do
    print "Testing $suite"
    zsh "tests/test-$suite.sh"
done
for fixture in StartupResponsivenessTests GatewayWarmupTests; do
    print "Testing $fixture"
    VOICE_MODEL_TEST_SOURCE="tests/$fixture.swift" zsh tests/test-voice-model.sh
done
python3 tests/test-model-downloads.py
