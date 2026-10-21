---
name: deploy-local-agent
description: 在新电脑部署、迁移或恢复本仓库 GodotSpace Local Agent，包括本地 Qwen/vLLM、Gateway/harness、FunASR、轻量中文 TTS 和 Godot/PICO 联通验证。用户说“一键部署智能助手”“换机器部署 local agent”“迁移模型和语音服务”时使用；不是通用模型训练、云服务部署或主工程导出工具。
---

# Deploy Local Agent

目标是执行部署并交付可再次启动的本机环境，不是只给用户安装建议。正常路径一次请求完成；系统安装授权、重启、缺失定制引擎和真实头显操作可能需要用户介入。

## 执行顺序

1. **定位与盘点**：从本文件向上找到同时包含 `Model/agent_service` 和 `GodotSpace/project.godot` 的仓库根目录，阅读适用的 AGENTS.md。记录分支、commit、已有修改；遵守当前开发分支约定，不自动切分支、stash、合并或初始化嵌套 Git。
2. **理解链路**：完整读取 [architecture.md](references/architecture.md)，再完整读取 [deployment.md](references/deployment.md) 和 [runtime-profile.md](references/runtime-profile.md)。天上主机承载 Godot Server、Sky Client、Gateway 和模型（也可经 SSH 连接远端模型）；地面 Client 只需本机 ASR/TTS，命令通过 Godot Server 处理。执行 `scripts/deployment_check.py inventory --repo REPO`（系统 Python 即可）；Windows 还需检查当前用户的 WSL2 注册和 Windows 端口。
3. **宣布部署方案并执行**：说明选用的模型 ID/精度、上下文、ASR 设备、运行目录和下载范围。默认目标为 **RTX 5090 32GB**，模型 **Qwen/Qwen3-VL-8B-Instruct（原版 BF16）**，上下文 8192，vLLM 显存比例 0.75；不是 FP8。沿用用户后续明确指定的其他配置；显存不足时不静默降为 2B、量化或改远程。按 deployment.md 的 CUDA 12.8 配方建立隔离环境、下载权重、逐个启动服务；已有兼容且健康的服务直接复用。
4. **验证**：完整读取 [verification.md](references/verification.md)，先自动化单测、服务身份/就绪和真实推理，再 Godot→Gateway→模型→工具往返，最后引导硬件验收。服务检查返回成功不等于任务完成。
5. **交付**：按 runtime-profile.md 在忽略的 `Model/generated/local-agent-deploy/` 下保存本机 runtime.json、停止入口和部署报告。日常在 Godot 启动菜单选择算力后点击启动；Client 自动准备 ASR/TTS。必须验证重复启动复用、端口冲突报错和 Windows localhost 可达。报告记录版本、权重 revision/hash、设备、端口、PID 所有权、各层 PASS/FAIL/未验证、日志位置及恢复命令。只记录部署技术信息，不保存用户录音、真实对话或密钥。重启后恢复不重新下载模型。

## 关键约束与暂停点

- 默认 Windows + WSL2 NVIDIA CUDA 后端，Windows 定制 Godot 串流到 PICO。Linux 后端可按同样配方部署；不声称 macOS、无 CUDA 或普通 Godot 可无改动运行整套。
- 迁移完整 monorepo、知识/工作清单资源和 native extensions；不复制旧机器虚拟环境、缓存中的绝对路径、用户配置或密钥。
- 使用新隔离目录，不运行旧 `bootstrap_wsl.sh` 的 `--clear`；不要因端口占用杀进程。深度服务也默认用 8765，冲突时选择其他空闲 ASR 端口并同步 Godot 的 `LOCAL_ASR_ENDPOINT`。
- 不使用旧远程 4090 脚本、写死的盘符/GPU 编号或非官方下载镜像作为迁移默认。远程访问、联网受限下载和管理员操作使用平台授权流程；不要暴露无认证端口到局域网或公网。
- 缺 WSL/驱动时说明必要安装与重启，保存已完成阶段并暂停需要用户参与的部分；缺匹配的定制 Godot 时可以继续完成后端，不以任意下载的引擎替代。
- 不改 DeepSeek/Tencent 兼容功能；本地链路不需要它们的凭据。不要用 mock 结果或普通 HTTP 200 冒充真实模型/麦克风/PICO 验证。

## 辅助脚本

`scripts/deployment_check.py` 仅依赖标准库；不安装、不改配置、不停止服务：

- `inventory --repo REPO`：路径、版本、GPU、磁盘、端口、LFS pointer 盘点；只是盘点，不承诺部署就绪。
- `services --model-id ID`：检查四服务响应内容和模型名，任一失败退出非零。
- `smoke --model-id ID`：在服务检查后发起一次真实文本推理和 TTS 合成；不调用云服务，不触发 Godot 工具操作。
- 后两项默认检查 Qwen/Qwen3-VL-8B-Instruct；使用其他模型必须显式传 --model-id。可传 `--model-port`、`--gateway-port`、`--asr-port`、`--tts-port`。只访问 127.0.0.1。在 WSL 和 Windows 各检查一次，不能只验证 WSL 内部互通。
- 无 Python 时先用系统只读命令检查 WSL/GPU，再按部署参考安装运行时，不为盘点单独装一套 Windows Python。

在目标机器的 Codex 中可直接提出：
“使用 $deploy-local-agent 部署当前仓库的 Local Agent，完成可执行的自动验证，并列出尚需 PICO 真机确认的部分。”
