# 部署配方

本文件命令是供执行 skill 的 Codex 按探测结果执行的配方。负责展开路径、检查退出码、保存重启入口；不要把未展开的占位符交给用户逐条运行。

## 1. 确定目标与先决条件

- 从 skill 所在仓库定位 Repo；Windows 项目路径为 Repo/GodotSpace，后端为 Repo/Model。读取 git status/branch/HEAD，保留既有修改。
- Windows 用 `wsl.exe --list --verbose`；在实际用户权限下选择已有 WSL2 发行版，优先已有 Ubuntu-20.04。沙箱“无发行版/拒绝访问”先走工具授权，不能据此重装 WSL。
- 缺 WSL2/驱动，先解释安装和重启需求，通过授权执行系统安装；不要静默更换已有发行版或在 WSL 安装 Linux NVIDIA 内核驱动。可用 `wsl.exe --list --online` 确认可安装名称。
- 用 `wsl.exe -d DISTRO -- wslpath -u WINDOWS_MODEL_PATH` 转换路径，不假定 C/F 盘。所有路径作为独立参数引用；Windows 启动 WSL 后端，不用 python.exe 操作 Linux venv。
- Windows 和 WSL 分别检查 `nvidia-smi`、磁盘与端口。WSL 在 Windows 大型工作树上的 git status 可能超时；此时用 Windows Git 补查，不把超时当干净工作树。为环境和下载留足空间（建议先有 30GiB 以上可用；这不是 8B 的固定容量保证）。
- NVIDIA 8GB 机器可尝试仓库 2B/2048/0.60 基线，但空闲显存、其他进程和上下文均会影响成功；不是仅按显卡名称保证可运行。8B 必须明确具体普通/FP8 模型 ID 和可用显存。不满足用户指定模型时停止该阶段，不擅自降模型/量化/改远程。
- 确认 git-lfs 可用；完整 clone 后运行 `git lfs pull` 和 `git lfs fsck`。复制来的目录仍需检查 pointer。不要覆盖用户修改来“修复”资产。
- 匹配定制 Godot 可执行文件从用户的可信迁移包/现有安装定位；检查 `--version`。不能保证从公共 Godot 下载普通 4.4 就能满足项目定制 API。

## 2. 隔离环境安装

以下在 Linux/WSL 的 Model 目录执行。后续所有 Python 均使用完整 venv 路径。

准备 Python 3.12 与 uv：优先已有工具；缺少时可用系统包管理器或 uv 官方安装方式，先检查下载的安装脚本并使用授权流程。不要无检查 curl 管道执行。Python 3.12 可由 `uv python install 3.12` 安装。Ubuntu 缺 native build 依赖时再安装 build-essential、ca-certificates、git、curl、libgomp1、libsndfile1（系统安装需权限）。

```bash
# Codex 将这里的目录变量填成从当前仓库解析的绝对路径。
BACKEND="$PWD"
RUNTIME="$BACKEND/.cache/local-agent-deploy"
mkdir -p "$RUNTIME/envs" "$BACKEND/generated/local-agent-deploy" "$BACKEND/logs/local-agent-deploy"
```

三个环境为 `$RUNTIME/envs/model`（vLLM + Gateway）、`asr`、`tts`。目标不存在才执行：
`uv venv --python 3.12 --seed "$RUNTIME/envs/NAME"`。
**不要 --clear**。已存在且来源不明的环境先检查，不安装进去；选一个新的明确路径。对本 skill 上次创建的环境，按已保存部署记录检查 pip check/版本后复用，安装失败可续装该环境，不删目录重来。

