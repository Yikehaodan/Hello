#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
HUD_TEST_SOURCE=tests/DatabaseMigrationTests.swift zsh tests/test-hud-integration.sh
