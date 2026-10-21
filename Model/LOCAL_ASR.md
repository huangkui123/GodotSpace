# Local FunASR service

Godot's "唤醒智能助手" button now waits for the local ASR service before
opening recognition. On Windows it uses the shared runtime controller's `asr`
role, independently of the model startup checkbox. Existing healthy services
are reused; a stopped WSL service is started again. The button shows preparation
or startup errors instead of opening a WebSocket while the model is still loading.

The controller reads `generated/local-agent-deploy/runtime.json`. An existing
installation that only needs ASR can instead use the ignored
`generated/local-agent-deploy/asr-runtime.json`, containing `wsl_distro` and an
`asr` object with `env_dir`, `port`, `asr_device`, `asr_model`, and `vad_model`.
These paths must refer to the current machine's installed Linux environment and
downloaded model files. This ASR-only configuration does not start Qwen, Gateway,
or TTS. A custom external `LOCAL_ASR_ENDPOINT` remains externally managed.

The Godot Server can use this service instead of sending microphone audio to
Tencent Cloud. The service accepts 16 kHz mono PCM16 over WebSocket, runs the
FunASR `paraformer-zh-streaming` model, uses streaming `fsmn-vad` for speech
endpoints, and emits partial/final transcripts.

## Install and run in WSL2

```bash
.venv/bin/pip install -r requirements-asr.txt
bash scripts/start_local_asr.sh
```

The first connection downloads and loads the model. Check the process with:

```bash
.venv/bin/python scripts/check_local_asr.py
```

From Windows PowerShell, the service can be launched in the background and
stopped with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/start_local_asr_windows.ps1
powershell -ExecutionPolicy Bypass -File scripts/stop_local_asr_windows.ps1
```

Startup output is written to `logs/local_asr.out` and `logs/local_asr.err`.

Stream a representative 16 kHz WAV through the production WebSocket protocol:

```bash
.venv/bin/python scripts/smoke_local_asr.py /path/to/sample.wav
```

Verify that streaming FSMN-VAD ends the utterance without an explicit finish:

```bash
.venv/bin/python scripts/smoke_local_asr.py /path/to/sample.wav --auto-vad
```

With the service running, validate the actual Godot WebSocket adapter against
the loaded model:

```bash
bash scripts/test_local_funasr_godot.sh
```

Defaults:

- WebSocket: `ws://127.0.0.1:8765/ws/asr`
- Health: `http://127.0.0.1:8765/health`
- Model: `paraformer-zh-streaming`
- Endpoint model: `fsmn-vad`
- Device: `cuda`
- Audio upload/WebSocket packet: 100 ms
- End-of-speech silence: 600 ms
- Model streaming chunk: 600 ms (`chunk_size=[0, 10, 5]`)
- Stalled partial finalization: 1800 ms

The model runs one silent CUDA warmup during service startup so the first real
utterance does not pay the initial inference penalty. Set `FUNASR_WARMUP=0` to
disable this behavior.

Override these with `LOCAL_ASR_HOST`, `LOCAL_ASR_PORT`, `FUNASR_MODEL`,
`FUNASR_VAD_MODEL`, `FUNASR_DEVICE`, and `FUNASR_SPEECH_THRESHOLD`. The service
binds to localhost by default and must not be exposed without authentication.

The protocol starts with a JSON object:

```json
{"type":"start","sample_rate":16000,"format":"pcm_s16le","need_vad":true}
```

Audio packets are binary PCM. Send `{"type":"finish"}` to flush dictation.
The server responds with `ready`, `transcript`, `finished`, or `error` objects.

## 助手后端未连接

ASR 就绪只表示语音可以转成文字。执行“打开相册”等指令还需要模型、Gateway 和 Godot WebSocket 握手。

首次部署在本机 `generated/local-agent-deploy/runtime.json` 配置实际使用的算力模式、Gateway 环境和语音环境。该文件属于本机配置，不提交私有地址或密钥。

协作启动台默认启用“自动准备智能助手”：打开启动台即在后台检查并启动所选拓扑需要的服务，无需先点击“开始协作”。本机协作准备模型连接、Gateway、ASR 和 TTS；加入其他电脑只准备本机 ASR/TTS。算力沿用保存的选择，未保存且只有远端配置时自动选远端；已明确选择的算力不会被静默切换。用户主动关闭自动准备的选择仍会保存。

应用运行期间每 30 秒检查一次本机负责的服务，复用健康进程、重新启动已停止的服务，失败后自动重试并显示状态。无需重开 Godot 或手动运行终端命令；服务被其他配置占用时不会强行终止进程。更新前保存的 `assistant=false` 仍表示关闭；本次已按用户要求将当前机器的偏好改为开启。

协作模式下只有 Server 连接 Gateway。若以不启动助手的方式进入协作，后续显式助手指令会由 Server 检查并启动后端，等待 WebSocket 握手后再提交；启动期间取消、断线或超时的请求不会补发。缺配置、SSH 失败和握手失败会显示具体错误。已运行的 Godot 必须重新启动才能加载这项修复。

收窄的真实相册验证入口是 `res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_album_live_smoke.gd`，需要参数 `--local-agent-testmode --local-agent-album-smoke`。它只发送固定测试指令、通用 UI 状态和布尔结果，不发送相册内容或工作清单知识；在独立 Godot 进程中验证恢复连接和实际相册工具。
