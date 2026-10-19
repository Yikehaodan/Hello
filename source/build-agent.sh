#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
runtime_source="$PWD/source/agent-runtime"
runtime_target="${HELLO_AGENT_BUILD_DIR:-$PWD/Hello.app/Contents/Resources/AgentRuntime}"
node_path="${HELLO_AGENT_NODE:-$(command -v node)}"
[[ -x "$node_path" ]] || { print '需要 Node.js 22 或更新版本来构建 Agent 组件。'; exit 1; }
"$node_path" -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)'
if ! "$node_path" -e 'const fs=require("fs"); const base=process.argv[1]; const expected=JSON.parse(fs.readFileSync(base+"/package.json")).dependencies["@anthropic-ai/claude-agent-sdk"]; try {if(JSON.parse(fs.readFileSync(base+"/node_modules/@anthropic-ai/claude-agent-sdk/package.json")).version!==expected) process.exit(1)} catch {process.exit(1)}' "$runtime_source"; then
    npm ci --prefix "$runtime_source" --no-audit --no-fund
fi
mkdir -p "$runtime_target"
cp "$node_path" "$runtime_target/node"
node_license="${HELLO_AGENT_NODE_LICENSE:-${node_path:h:h}/LICENSE}"
[[ -f "$node_license" ]] || { print '未找到 Node.js 许可证，请用 HELLO_AGENT_NODE_LICENSE 指定许可证文件。'; exit 1; }
cp "$node_license" "$runtime_target/NODE_LICENSE"
chmod 755 "$runtime_target/node"
cp "$runtime_source/bridge.mjs" "$runtime_source/package.json" "$runtime_source/package-lock.json" "$runtime_target/"
rsync -a --delete "$runtime_source/node_modules/" "$runtime_target/node_modules/"
"$runtime_target/node" --check "$runtime_target/bridge.mjs"
print "Agent 运行组件已准备：$runtime_target"
