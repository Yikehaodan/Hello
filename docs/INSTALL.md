# 安装 Hello

适用于 Apple Silicon Mac（M 系列芯片），需要 macOS 14 或更新版本。Intel Mac 暂不支持。

## 下载与安装

1. 从 https://github.com/Yikehaodan/Hello/releases 下载 `Hello-0.9.3-macOS-arm64.dmg`。
2. 双击打开 DMG，把 `Hello.app` 拖到旁边的 `Applications` 文件夹。
3. 从“应用程序”打开 Hello，再推出安装磁盘。

安装包已包含运行组件，无需安装 Xcode、Homebrew、Python 或 CMake。模型权重在首次使用时单独下载。

## 首次打开

**v0.9.3 使用临时签名，尚未取得 Apple Developer ID 签名或完成 Apple 公证。** 首次打开可能被 macOS 阻止。

确认文件来自本项目 Release 且你愿意信任此版本后，可先尝试打开一次，再进入“系统设置 → 隐私与安全性”，找到 Hello 的提示，点击“仍要打开”，按系统提示确认。具体名称可能随系统版本变化。参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

如果系统提示恶意软件、文件损坏，或没有相应的允许选项，请停止打开并到项目 Issues 反馈。无需关闭整个系统的安全保护。

## 完成第一次听写

1. 按应用引导允许麦克风和辅助功能。屏幕录制仅用于可选的窗口截图。
2. 打开“设置 → 语音模型”，下载并选择一个模型。中文听写可先选约 167 MB 的 Zipformer。
3. 把光标放入输入框，轻按 `Fn` 开始说话，再按一次结束。

普通本地听写无需 API Key。翻译、问答和文字整理需要在“设置 → 服务配置”填写自己的 API Key。默认使用 DeepSeek 官方，也支持其他兼容 Chat Completions 的服务。点击“测试连接”检查后保存。

个人记忆在“词典 → 个人记忆”中开启，默认关闭。开启后可学习你在原输入框里纠正的名字和固定表达，具体规则见[个人记忆](MEMORY.md)。

## 更新与卸载

更新时先退出旧版应用，再将 Hello 拖入“应用程序”。从 Knock 升级后，确认 Hello 正常运行，即可移除旧的 `Knock.app`；请勿同时运行两个版本。后续更新用新版替换 `Hello.app`。当前版本没有自动更新功能。替换应用会保留模型、词典和历史；系统可能要求重新授予权限。

卸载时退出 Hello，将应用移到废纸篓。本机数据保留在 `~/Library/Application Support/Hello/`；早期版本可能使用 `LightVoice/` 或 `Knock/`，实际位置见应用设置。只有确定不再需要历史与模型时，才手动删除对应数据目录。

## 验证下载文件（可选）

Release 同时提供 `.dmg.sha256` 文件。把两个文件放在同一个文件夹，在该文件夹的终端执行：

```sh
shasum -a 256 -c Hello-0.9.3-macOS-arm64.dmg.sha256
```

输出 `OK` 表示下载内容与发布时的校验值一致；它不代表 Apple 公证。
