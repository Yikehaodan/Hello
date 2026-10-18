#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
python="$PWD/Hello.app/Contents/Resources/SpeechRuntime/python/bin/python3"
[[ -x "$python" ]] || { print '请先运行 zsh scripts/setup.sh 构建应用运行组件。'; exit 1; }
data_root="${HELLO_DATA_DIR:-${KNOCK_DATA_DIR:-}}"
if [[ -z "$data_root" ]]; then
    data_root="$HOME/Library/Application Support/Hello"
    for legacy in LightVoice Knock; do
        if [[ -d "$HOME/Library/Application Support/$legacy" ]]; then
            data_root="$HOME/Library/Application Support/$legacy"
            break
        fi
    done
fi
model_root="${HELLO_MODELS_DIR:-${KNOCK_MODELS_DIR:-$data_root/SpeechModels}}"
exec "$python" -I -B source/speech-runtime/model_manager.py --root "$model_root" "$@"
