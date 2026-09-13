# 本地播报（CPU / CUDA）

默认使用 sherpa-onnx 1.13.8 + Kokoro v1.1 中文 INT8，24kHz 单声道 PCM16，无 torch/CUDA/云 API。模型从官方发布下载并校验 SHA256，不提交权重。

## 可选本机 NVIDIA GPU

GPU 使用同版 Kokoro 的 FP32 ONNX 权重，不把 CPU 动态 INT8 原样当作 CUDA 加速。CPU 环境和权重保持独立，迁移后按实际显存选择：

```bash
bash scripts/bootstrap_local_tts_gpu.sh
.venv-tts-gpu/bin/python scripts/benchmark_local_tts.py --device cuda
# 测过真实合成及 Godot 显存余量后，停止当前受管理的 TTS，再切换。
.venv-tts/bin/python scripts/local_tts.py stop
LOCAL_TTS_DEVICE=cuda .venv-tts-gpu/bin/python scripts/local_tts.py start
```

GPU 安装限 Linux x86_64 / Python 3.12，依赖独立 pip CUDA 12 / cuDNN 9，无 torch。Ubuntu 20.04 的 glibc 2.31 无法加载官方 CUDA wheel；安装器会在忽略的 `.cache/tts-build` 中从固定官方 commit 构建 sherpa 1.13.8，需要 C/C++ 编译器和额外下载/编译时间，不升级系统库。新系统可使用官方预编译 wheel。GPU 依赖/显卡不可用时明确报错，不悄悄把 CPU 宣称为 CUDA。启动后核对 `/health` 的 `device=cuda`、`model=kokoro-multi-lang-v1_1`，并用实际合成速度及 NVIDIA 进程显存确认。

CPU 回退：用管理入口 stop，随后 `LOCAL_TTS_DEVICE=cpu .venv-tts/bin/python scripts/local_tts.py start`。不需要重新下载 CPU 权重。将选定环境和 `LOCAL_TTS_DEVICE` 写入本机启动入口；它不是系统永久变量。前台入口 `LOCAL_TTS_DEVICE=cuda bash scripts/start_local_tts.sh` 也会选择 GPU 环境。

Windows PowerShell 可运行 `./scripts/local_tts.ps1 start -Device cuda`，用 `stop`/`status` 管理同一服务；默认发行版 Ubuntu-20.04，可传 `-Distro`。CPU 回退的 start 显式 `-Device cpu`。入口从仓库位置解析路径，不依赖旧机器盘符。

## CPU 便携方案

在 WSL 的 Model 目录，使用已有隔离环境：

```bash
.venv-tts/bin/python scripts/download_tts_model.py --model kokoro
.venv-tts/bin/python scripts/local_tts.py status
# 替换前确认这是本仓库管理的 TTS；不停止 Gateway/ASR/对话模型。
.venv-tts/bin/python scripts/local_tts.py stop
.venv-tts/bin/python scripts/local_tts.py start
```

首次没有环境时运行 `bash scripts/bootstrap_local_tts.sh`。默认 `LOCAL_TTS_MODEL=kokoro`、`LOCAL_TTS_SPEAKER=17`（用户试听选定的中文女声，CPU/CUDA 相同）、`LOCAL_TTS_THREADS=2`、`LOCAL_TTS_SPEED=1.0`。变量设置在启动进程的环境中，不自动写入电脑永久环境变量。显式 `LOCAL_TTS_SPEAKER` 仍优先于默认值。`LOCAL_TTS_MODEL_DIR` 可覆盖模型路径；旧入口显式传 VITS 目录时仍使用 VITS，应先检查启动入口及 `/health` 的 model/speaker。语速允许 0.7–1.3；不同模型的 speaker ID 不通用。

旧模型保持可用：下载器加 `--model vits`，启动时 `LOCAL_TTS_MODEL=vits`，并取消不匹配的模型目录及 speaker 覆盖。默认 VITS sid=66，8kHz。不会在 Kokoro 出错时无提示切回旧模型。

Godot 按完整句子分段，长句优先在逗号/分句处分段，64 字附近没有边界时兜底切分并尽量保留数字/拉丁单位。播放当前句时只预取下一句，最大缓存一段；取消/断线清空缓存。无标点中文仍不能保证语义切分正确。已有 Godot 进程需重启才加载客户端代码；后台 TTS 切换可在原 endpoint 生效。

后端仅做格式清理、单位读法转换；不使用模型改写数值或指导含义。合成结果保存在最多 32 条/8MiB 的进程内 LRU 中，不将用户文本/音频写盘。首次合成与缓存命中延迟必须分开报告。预取能重叠播放与计算，但 CPU 合成慢于音频时长时仍会等待。

```bash
.venv-tts/bin/python -m unittest discover -s tts_service/tests -v
.venv-tts/bin/python scripts/benchmark_local_tts.py --speakers 17 18 --threads 2
.venv-tts/bin/python scripts/smoke_local_tts.py
```

benchmark 仅生成固定公开测试语句，在 generated/tts_audition 中输出 WAV/JSON；不会自动播放。音色自然程度、技术数值读法和 PICO 实际出声需要真人试听，不以健康检查或 HTTP 200 代替。
