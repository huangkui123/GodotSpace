# Local Agent 部署与功能简介

GodotSpace 的 Local Agent 由 Godot、Agent Gateway、本地 Qwen 模型和本地 FunASR 组成，所有组件都在本机运行。

## 1. 服务结构

```text
Godot Server ── WebSocket :7861 ── Agent Gateway ── HTTP :8000 ── Qwen / vLLM
      │
      └──────── WebSocket :8765 ── FunASR
```

| 服务 | 地址 | 用途 |
| --- | --- | --- |
| Qwen / vLLM | `http://127.0.0.1:8000` | 本地模型推理 |
| Agent Gateway | `ws://127.0.0.1:7861/ws/godot` | 模型与 Godot 工具调用之间的网关 |
| FunASR | `ws://127.0.0.1:8765/ws/asr` | 本地实时语音识别 |

这些服务默认只监听本机地址。

## 2. 首次安装

推荐环境为 WSL2 Ubuntu 20.04、Python 3.12 和支持 CUDA 的 NVIDIA 显卡。在 WSL 中执行：

```bash
cd /mnt/f/GodotSpace/Model
bash scripts/bootstrap_wsl.sh
source .venv/bin/activate
.venv/bin/pip install -r requirements-asr.txt
```

首次启动时可能需要下载模型文件，请确保磁盘空间和网络可用。模型权重、日志和运行产物不会提交到 Git。

## 3. 启动本地服务

打开三个 WSL 终端，并在 `GodotSpace/Model` 目录中分别启动模型、语音识别和 Gateway。

终端 1：

```bash
source .venv/bin/activate
bash scripts/start_vllm.sh
```

终端 2：

```bash
source .venv/bin/activate
bash scripts/start_local_asr.sh
```

终端 3：

```bash
source .venv/bin/activate
bash scripts/start_agent_gateway.sh
```

`start_vllm.sh` 默认启动仓库配置的本地 Qwen 模型；如需更换模型，请同步调整模型服务与 Gateway 使用的 `MODEL_NAME`。

## 4. 启动 Godot

确认仓库位于开发分支：

```powershell
cd F:\GodotSpace
git switch feature/local-agent-voice-tools
```

随后用 Godot 打开 `F:\GodotSpace\GodotSpace\project.godot`，先启动 Server，再启动需要使用智能助手的 Client。

主要项目设置如下：

- `arspace/local_agent/enabled`：启用智能助手
- `arspace/local_agent/endpoint_url`：`ws://127.0.0.1:7861/ws/godot`

FunASR 默认使用 `ws://127.0.0.1:8765/ws/asr`，通常无需额外配置。

## 5. 检查服务

```bash
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate
curl http://127.0.0.1:8000/v1/models
python scripts/check_local_asr.py
python scripts/check_agent_gateway.py
```

三项检查通过后，Godot Server 才能完整使用语音助手。

## 6. 支持的功能

- 通过“智能助手”或界面按钮进入指令输入状态。
- 本地实时语音转写，并将普通听写按顺序显示在记录中。
- 显示唤醒反馈、独立指令文本框和剩余时间条。
- 保留确认上下文，例如在“是否想打开工作清单”后回答“是”。
- 将一次指令及其二次确认合并为同一条问答记录。
- 打开、关闭或翻页工作清单、相册等 Godot 界面。
- 对近似名称给出“你是不是想说……”的候选并等待确认。
- 读取当前页面的结构化内容，回答页面相关问题。
- 由 Server 执行工具，并把结果同步到正确的 Client。

## 7. 停止服务

前台运行时可以在各终端按 `Ctrl+C`。通过后台脚本启动时，可以执行：

```bash
cd /mnt/f/GodotSpace/Model
bash scripts/stop_agent_gateway.sh
bash scripts/stop_local_asr.sh
bash scripts/stop_vllm.sh
```

更多参数和测试命令可参考 `Model/README.md`、`Model/LOCAL_ASR.md` 和 `Model/agent_service/README.md`。
