# Local Agent 部署与功能简介

本文说明如何在 GodotSpace monorepo 中启动本地智能助手。相关服务代码位于
`Model/`，Godot 工程位于 `GodotSpace/`。以下命令以 Windows 仓库路径
`F:\GodotSpace`、WSL 路径 `/mnt/f/GodotSpace` 为例。

## 1. 组件与端口

```text
Godot Server ── WebSocket :7861 ── Agent Gateway ── OpenAI API ── Qwen
      │
      └──────── WebSocket :8765 ── FunASR
```

| 组件 | 默认地址 | 作用 |
| --- | --- | --- |
| Agent Gateway | `ws://127.0.0.1:7861/ws/godot` | 接收语音指令、调用模型并安全执行 Godot 工具 |
| Gateway 健康检查 | `http://127.0.0.1:7861/readyz` | 检查模型、Gateway 和 Godot 连接状态 |
| 本地 FunASR | `ws://127.0.0.1:8765/ws/asr` | 将 16 kHz 单声道 PCM16 语音实时转成文字 |
| 本地 vLLM | `http://127.0.0.1:8000/v1` | 可选的本机 Qwen 推理服务，默认启动 2B 模型 |
| 远程模型隧道 | `http://127.0.0.1:18400/v1` | 推荐的远程 Qwen3-VL-8B-FP8 推理入口 |

服务默认只监听 `127.0.0.1`。不要在没有认证和访问控制的情况下将这些端口暴露到公网。

## 2. 首次安装

运行环境为 WSL2 `Ubuntu-20.04`、Python 3.12 和 CUDA。进入服务目录：

```bash
cd /mnt/f/GodotSpace/Model
bash scripts/bootstrap_wsl.sh
source .venv/bin/activate
.venv/bin/pip install -r requirements-asr.txt
```

`bootstrap_wsl.sh` 会重新创建 `.venv`，安装 vLLM、Qwen-Agent、FastAPI 等依赖。
FunASR 模型会在首次启动或首次连接时下载，因此第一次启动会比之后更慢。

## 3. 推荐部署：远程 8B 模型

该方式让远程 RTX 4090 运行 Qwen3-VL-8B-FP8，本机只运行 SSH 隧道、Gateway、
FunASR 和 Godot。远程机器需要已经配置 SSH 别名 `lab_4090`、用户服务
`qwen-vllm.service`，并具有对应的 8B 权重。

在 WSL 中执行：

```bash
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate

ssh lab_4090 systemctl --user start qwen-vllm.service
bash scripts/start_remote_model_tunnel.sh
bash scripts/start_agent_gateway_remote_model_background.sh
bash scripts/start_local_asr_background.sh
```

这套配置默认使用：

- 模型：`Qwen/Qwen3-VL-8B-Instruct-FP8`
- 模型入口：`http://127.0.0.1:18400/v1`
- Gateway：`127.0.0.1:7861`
- FunASR：`127.0.0.1:8765`

## 4. 备选部署：本机 2B 模型

如果不使用远程 GPU，可以在 WSL 的两个终端中运行：

```bash
# 终端 1
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate
bash scripts/start_vllm.sh
```

```bash
# 终端 2
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate
bash scripts/start_local_asr_background.sh
bash scripts/start_agent_gateway.sh
```

本机脚本默认使用 `Qwen/Qwen3-VL-2B-Instruct` 和端口 `8000`。2B 占用资源较少，
但复杂口语指令和歧义处理能力通常弱于推荐的 8B 模型。

## 5. 启动 GodotSpace

确认当前 Git 分支为：

```text
feature/local-agent-voice-tools
```

工程已经包含所需配置，无需手动修改 endpoint：

```ini
arspace/local_agent/enabled=true
arspace/local_agent/endpoint_url="ws://127.0.0.1:7861/ws/godot"
```

在 PowerShell 中打开工程：

```powershell
& 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe' `
  --editor --path 'F:\GodotSpace\GodotSpace'