```bash
uv pip install --python "$RUNTIME/envs/model/bin/python" "vllm==0.11.0" --torch-backend=cu126
uv pip install --python "$RUNTIME/envs/model/bin/python" \
  -r "$BACKEND/requirements-agent.txt" "transformers==4.57.1" \
  "qwen-vl-utils==0.0.14" "huggingface-hub<1" "requests>=2.31" "python-dateutil>=2.8"

# 默认给 ASR 使用 CPU，避免和 vLLM 争抢小显存；必须测真实识别时延。
# 用户要求 GPU ASR 时在它自己的环境选匹配 CUDA 的 torch，不污染 model 环境。
uv pip install --python "$RUNTIME/envs/asr/bin/python" torch --torch-backend=cpu
uv pip install --python "$RUNTIME/envs/asr/bin/python" \
  -r "$BACKEND/requirements-asr.txt" "funasr==1.4.13" "modelscope==1.39.1" \
  "numpy==1.26.4" soundfile requests

uv pip install --python "$RUNTIME/envs/tts/bin/python" -r "$BACKEND/requirements-tts.txt"
```

分别运行三环境 `python -m pip check`，导出 `pip freeze` 到忽略的部署报告目录。model 环境还检查 torch.cuda.is_available()、设备、torch/CUDA/vLLM/transformers 版本；不通过不进入模型启动。

这里复用了仓库验证过的 vLLM/transformers、FunASR 和 TTS 主版本，**不是所有传递依赖的跨平台锁文件**。ASR CPU 配方与旧电脑 CUDA 环境不同，必须通过后面的真实音频 smoke；若未来包源版本变化导致安装/导入失败，定位具体依赖、记录实际版本，不盲目升级整套 vLLM。

## 3. 权重下载和缓存

始终在新机器下载，或从用户提供的可信离线包校验后复制。不要提交权重。首次需要联网，不承诺尚无权重时离线部署。

- **Qwen**：model 环境使用 huggingface_hub 的 `HfApi().model_info(model_id).sha` 取得具体 revision，再 `snapshot_download(repo_id=model_id, revision=sha, local_dir=...)` 下载到 `Model/models/local-agent/模型专属目录`。Codex 用 apply_patch 写本地下载脚本，参数传入完整 ID，不拼 shell 字符串。记录 ID/revision、配置和权重文件 SHA256；确认 config/tokenizer/processor 和 safetensors 分片齐全。默认官方 Hugging Face，不继承旧 HF_ENDPOINT 镜像；网络受限需要镜像时先说明来源并取得选择。
- **FunASR/VAD**：asr 环境中以 `FUNASR_DEVICE=cpu`（或计划的 cuda）、`MODELSCOPE_CACHE=$BACKEND/models/funasr`，在 Model cwd 执行 `from asr_service.funasr_engine import FunAsrEngine; e=FunAsrEngine(); e.load(); assert e.loaded and e.vad_loaded and e.warmed_up`。它会下载 paraformer-zh-streaming 和 fsmn-vad 并预热。记录别名解析后的真实模型仓库、缓存目录/revision及权重 SHA256。随后将实际两个本地模型目录交给启动器的 --asr-model/--vad-model，避免启动依赖别名查询网络。不要把整个 cache 根目录误当模型目录。
- **TTS**：tts 环境运行 `python scripts/download_tts_model.py`。该脚本使用固定上游 URL/SHA256，只保留推理必需文件；模型目录为 `Model/models/tts/vits-icefall-zh-aishell3`。不要用 Windows 系统朗读替代它。离线包也必须含 tokens/lexicon/FST，只有 model.onnx 不够。

有完整缓存后验证一次无需下载的重启。模型下载与本机硬件运行均失败时不能写“部署完成”。

## 4. 逐服务启动

使用 skill 的 `scripts/launch_service.py`，它只在前台启动一个服务，固定 loopback，拒绝已占用端口，**不杀进程、不改系统服务**。它绕过旧 env.sh、硬编码路径和旧 ASR venv；不依赖 PATH 中的 uvicorn。

在 Linux/WSL 中，SKILL 指当前 skill 的绝对路径，MODEL_ID/MODEL_DIR 与前一步一致：

