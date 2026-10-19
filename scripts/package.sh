#!/bin/zsh
# Build a self-contained drag-to-Applications disk image on Apple Silicon macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${HELLO_SEARCH_CONFIG:-${KNOCK_SEARCH_CONFIG:-}}" ]]; then
    print -u2 '发布安装包不能使用私人搜索配置，请取消 HELLO_SEARCH_CONFIG 后重试。'
    exit 1
fi
zsh scripts/doctor.sh
zsh source/build.sh
app="$PWD/Hello.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" == [0-9]* && "$version" != */* ]] || exit 1
# Older development bundles can contain model weights or personal configuration.
python3 - "$app" <<'PY'
import sys
from pathlib import Path
resources = Path(sys.argv[1]) / 'Contents/Resources'
allowed = {'Hello.icns', 'SpeechModels', 'SpeechRuntime', 'whisper-cli',
           'lightvoice-asr-worker', 'whisper-LICENSE.txt', 'THIRD_PARTY_NOTICES.md', 'AgentRuntime'}
extra = {p.name for p in resources.iterdir()} - allowed
model_files = {p.name for p in (resources / 'SpeechModels').iterdir()}
expected = {'model_manager.py', 'speech_worker.py', 'models.json'}
if extra or model_files != expected:
    raise SystemExit('应用包包含额外资源或模型，请在干净的源码目录重新构建后打包。')
PY
codesign --verify --deep --strict "$app"
mkdir -p dist
filename="Hello-${version}-macOS-arm64.dmg"
[[ ! -e "dist/$filename" ]] || { print -u2 "dist/$filename 已存在，请先移走旧文件。"; exit 1; }
package_temp=$(mktemp -d "${TMPDIR:-/tmp}/hello-package.XXXXXX")
trap 'rm -rf "$package_temp"' EXIT
mkdir "$package_temp/image"
ditto --noqtn "$app" "$package_temp/image/Hello.app"
ln -s /Applications "$package_temp/image/Applications"
cp docs/INSTALL.md "$package_temp/image/安装说明 Installation.txt"
cp THIRD_PARTY_NOTICES.md "$package_temp/image/Third Party Notices.txt"
codesign --verify --deep --strict "$package_temp/image/Hello.app"
hdiutil create -volname "Hello $version" -srcfolder "$package_temp/image" \
    -fs HFS+ -format UDZO "$package_temp/$filename"
hdiutil verify "$package_temp/$filename"
mv "$package_temp/$filename" "dist/$filename"
(cd dist && shasum -a 256 "$filename" > "${filename}.sha256")
print "已生成 dist/$filename 及 SHA-256 校验文件。"
print '此脚本不会执行 Apple 公证；发布时请准确注明实际签名与公证状态。'
