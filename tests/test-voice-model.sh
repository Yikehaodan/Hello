#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/lightvoice-controller-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT
: > "$test_temp/empty.modulemap"
cat > "$test_temp/overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$test_temp/empty.modulemap"}]}
JSON
xcrun swiftc -vfsoverlay "$test_temp/overlay.json" -module-cache-path "${TMPDIR:-/tmp}/lightvoice-module-cache" -target arm64-apple-macos14.0 source/AppPaths.swift source/InputMode.swift source/LibraryStore.swift source/LocalASR.swift source/ResidentASR.swift source/LiveTranscription.swift source/CloudTranscription.swift source/PersonalMemory.swift source/Gateway.swift source/AnswerSources.swift source/MemoryCapture.swift source/TextInsertion.swift source/AppPreferences.swift source/VoiceRecording.swift source/SpeechModels.swift source/ManagedSpeechASR.swift source/ManagedSpeechStream.swift source/VoiceModel.swift "${VOICE_MODEL_TEST_SOURCE:-tests/VoiceModelTests.swift}" -o "$test_temp/controller-tests" -lz -framework AppKit -framework AVFoundation -framework ApplicationServices -framework ServiceManagement
"$test_temp/controller-tests"
