#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
command -v cmake >/dev/null || { print '缺少 CMake，请先运行 zsh scripts/doctor.sh。'; exit 1; }
# Cache source and build outputs. Model weights are downloaded on demand in the app.
cache="$PWD/.build-runtime/whisper"
resources="$PWD/Hello.app/Contents/Resources"
mkdir -p "$cache" "$resources"
if [[ ! -f "$cache/whisper.cpp-1.9.5/CMakeLists.txt" ]]; then
    curl -fL --retry 4 --retry-delay 2 --connect-timeout 20 --max-time 600 \
        https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.5 -o "$cache/source.tar.gz.part"
    tar -xzf "$cache/source.tar.gz.part" -C "$cache"
    mv "$cache/source.tar.gz.part" "$cache/source.tar.gz"
fi
cmake -S "$cache/whisper.cpp-1.9.5" -B "$cache/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_NATIVE=OFF
cmake --build "$cache/build" --config Release --target whisper-cli -j "${HELLO_BUILD_JOBS:-${KNOCK_BUILD_JOBS:-4}}"
cp "$cache/build/bin/whisper-cli" "$resources/"
zsh source/build-worker.sh "$cache/whisper.cpp-1.9.5" "$resources"
cp "$cache/whisper.cpp-1.9.5/LICENSE" "$resources/whisper-LICENSE.txt"
print '本地识别引擎已准备。模型权重将在应用内按需下载。'
