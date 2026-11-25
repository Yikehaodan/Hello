#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
for suite in portability core app-preferences speech-models library voice-animation gateway-retry memory voice-model markdown agent database sidebar-hover token-usage; do
    print "Testing $suite"
    zsh "tests/test-$suite.sh"
done
for fixture in StartupResponsivenessTests ContextStartupTests GatewayWarmupTests ProcessingTimingTests; do
    print "Testing $fixture"
    VOICE_MODEL_TEST_SOURCE="tests/$fixture.swift" zsh tests/test-voice-model.sh
done
for fixture in NavigationPerformanceTests AgentProgressTests AgentNavigationTests; do
    print "Testing $fixture"
    HUD_TEST_SOURCE="tests/$fixture.swift" zsh tests/test-hud-integration.sh
done
python3 tests/test-model-downloads.py
