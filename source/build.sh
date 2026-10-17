#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { print 'Knock 目前仅支持 Apple Silicon Mac。'; exit 1; }
mkdir -p 'Knock.app/Contents/MacOS'
# Remove the obsolete executable only in this generated bundle after the rename.
rm -f 'Knock.app/Contents/MacOS/LightVoice'
if [[ ! -x 'Knock.app/Contents/Resources/whisper-cli' || ! -x 'Knock.app/Contents/Resources/lightvoice-asr-worker' ]]; then
    zsh source/build-asr.sh
fi
if [[ ! -f 'Knock.app/Contents/Resources/SpeechRuntime/READY' ]]; then
    python3 source/build-speech-runtime.py
fi
mkdir -p 'Knock.app/Contents/Resources/SpeechModels'
cp source/speech-runtime/*.py source/speech-runtime/models.json 'Knock.app/Contents/Resources/SpeechModels/'
cp THIRD_PARTY_NOTICES.md 'Knock.app/Contents/Resources/'
rm -rf 'Knock.app/Contents/Resources/SpeechModels/__pycache__'
# 隔离本机旧版 SwiftBridging 文件，不修改系统工具链。
build_temp=$(mktemp -d "${TMPDIR:-/tmp}/lightvoice.XXXXXX")
trap 'rm -rf "$build_temp"' EXIT
: > "$build_temp/empty.modulemap"
cat > "$build_temp/overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$build_temp/empty.modulemap"}]}
JSON
xcrun swiftc -vfsoverlay "$build_temp/overlay.json" -module-cache-path "${TMPDIR:-/tmp}/lightvoice-module-cache" -target arm64-apple-macos14.0 source/*.swift -o 'Knock.app/Contents/MacOS/Knock' -O -lz -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices -framework ServiceManagement
xcrun swiftc -vfsoverlay "$build_temp/overlay.json" -module-cache-path "${TMPDIR:-/tmp}/lightvoice-module-cache" scripts/make-icon.swift -o "$build_temp/make-icon" -framework AppKit
mkdir -p "$build_temp/Knock.iconset"
"$build_temp/make-icon" "$build_temp/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$build_temp/icon.png" --out "$build_temp/Knock.iconset/icon_${size}x${size}.png" >/dev/null
    double=$(( size * 2 ))
    sips -z "$double" "$double" "$build_temp/icon.png" --out "$build_temp/Knock.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$build_temp/Knock.iconset" -o 'Knock.app/Contents/Resources/Knock.icns'
cat > 'Knock.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Knock</string>
<key>CFBundleIdentifier</key><string>local.lightvoice.lin</string>
<key>CFBundleName</key><string>Knock</string>
<key>CFBundleDisplayName</key><string>Knock</string>
<key>CFBundleIconFile</key><string>Knock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.0</string>
<key>CFBundleVersion</key><string>26</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Knock 仅在你主动开始录音后使用麦克风，将口述转成文字或用于语音提问。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# HTTP search exceptions are opt-in. Never bake the developer's private hosts into a public build.
if [[ -n "${KNOCK_SEARCH_CONFIG:-}" ]]; then
python3 - <<'ATS'
import json, os, plistlib
from pathlib import Path
from urllib.parse import urlparse
values = json.loads(Path(os.environ['KNOCK_SEARCH_CONFIG']).read_text())
hosts = {urlparse(values.get(field, '')).hostname for field in ('bnsHost', 'baseURL')
         if urlparse(values.get(field, '')).scheme == 'http'} - {None}
path = Path('Knock.app/Contents/Info.plist')
info = plistlib.loads(path.read_bytes())
if hosts:
    info['NSAppTransportSecurity'] = {'NSExceptionDomains': {
        host: {'NSExceptionAllowsInsecureHTTPLoads': True} for host in hosts}}
    path.write_bytes(plistlib.dumps(info))
ATS
fi
sign_dir="${KNOCK_SIGN_HOME:-${LIGHTVOICE_SIGN_HOME:-}}"
signer="$sign_dir/rcodesign/apple-codesign-0.29.0-aarch64-apple-darwin/rcodesign"
if [[ -x "$signer" && -f "$sign_dir/private.key" ]]; then
    "$signer" sign --pem-file "$sign_dir/certificate.pem" --pem-file "$sign_dir/private.key" --timestamp-url none --code-requirements-file "Contents/MacOS/Knock:$sign_dir/requirement.bin" 'Knock.app'
elif [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --sign "$CODE_SIGN_IDENTITY" 'Knock.app'
else
    codesign --force --sign - 'Knock.app/Contents/Resources/whisper-cli'
    if [[ -f 'Knock.app/Contents/Resources/lightvoice-asr-worker' ]]; then
        codesign --force --sign - 'Knock.app/Contents/Resources/lightvoice-asr-worker'
    fi
    codesign --force --deep --sign - 'Knock.app'
    print '使用临时签名，重新编译后需要重新允许权限。'
fi
codesign --verify --deep --strict 'Knock.app'
