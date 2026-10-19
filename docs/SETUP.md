# 构建与配置

只想使用 Hello，可直接下载 [Release 安装包](https://github.com/Yikehaodan/Hello/releases/latest)，按[安装指引](INSTALL.md)操作，无需以下开发工具。

## 环境

需要 Apple Silicon Mac、macOS 14 或更新版本、Xcode 命令行工具、CMake、Python 3.9 或更新版本，以及 Node.js 22 或更新版本。当前构建目标为 arm64。

```sh
xcode-select --install
# 如果已安装 Homebrew，可用它安装缺少的依赖。
brew install cmake python node
zsh scripts/doctor.sh
zsh scripts/setup.sh
```

运行 `setup.sh` 会构建 Whisper 引擎、独立 Python 运行组件、Agent 运行组件和 Swift 应用。Python 组件用于模型管理与其他本地识别引擎，不向系统 Python 安装包。GitHub 和 PyPI 下载保存在 `.build-runtime/`，再次运行会复用已完成缓存。Agent 依赖从 npm 安装，构建不需要语音或文字服务密钥。

构建脚本会将 Node.js 和 Claude Agent SDK 放入应用包。使用者无需另装 Node.js 或 Claude 桌面应用。若 Node.js 安装目录没有 `LICENSE`，可通过 `HELLO_AGENT_NODE_LICENSE` 指定对应版本的许可证文件。

模型权重在应用内按需下载。新克隆的目录无需复制开发者的应用包、模型目录、签名证书或配置。

## 文字服务

打开“设置 → 服务配置”，默认使用 DeepSeek 官方地址 `https://api.deepseek.com` 和模型 `deepseek-flash`。填写你自己的 API Key，点击“测试连接”，成功后保存。测试只发送固定测试文字，不会发送历史记录。接口参数以 [DeepSeek 官方文档](https://api-docs.deepseek.com/zh-cn/api/create-chat-completion/)为准。

也可填写其他兼容 Chat Completions 的 HTTPS 服务地址和模型名称。Hello 会在地址后追加 `/chat/completions`。已有配置会保留；点击“使用 DeepSeek 官方”切换服务商时，会清空其他服务的密钥，保存前不影响当前配置。

保存后对下一次文字处理生效。需要自动整理时，在“个性化”中开启该选项。[个人记忆](MEMORY.md)也复用这里配置的服务。

也可以复制 `examples/gateway.env.example` 到设置页显示的配置目录，命名为 `gateway.env`。文件包含：

```dotenv
HELLO_LLM_BASE_URL=https://api.deepseek.com
HELLO_LLM_API_KEY=replace-with-your-api-key
HELLO_LLM_MODEL=deepseek-flash
```

文件是键值配置，不会作为脚本执行。手动创建后建议执行 `chmod 600`，限制为当前用户读写。应用内保存会自动设置此权限。

模型需要兼容 Chat Completions。上下文截图要求支持图片输入；不同服务商支持的参数和返回格式可能不同，建议先在文本工作台试一段文字。

Fn + Space 的 Agent 使用独立配置。它需要支持 Anthropic Messages 和工具调用的服务，可导入现有 DeepSeek Key。配置与验证方法见 [Agent 使用说明](AGENT.md)。

## 云端语音

豆包云端为可选功能。将 `examples/doubao.env.example` 复制到配置目录并命名为 `doubao.env`，填写有效的 `DOUBAO_API_KEY`，随后退出并重新打开 Hello。在“语音模型”中选择豆包云端。服务额度与费用由你配置的账户承担。

未配置云端密钥时，可以使用本地模型。未配置文字服务时，新的安装默认关闭自动整理；已保存的个人选择会保留。

## 数据与可移动路径

新安装的数据目录为 `~/Library/Application Support/Hello/`。从 Knock 或更早版本升级时，继续使用已有的 `LightVoice/` 或 `Knock/` 目录，保留词典、历史和下载的模型。两者都存在时，沿用旧版规则，优先使用 `LightVoice/`。实际目录以设置页显示为准。

| 可选环境变量 | 用途 |
| --- | --- |
| `HELLO_DATA_DIR` | 数据与配置目录，使用绝对路径 |
| `HELLO_MODELS_DIR` | 模型与下载缓存目录，可放在外置磁盘，使用绝对路径 |
| `HELLO_ENV` | 自定义文字服务配置文件 |
| `HELLO_HF_ENDPOINT` | Hugging Face 模型下载的 HTTPS 镜像地址，校验规则不变 |
| `HELLO_BUILD_JOBS` | Whisper 编译并行数，默认 4 |
| `CODE_SIGN_IDENTITY` | 可选的本机代码签名身份 |

环境变量需要由启动应用的进程传入。在终端设置后运行应用包内可执行文件，例如：

```sh
HELLO_MODELS_DIR="/Volumes/Models/Hello" ./Hello.app/Contents/MacOS/Hello
```

从 Finder 双击启动不会继承普通终端的环境变量。默认路径无需配置这些变量。

原有 `KNOCK_*` 环境变量、配置键，以及 `LIGHTVOICE_ENV` 仍可读取；同时设置时优先使用 `HELLO_*`。应用保留旧 bundle identifier，以减少升级时对现有偏好设置与权限记录的影响。

## 构建和启动问题

| 情况 | 处理方法 |
| --- | --- |
| 找不到 Swift 或 SDK | 完成 Xcode 命令行工具安装，重新运行 doctor |
| 找不到 CMake | 安装 CMake，再运行 setup |
| 找不到 Node.js 或 npm | 安装 Node.js 22 或更新版本，再运行 setup |
| GitHub、PyPI 或 npm 下载失败 | 检查网络，再运行 setup；已完成缓存会复用 |
| 模型下载失败 | 在应用内点击继续下载，具体方法见模型说明 |
| 找不到模型 | 在“语音模型”中下载并选择一个模型，等待校验完成 |
| API 返回错误 | 检查地址、密钥、模型名称和服务额度；原文会保留 |
| 授权后 Fn 无响应 | 返回应用重新检查，必要时退出重开，并检查其他 Fn 工具是否冲突 |

构建产物默认使用临时签名，尚未经过 Apple 公证。请在固定位置运行应用，授权问题参见 [macOS 权限](PERMISSIONS.md)。

高级搜索适配器读取配置目录中的 `search.json`，它面向特定搜索协议，不是通用搜索 API。普通听写与翻译不依赖它。构建默认不会读取本机搜索配置；仅显式设置 `HELLO_SEARCH_CONFIG` 时，为指定 HTTP 搜索主机生成单独的网络例外。

## 打包发布

在干净的源码目录运行 `zsh scripts/package.sh`，脚本会构建应用、验证签名，并生成 `dist/Hello-<版本>-macOS-arm64.dmg` 和对应 `.sha256` 文件。DMG 包含应用、“应用程序”快捷方式与安装说明。生成目录不会提交到 Git。

脚本拒绝包含旧模型或额外顶层资源的应用包，也不接受私人搜索配置。它不会执行 Apple 公证；默认临时签名的产物需要在 Release 中说明首次打开要求。`CODE_SIGN_IDENTITY` 只指定构建签名身份，不代表已完成公证。