```bash
python3 "$SKILL/scripts/launch_service.py" vllm --repo "$REPO" \
  --env-dir "$RUNTIME/envs/model" --model-id "$MODEL_ID" --model-path "$MODEL_DIR" \
  --max-model-len 2048 --gpu-memory-utilization 0.60
python3 "$SKILL/scripts/launch_service.py" gateway --repo "$REPO" \
  --env-dir "$RUNTIME/envs/model" --model-id "$MODEL_ID"
python3 "$SKILL/scripts/launch_service.py" asr --repo "$REPO" \
  --env-dir "$RUNTIME/envs/asr" --asr-device cpu \
  --asr-model "$ASR_MODEL_DIR" --vad-model "$VAD_MODEL_DIR"
python3 "$SKILL/scripts/launch_service.py" tts --repo "$REPO" --env-dir "$RUNTIME/envs/tts"
```

上面每条占用一个前台进程，不能顺序粘贴到同一阻塞终端。Codex 应把已解析的启动命令保存到忽略的本机入口，分别后台启动并记录 PID/完整 argv/启动时间/日志。Windows 的后台辅助进程必须隐藏窗口；可用 WSL 内独立会话/nohup，或 Hidden 的 Start-Process 启动 wsl.exe，避免退出临时终端后服务被回收。不默认配置开机自启。

先启动 vLLM，轮询 /v1/models 和首次推理，再 Gateway，再 ASR/TTS；每个阶段有超时和日志，不能无限无反馈等待。模型冷启动可给 10 分钟预算，每次等待不超过 30 秒；下载单独报告进度。启动失败仅清理由本次部署创建且身份仍匹配的进程。

每次重跑先探测身份、端口、配置、健康；匹配者复用，不匹配者报告。默认端口为 8000/7861/8765/8767。使用自定义端口时：
- vLLM: --port；Gateway: --model-port（必须同步）。
- 其他服务: --port；检查脚本使用对应 --SERVICE-port。
- Gateway 改端口还要同步 Godot 的 arspace/local_agent/endpoint_url（它没有通用环境变量覆盖）。
- ASR 改端口同步启动 Godot 进程的 LOCAL_ASR_ENDPOINT。
- TTS 改端口同步 GODOTSPACE_TTS_ENDPOINT。

停止入口只允许终止记录中属于当前部署的进程；先比对 PID 的启动时间及 argv，PID 复用/外部服务一律不杀。不使用 pkill python、killall、按端口批量终止或关闭整个 WSL。用户退出 Codex 后后端应保持可用。

## 5. Godot/PICO 配置

Windows 新启动的 Godot 进程继承：

```powershell
$env:GODOT_ASR_PROVIDER = 'funasr'
$env:LOCAL_ASR_ENDPOINT = 'ws://127.0.0.1:8765/ws/asr'
$env:GODOTSPACE_TTS_ENDPOINT = 'http://127.0.0.1:8767/v1/speech'
```

按实际选定端口替换；不是注册系统永久环境变量，也不会改变已运行的 Godot 进程。把这些变量保存到本机启动入口。Gateway 默认读取项目设置 `ws://127.0.0.1:7861/ws/godot`。默认无需改 tracked project.godot；确需改端口时只改明确配置并记录 diff，不改其他功能。

先使用匹配的 Windows Godot 对 Repo/GodotSpace 做 headless import/自检，再启动实际 Server 和目标 Client。参数及角色见根 AGENTS.md。只有目标 XR Client 使用 --xr-mode on/--xr-client，Server/另一个桌面 Client 不抢 OpenXR。PICO 串流连接后选择它的麦克风与扬声器输出；必须听到目标端播报。

## 6. 交付本机入口与报告

用 apply_patch 创建不跟踪的 `Model/generated/local-agent-deploy/` 下本机启动、检查、停止入口，记录发行版、转换后的路径、三个 venv、模型 ID/path/revision、服务端口和环境变量。入口要引用本 skill 的 launcher，不复制业务实现。启动入口重复执行应复用匹配健康进程；停止入口验证身份。

把实际运行的命令、版本、模型校验、PASS/FAIL/未验证写入 report.md；敏感配置不写入。git status 确认仅用户授权的 tracked 配置发生变化。迁移操作不自动 commit/push，也不把本机入口加入 Git。
