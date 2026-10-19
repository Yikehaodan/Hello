# Third-party components

Hello includes or downloads components with their own licenses. Model weights are downloaded separately; their upstream terms apply.

| Component | Source and license location |
| --- | --- |
| mlx-qwen3-asr | Vendored in `vendor/qwen3-asr-mlx/`; upstream commit and Apache 2.0 license are retained there |
| whisper.cpp | Built from the pinned upstream tag in `source/build-asr.sh`; its MIT license is copied into the app |
| Whisper model | Downloaded separately from ggerganov/whisper.cpp; see the [upstream Whisper license](https://github.com/openai/whisper/blob/main/LICENSE) |
| Python standalone | Downloaded from astral-sh/python-build-standalone; runtime files retain their included notices |
| NumPy, regex, MLX, sherpa-onnx | Versioned wheels unpacked into the private runtime, retaining package metadata and licenses |
| Zipformer, SenseVoice, Qwen model weights | Sources and checksums in `source/speech-runtime/models.json`; consult each upstream model's terms |
| Open-Meteo | Optional weather data from [Open-Meteo](https://open-meteo.com/); answers identify the source |
| Claude Agent SDK and its native runtime | Pinned in `source/agent-runtime/package-lock.json`; Anthropic commercial terms apply as described in the SDK's bundled README |
| Node.js | Bundled from the build machine's Node.js 22+ distribution; see the included `AgentRuntime/NODE_LICENSE` |
| Zod and MCP dependencies | Installed from the pinned lockfile; package license files are retained under `AgentRuntime/node_modules` |

This repository does not include model weights, user credentials, private recordings, or developer signing keys. No project-wide license has been selected yet; third-party licenses do not grant rights to unrelated project code.
