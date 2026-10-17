#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
python="$PWD/Knock.app/Contents/Resources/SpeechRuntime/python/bin/python3"
[[ -x "$python" ]] || { print '请先运行 zsh scripts/setup.sh 构建应用运行组件。'; exit 1; }
data_root="${KNOCK_DATA_DIR:-$HOME/Library/Application Support/Knock}"
if [[ -z "${KNOCK_DATA_DIR:-}" && -d "$HOME/Library/Application Support/LightVoice" ]]; then
    data_root="$HOME/Library/Application Support/LightVoice"
fi
model_root="${KNOCK_MODELS_DIR:-$data_root/SpeechModels}"
exec "$python" -I -B source/speech-runtime/model_manager.py --root "$model_root" "$@"
