#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
[[ $# -ge 1 ]] || { print '用法: source/build-worker.sh whisper.cpp源码目录 [输出目录]'; exit 1; }
worker_source="${1:A}"
worker_output="${2:-$PWD/Knock.app/Contents/Resources}"
worker_build=$(mktemp -d "${TMPDIR:-/tmp}/lightvoice-worker.XXXXXX")
trap 'rm -rf "$worker_build"' EXIT
python3 source/asr-worker/prepare-whisper.py "$worker_source/src/whisper.cpp" "$worker_build/whisper-encoder-reuse.cpp"
cmake -S source/asr-worker -B "$worker_build" -DCMAKE_BUILD_TYPE=Release -DWHISPER_SOURCE_DIR="$worker_source" -DLIGHTVOICE_WHISPER_SOURCE="$worker_build/whisper-encoder-reuse.cpp"
cmake --build "$worker_build" --config Release --target lightvoice-asr-worker -j 4
mkdir -p "$worker_output"
cp "$worker_build/lightvoice-asr-worker" "$worker_output/lightvoice-asr-worker"
print '常驻识别引擎编译完成。'
