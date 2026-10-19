<p align="center">
  <img src="docs/assets/hero.svg" alt="Hello：在 macOS 上用声音听写、翻译和改写文字。" width="100%" />
</p>
<p align="center">在你正在使用的应用里，用声音输入、翻译和改写文字。</p>
<p align="center">
  <a href="https://github.com/Yikehaodan/Hello/releases/download/v0.9.3/Hello-0.9.3-macOS-arm64.dmg"><img src="docs/assets/download-macos.svg" width="340" height="64" alt="下载 Hello v0.9.3 for macOS" /></a>
</p>
<p align="center"><sub>仅支持 Apple Silicon Mac · macOS 14+ · 公开预览版</sub></p>
<p align="center"><a href="#功能">功能</a> · <a href="#演示">观看演示</a> · <a href="#开始使用">开始使用</a> · <a href="https://github.com/Yikehaodan/Hello/releases/latest">版本记录</a></p>

## 功能

| 功能 | 快捷键 | 用法 |
| --- | --- | --- |
| 听写 | `Fn` | 把口述变成文字。开启自动整理后，可处理改口、重复和标点。 |
| 翻译 | `Fn + Shift` | 说中文，直接输入英文等目标语言。 |
| 上下文听写 | `Fn + Control` | 结合当前输入框和可选截图，校对人名与专业词。 |
| Agent | `Fn + Space` | 说出任务，查看进度、确认操作并继续追问。 |

Agent 适用于当前源码构建，v0.9.3 安装包仍为旧版问答。Agent 支持独立配置模型，详见 [Agent 使用与配置](docs/AGENT.md)。

**个人记忆会学习你纠正过的写法。** 例如多次把“小雪”改成“晓雪”，Hello 会在之后的输入中参考这个名字。在“词典 → 个人记忆”中开启，支持查看、编辑和删除。[了解记忆规则](docs/MEMORY.md)。

还支持个人词典、历史搜索和录音回放。

## 演示

https://github.com/user-attachments/assets/3470dc33-b43c-4236-a57d-f22b6f2c7b73

<sub>示例演示，等待时间已压缩。</sub>

## 开始使用

1. 打开安装包，将 `Hello.app` 拖到 `Applications`，再从“应用程序”启动。
2. 按引导开启麦克风和辅助功能权限。
3. 在“设置 → 语音模型”中下载并选择模型。中文听写可以先用 Zipformer。
4. 把光标放入输入框，按 `Fn` 开始说话，再按一次结束并输入文字。按 `Esc` 可取消。

普通本地听写无需 API Key。自动整理、翻译、上下文听写和记忆整理需要配置文字服务。在“设置 → 服务配置”中填写你自己的 API Key，默认使用 DeepSeek 官方。[配置说明](docs/SETUP.md#文字服务)。

当前版本尚未经过 Apple 公证。首次打开若被系统阻止，请按[安装帮助](docs/INSTALL.md#首次打开)操作。

Agent 运行时，`Esc` 隐藏气泡，任务会继续；点击“停止”可中断任务。

## 权限与隐私

麦克风用于录音，辅助功能用于快捷键和文字读写。屏幕录制仅用于可选的上下文截图。

本地语音模型在 Mac 上处理录音。使用云端语音或文字服务时，相关录音、文字或截图会发送到你配置的服务。

个人记忆默认关闭。开启后会观察听写后的局部纠正，并交给配置的文字服务整理；记忆保存在本机，可随时删除。[详细说明](docs/PERMISSIONS.md)。

Agent 会使用所选模型与本机执行工具。任务记录独立保存在本机，可在 Agent 设置中清空。

## 帮助与反馈

[安装与更新](docs/INSTALL.md) · [模型管理](docs/MODELS.md) · [反馈问题](https://github.com/Yikehaodan/Hello/issues)

[从源码构建](docs/SETUP.md) · [第三方组件](THIRD_PARTY_NOTICES.md)
