# Hello Agent

## 使用方法

Fn + Space 现在用于提交 Agent 任务。按下快捷键开始说话，再按 Fn 结束录音。Hello 转写后启动任务，在紧凑浮窗显示进度。完成后自动打开普通结果窗口，正文按 Markdown 排版。Fn 上下文听写可在任务运行时继续使用。

Agent 对话与语音输入统一显示在“历史记录”，按日期排序。点击任务可打开结果窗口，也可以继续输入文字。运行中发送的补充会排队，当前一轮结束后继续。任务完成后，Fn + Space 开始新任务；在结果窗口输入或点击麦克风，则继续当前会话。

Esc 在录音时取消录音，在 Agent 执行时隐藏浮窗。隐藏后任务继续，完成时也不会重新弹出窗口。点击“停止”可中断执行；菜单栏的“历史记录”可重新查看任务。

## 配置模型

打开“设置 → 服务配置 → 配置 Agent 模型”，填写服务地址、API Key、模型名称和工作目录。完整构建包含 Node.js 和 Claude Agent SDK 运行组件，使用者无需安装 Claude 桌面应用。

DeepSeek 使用 `https://api.deepseek.com/anthropic`，鉴权选择 Bearer Token。选择“DeepSeek V4.1 Flash”会填入官方模型名称 `deepseek-flash`，截至 2026 年 10 月 19 日对应 V4.1 Flash 1017。“导入 Hello 文字服务”可以复用已有的 DeepSeek Key。其他文字服务需要单独提供 Anthropic Messages 兼容地址，不能直接导入 Chat Completions 地址。

点击“测试模型与工具”后，Hello 在临时目录生成随机文件，让模型通过 Read 工具读取。只有工具调用和文件内容都正确，界面才显示验证成功。测试会产生少量模型用量。验证通过后点击“保存”。

API Key 保存在 Hello 数据目录的 `Agent/api-key`，文件权限为 `0600`，仅当前用户可读写。其他配置位于 `Agent/settings.json`。填写并保存后即可使用，不再访问 macOS 钥匙串。修改配置在下次任务生效；服务地址、模型或工作目录改变时，会开启新会话。

## 工具和操作确认

Agent 提供文件读取、查找、编辑、命令执行和追问工具。写入、编辑和命令执行会显示操作详情，用户可允许一次或拒绝。工作目录用于确定任务起点，不构成操作系统沙箱。

使用 DeepSeek 官方接口时，Agent 通过 SDK 的 WebSearch 联网搜索，通过 WebFetch 核实网页原文，无需另配搜索 Key。执行浮窗显示当前状态，结果窗口用来源卡片展示实际链接；展开“执行过程”可查看工具记录。搜索和网页读取会产生服务商用量。

旧 Hello 搜索服务已移除，应用不再读取 `search.json`，也不再调用内网服务发现和 `/search/api`。其他模型服务暂不启用联网搜索。天气继续使用 Hello weather 工具。

Agent 不提供鼠标键盘自动操作。任务需要外部发送、发布或删除时，仍需要用户确认具体操作。

## 记录和数据

任务、选文和工具结果会发送到你配置的模型服务。Hello 不把 API Key 放入命令行参数或任务记录。

Agent 对话保存在 `Agent/records.sqlite`，SDK 会话位于 `Agent/claude`。界面将 Agent 对话与听写历史统一展示，关联录音和截图可在任务条目内展开。Agent 对话与 SDK 会话仍单独存储，不受语音历史保留时间控制。可在 Agent 设置中清空任务记录和会话缓存；工作目录内生成的文件会保留。应用退出时会停止正在执行的任务，下次可以从任务记录继续。

首次升级自动导入旧 `Agent/tasks.json`，并保留原文件和 `Agent/MigrationBackups/tasks.json` 备份。历史列表每批加载 50 条，搜索覆盖全部任务和关联录音文字。备份会保留升级前的内容，删除当前任务不会修改备份。

## 构建与测试

构建需要 Node.js 22 或更新版本。SDK 版本及其依赖由 `source/agent-runtime/package-lock.json` 固定。

```sh
npm ci --prefix source/agent-runtime
zsh source/build-agent.sh
zsh source/build.sh
zsh tests/test-agent.sh
```

`test-agent.sh` 检查 Swift 侧的配置、会话、排队和取消，也运行真实 SDK 与本机模拟模型的集成测试。模拟测试包含文件读取、天气回调和原生搜索来源解析、拒绝写入、追问、会话恢复和取消。

可选的 `node tests/agent-deepseek-smoke.mjs` 使用现有官方 DeepSeek 配置，只发送临时文件测试任务。测试有真实 API 用量，不包含项目文件或听写历史。

可选的 `node tests/agent-deepseek-search-live.mjs` 使用已保存的 Agent 配置和本机密钥，先向官方接口核对模型，再验证至少两次原生搜索、读取官方网页、返回来源和最终答案。测试拒绝本地文件操作和原搜索服务回调，有真实 API 用量。可用 `HELLO_TEST_AGENT_RUNTIME` 指定已安装的运行组件，用 `HELLO_SEARCH_REPORT` 保存测试结果。

接入参考：[Claude Agent SDK 配置](https://code.claude.com/docs/en/agent-sdk/configuration)、[DeepSeek 接入 Claude Code](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/)。非 Claude 模型的兼容性由服务商提供，SDK 升级后需要重新验证工具调用。
