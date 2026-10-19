# Hello Agent

## 使用方法

Fn + Space 现在用于提交 Agent 任务。按下快捷键开始说话，再按 Fn 结束录音。Hello 转写后启动任务，在气泡里显示进度和结果。普通 Fn 听写可在任务运行时继续使用。

在主窗口点击“Agent 任务”，也可以输入文字。运行中发送的补充会排队，当前一轮结束后继续。任务完成后，Fn + Space 开始新任务；在气泡里输入或点击麦克风，则继续当前会话。

Esc 在录音时取消录音，在 Agent 气泡中隐藏界面。隐藏后任务继续，点击“停止”才中断执行。菜单栏的“打开 Agent / 任务记录”可以重新打开气泡。

## 配置模型

打开“设置 → 服务配置 → 配置 Agent 模型”，填写服务地址、API Key、模型名称和工作目录。完整构建包含 Node.js 和 Claude Agent SDK 运行组件，使用者无需安装 Claude 桌面应用。

DeepSeek 使用 `https://api.deepseek.com/anthropic`，鉴权选择 Bearer Token。模型名称按服务商文档填写。“导入 Hello 文字服务”可以复用已有的 DeepSeek Key。其他文字服务需要单独提供 Anthropic Messages 兼容地址，不能直接导入 Chat Completions 地址。

点击“测试模型与工具”后，Hello 在临时目录生成随机文件，让模型通过 Read 工具读取。只有工具调用和文件内容都正确，界面才显示验证成功。测试会产生少量模型用量。验证通过后点击“保存”。

API Key 存在 macOS 钥匙串，其他配置位于 Hello 数据目录的 `Agent/settings.json`。修改配置在下次任务生效；服务地址、模型或工作目录改变时，会开启新会话。

## 工具和操作确认

Agent 提供文件读取、查找、编辑、命令执行和追问工具。写入、编辑和命令执行会显示操作详情，用户可允许一次或拒绝。工作目录用于确定任务起点，不构成操作系统沙箱。

搜索和天气由 Hello 注册为 MCP 工具。搜索继续读取原有的 `search.json`，沿用签名、服务发现和重试逻辑。搜索结果会返回给模型，气泡也显示来源链接。缺少搜索配置时，工具返回配置错误。

Agent 不提供鼠标键盘自动操作。任务需要外部发送、发布或删除时，仍需要用户确认具体操作。

## 记录和数据

任务、选文和工具结果会发送到你配置的模型服务。Hello 不把 API Key 放入命令行参数或任务记录。

Agent 对话保存在 `Agent/tasks.json`，SDK 会话位于 `Agent/claude`。它们独立于听写历史，不受听写历史保留时间控制。可在 Agent 设置中清空任务记录和会话缓存；工作目录内生成的文件会保留。应用退出时会停止正在执行的任务，下次可以从任务记录继续。

## 构建与测试

构建需要 Node.js 22 或更新版本。SDK 版本及其依赖由 `source/agent-runtime/package-lock.json` 固定。

```sh
npm ci --prefix source/agent-runtime
zsh source/build-agent.sh
zsh source/build.sh
zsh tests/test-agent.sh
```

`test-agent.sh` 检查 Swift 侧的配置、会话、排队和取消，也运行真实 SDK 与本机模拟模型的集成测试。模拟测试包含文件读取、搜索回调、拒绝写入、追问、会话恢复和取消。

可选的 `node tests/agent-deepseek-smoke.mjs` 使用现有官方 DeepSeek 配置，只发送临时文件测试任务。测试有真实 API 用量，不包含项目文件或听写历史。

接入参考：[Claude Agent SDK 配置](https://code.claude.com/docs/en/agent-sdk/configuration)、[DeepSeek 接入 Claude Code](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/)。非 Claude 模型的兼容性由服务商提供，SDK 升级后需要重新验证工具调用。
