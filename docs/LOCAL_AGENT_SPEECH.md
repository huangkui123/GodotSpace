# 轻量离线语音播报

Local Agent 的最终回复、操作结果和二次确认问题可以自动播报。
TTS 在电脑 CPU 上生成 PCM，由发起请求的 Godot Client 播放到当前音频输出设备。
不依赖 Windows 系统语音、中文语言包、云 API 或 GPU。没有改动或移除 DeepSeek。

## 模型和迁移

- 推理引擎：sherpa-onnx 1.13.8，CPU 默认 2 个线程。
- 模型：官方 `vits-icefall-zh-aishell3`，`model.onnx` 为 30,482,262 字节，中文、8 kHz、16-bit mono 输出。
- 音质以清晰提示为目标，不提供自然情感或语音克隆。英文和特殊术语需试听；数字由模型配套 FST 处理。
- 安装包 SHA-256 固定在下载脚本中；正常启动不会访问互联网。
- 服务、Godot 接入、测试、依赖版本和安装脚本全部随本仓库维护。
- 权重保存在 `Model/models/tts/vits-icefall-zh-aishell3`，依赖在 `Model/.venv-tts`，均不进 Git。
- 换电脑：重新创建虚拟环境；复制上述模型目录，或运行下载脚本。不要跨操作系统复制虚拟环境。
- 安装脚本只提取实际使用的模型、词典、规则；不展开包内约 180 MB 的未使用 `rule.far`。
- 许可证来源：[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)、[icefall](https://github.com/k2-fsa/icefall)、[AISHELL-3 数据集](https://www.openslr.org/93/)。它们标注 Apache-2.0；下载的模型压缩包没有单独 LICENSE，正式再分发权重前应补核上游模型授权，勿把数据集许可证直接当作独立模型授权。

官方模型说明：https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html#aishell3-chinese-multi-speaker-174-speakers

## 安装和启动

当前 Windows + WSL 运行方式，在仓库根目录执行：

```powershell
.\Model\scripts\local_tts_windows.ps1 install
.\Model\scripts\local_tts_windows.ps1 start
.\Model\scripts\local_tts_windows.ps1 status
.\Model\scripts\local_tts_windows.ps1 test
# 不再需要时：
.\Model\scripts\local_tts_windows.ps1 stop
```

WSL/Linux，在 `Model` 目录：

```bash
bash scripts/bootstrap_local_tts.sh
.venv-tts/bin/python scripts/local_tts.py start
.venv-tts/bin/python scripts/local_tts.py status
.venv-tts/bin/python scripts/local_tts.py stop
```

首次安装需能访问 PyPI、GitHub，且已有 Python 3.12。独立迁移机器可先用 Python 3.12 创建
`.venv-tts` 并安装 `requirements-tts.txt`，再运行 `scripts/download_tts_model.py`。
服务代码本身无 WSL 依赖；原生 Windows 使用相应 Python 虚拟环境亦可，尚未进行该部署路径实测。

也可前台执行 `bash scripts/start_local_tts.sh`，用 Ctrl+C 停止。
服务默认且仅绑定 `127.0.0.1:8767`。后台日志位于 `Model/logs/local_tts.log`，不记录请求正文。
状态接口不代替鉴权；不要直接把该服务暴露到公网/LAN。

## Godot 设置

- `arspace/assistant_speech/enabled`：总开关，默认 true。
- `arspace/assistant_speech/endpoint_url`：默认 `http://127.0.0.1:8767/v1/speech`。
- `GODOTSPACE_TTS_ENDPOINT`：运行时覆盖 URL。
- `arspace/assistant_speech/volume_db`：播报音量，默认 -3 dB。
- `LOCAL_TTS_THREADS`：CPU 线程数 1–4；默认 2。
- `LOCAL_TTS_SPEAKER`：模型说话人编号，默认 66。
- `LOCAL_TTS_MODEL_DIR`：离线模型目录覆盖。
- `LOCAL_TTS_PORT`：服务端口覆盖，需同步 Godot URL。

Pico 仍使用原来的串流音频设备设置。播报走 Godot 的 AudioServer，不修改 Windows 全局默认设备。
单台电脑运行 Server、ground、sky 时，共用一个 TTS 服务；只有目标进程播放。
如果 Client 迁移到另一台电脑，该电脑的 localhost 指向自己，需要部署同样的轻量服务，
或显式配置经过安全隧道保护的地址；不能误以为仍然指向 Server。

## 交互及边界

- 只播报最终回复，不读模型思考、工具中间事件或同步的历史记录。
- 按句/最多 160 字分段合成并顺序播放；这是分句播报，不是模型逐 token 流式合成。
- 最多接受 4000 字，单次 HTTP 最多 500 字；超长回复保留文字，不无限排队。
- 二次确认时显示“正在播报”，不消耗回答读秒；播报结束/失败后开启完整的 10 秒听写。
- “停止播报并听写”复用唤醒按钮，保留待确认上下文；旧播报回调不会覆盖新听写。
- 播报及短暂尾音保护期间暂停该用户的 ASR 输入，不关闭全局麦克风，不影响其他用户转写。
  这是半双工：期间普通讲话也不转写，暂不支持语音插话；可用按钮打断。
- 当前语音通话的麦克风音频仍独立运行；扬声器声音被麦克风物理收回仍可能传给其他人。
  这不是 AEC，不保证消除会议通话回声。
- 服务不可用时保留文字和工具执行结果，恢复确认听写；可查 AssistantSpeech.last_error。
- 唤醒时现有文字反馈保留；此次不额外播放“我在”，避免截断紧跟唤醒词的指令。
- 当前接入 Local Agent 路由的回复；既有工作清单“朗读步骤”仍为原系统 TTS，不自动改用本服务。
- headless 默认不播报；真实音频烟雾测试显式启用。头显音量、实际路由和物理回声仍需 Pico 真机验证。

## 验证

```bash
.venv-tts/bin/python -m unittest discover -s tts_service/tests -v
.venv-tts/bin/python scripts/smoke_local_tts.py
```

Godot 自检脚本（使用项目指定引擎，`--headless --path GodotSpace --script res://...`）：
- `Assets/ARSpace/Scripts/AI/LocalAgent/assistant_speech_self_test.gd`：隔离、去重、确认、取消、无效音频恢复。
- 同一脚本分别带 `-- --speech-server --local-agent-testmode` 和两个
  `-- --speech-client --local-agent-testmode`：真实 ENet、模拟合成的双 Client 隔离。
- `Assets/ARSpace/Scripts/AI/LocalAgent/assistant_speech_live_smoke.gd`：真实 TTS HTTP→Godot PCM 播放→确认读秒恢复，
  不需要对话模型，不等于 Pico 真机出声验证。

Pico 手工验收：打开三端并选好 Pico 输出；询问“打开工作手册”，确认只在发起端听到确认问题；
读完再说“是”；重新测试播报中点击按钮、TTS 关闭、两人分别询问、头显重连。
核对结果播报一次，正确的客户端操作，读秒和上下文正常，恢复后普通语音继续逐条转写。

## 本次验证记录（2026-09-12）

- WSL 独立环境安装、模型校验、真实 CPU 服务启动通过。
- 五条短句合成耗时 64–104 ms，中位数 79 ms；这是服务合成耗时，不含实际 Pico 串流延迟。
- 单元测试 6 项、原助手离线测试 7 项、路由自检、播报自检通过。
- 真实 ENet Server + 双 Client 定向/去重/回执测试通过；合成为模拟，用于隔离协议问题。
- 真实 TTS HTTP -> Godot PCM 播放 -> 确认听写恢复通过；使用 headless 音频，不代表真机已验证。
- Godot 导入退出码 0；仍有工程既有的 progress dialog、LICENSE/credits UID 缓存重建及退出 ObjectDB 提示。
- 尚未验证 Pico 实际扬声器出声、物理回声和真实多用户边说边播的效果。