```

正常启动 PC Server 和 Client。只有被选中的 Godot Server 会连接 Gateway；工具调用会
根据发言人的 `speaker_peer_id` 定向到对应 Client，避免两个 Client 互相串操作。

## 6. 验证服务状态

```bash
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate

curl http://127.0.0.1:18400/v1/models   # 远程 8B 部署
# curl http://127.0.0.1:8000/v1/models  # 本机 2B 部署
python scripts/check_agent_gateway.py
python scripts/check_local_asr.py
```

Gateway 正常时，`/readyz` 应显示 `status: ready` 和正确的模型名称。Godot Server 尚未
启动时，`godot_connected: false` 是正常现象；Server 连接后应变为 `true`。

离线回归测试：

```bash
python -m unittest discover -s agent_service/tests -v
python -m unittest discover -s asr_service/tests -v
bash scripts/test_assistant_command_router.sh
bash scripts/test_llm_assistant_voice_panel.sh
```

## 7. 当前支持的功能

### 自然语音交互

- 说“智能助手”或点击“唤醒智能助手”按钮进入指令输入状态。
- 唤醒后显示“我在，请说”、独立的指令文本框和可视化倒计时条。
- 首句话最长等待 10 秒；分段语音可以继续拼接，最终转写后会快速提交。
- 普通听写与助手问答按时间顺序显示，不会用后一句覆盖前一句。

### 工具操作

- 打开、关闭相册，读取页码，上一页、下一页或跳转到指定页。
- 打开、关闭工作清单，读取当前步骤，上一页、下一步或跳转到指定步骤。
- 重新播放当前工作步骤动画。
- 查询当前任务页面中的结构化知识，例如当前步骤所需的力矩或操作要求。

### 歧义处理和连续确认

- 对“工作手册”这类非标准名称，模型可以结合当前可用 UI 给出最接近的建议，
  例如“你是否想打开工作清单？”。
- 用户下一次只回答“是”或“不是”即可继续，确认上下文按发言人隔离。
- 点击“重新听写”不会丢失正在等待的确认。
- 建议、确认和最终结果在历史记录中合并为一次完整交互。

### 安全与可靠性

- 模型只能选择固定工具，不能提交任意 Godot `NodePath`、方法名或脚本。
- Gateway 会校验工具白名单、参数、当前 UI 状态和动作语义，再决定是否执行。
- `unclear` 表示证据不足；`contradicted` 只用于用户语义明确反对该动作的情况。
- 知识回答由本地证据 harness 约束，模型不能凭空增加力矩、温度或安全指令。
- 请求、工具结果和历史记录按 session、conversation 和 speaker 隔离，并包含超时、
  去重、断线和取消处理。

### 本地语音识别

- FunASR 使用 `paraformer-zh-streaming` 和 `fsmn-vad` 输出 partial/final 转写。
- 支持热词“智能助手”、静音端点检测、尾音缓冲和 stalled partial 自动完成。
- 如需回退腾讯 ASR，可以在 Godot 的 `VoiceChat` 配置中将 provider 改为 `tencent`，
  并通过环境变量提供腾讯凭据。

## 8. 停止服务

远程 8B 部署：

```bash
cd /mnt/f/GodotSpace/Model
bash scripts/stop_agent_gateway_remote_model.sh
bash scripts/stop_local_asr.sh
bash scripts/stop_remote_model_tunnel.sh
ssh lab_4090 systemctl --user stop qwen-vllm.service
```

本机 2B 部署：

```bash
bash scripts/stop_agent_gateway.sh
bash scripts/stop_local_asr.sh
bash scripts/stop_vllm.sh
```

更详细的模型、ASR 和协议说明见 `Model/REMOTE_MODEL.md`、`Model/LOCAL_ASR.md`、
`Model/agent_service/README.md` 和
`GodotSpace/Assets/ARSpace/Scripts/AI/LocalAgent/README.md`。
