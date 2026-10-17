# 本地模型

## 从应用下载

在“设置 → 语音模型”中选择模型，再点击下载。完成下载与校验后才能使用。首次下载 Qwen 轻量版时，会先下载原版权重再在本机转换，下载量大于最终模型大小。

安装目录下的 `Models/` 保存可用模型，`Downloads/` 保存下载缓存与未完成文件。模型目录在新安装中位于 `~/Library/Application Support/Knock/SpeechModels/`，升级安装可能继续使用 `LightVoice` 目录。

下载会检查文件大小与 SHA-256。取消或中断后保留未完成数据，继续下载时尝试 HTTP Range 续传。服务端不支持续传或文件校验失败时，会重新获取相关文件。下载与校验完成前不会替换原来的可用模型。

## 命令行准备

先完成应用构建，然后运行：

```sh
zsh scripts/models.sh --list
zsh scripts/models.sh --install zipformer
zsh scripts/models.sh --verify zipformer
```

可选模型 ID 为 `whisper`、`zipformer`、`sensevoice`、`qwen` 和 `qwen-lite`。`--verify` 会读取全部模型文件做哈希校验，大模型可能需要一段时间。

已有权重时，可以导入本地目录：

```sh
zsh scripts/models.sh --install whisper --adopt "/path/to/whisper-files"
```

导入目录的文件名、大小和哈希必须与 `source/speech-runtime/models.json` 一致。导入不会删除来源目录，也不会绕过校验。导入成功后，在应用内刷新模型状态并选择对应模型。

## 网络与磁盘

- Whisper 默认从 Hugging Face 下载；Zipformer 与 SenseVoice 从上游 GitHub Release 下载；Qwen 原版权重从 ModelScope 下载。
- 网络中断后可继续下载，无需重新构建应用。
- Hugging Face 下载可通过 `KNOCK_HF_ENDPOINT` 指定自己的 HTTPS 镜像，仍使用同一组校验值。
- 模型安装前会检查空间。下载、解压或转换期间需要额外磁盘空间；Qwen 轻量版转换还需要较多内存。
- 可以通过 `KNOCK_MODELS_DIR` 把模型保存在外置磁盘；命令行下载与应用启动必须使用相同设置。

模型清单记录上游来源和文件校验值。模型权重不包含在 Git 仓库中。
