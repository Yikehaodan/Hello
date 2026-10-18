#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
zsh scripts/doctor.sh
zsh source/build.sh
print '构建完成：Hello.app。请拖入“应用程序”后打开，并按引导配置权限和语音模型。'
