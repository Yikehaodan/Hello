#!/bin/zsh
set -u
cd "$(dirname "$0")/.."
failures=0
check() { if "$@" >/dev/null 2>&1; then return 0; else return 1; fi; }
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  print '需要 Apple Silicon Mac；当前不支持 Intel、Windows 或 Linux。'; exit 1
fi
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || { print '需要 macOS 14 或更新版本。'; exit 1; }
if check xcrun --find swiftc && check xcrun --show-sdk-path; then print '✓ Xcode 命令行工具'; else print '缺少 Xcode 命令行工具。请运行 xcode-select --install，完成后重试。'; (( failures += 1 )); fi
if check cmake --version; then print '✓ CMake'; else print '缺少 CMake。可从 cmake.org 安装，或运行 brew install cmake。'; (( failures += 1 )); fi
if check python3 -c 'import sys; assert sys.version_info >= (3,9)'; then print '✓ Python 3.9 或更新版本'; else print '需要 Python 3.9 或更新版本。可从 python.org 安装，或运行 brew install python。'; (( failures += 1 )); fi
if (( failures > 0 )); then exit 1; fi
print '环境检查通过。首次构建需要访问 GitHub 和 PyPI；模型可在应用内按需下载。'
