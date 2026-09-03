# Local FunASR service

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
