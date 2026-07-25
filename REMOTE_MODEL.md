# Remote Qwen Deployment

The Qwen3-VL inference server runs on one GPU of `lab_4090`. The local
Agent Gateway and GodotSpace remain on this PC. An SSH tunnel exposes the
remote loopback-only vLLM endpoint as `http://127.0.0.1:18000/v1`, so the
Godot protocol and tool implementations do not change.

## One-time deployment

Run inside WSL from the repository root:

```bash
bash scripts/deploy_remote_vllm.sh
```

Defaults are GPU 2, remote port 18000, and the local FP8 weights under
`models/Qwen3-VL-2B-Instruct-FP8`. The deployment host and local source can
be overridden with `REMOTE_HOST` and `LOCAL_MODEL_DIR`.
The large weight file is fetched from `hf-mirror` with resumable,
multi-connection downloading; the local copy supplies configuration files
and the expected final byte size. The default model revision is pinned to
`46485250d8854c0a9be4f1adbc67ca47e5bb6fa5`, matching the local cache.
The deployment pins `transformers==4.57.1`: vLLM 0.11 is not compatible with
the 5.x tokenizer API.

## Daily startup

```bash
ssh lab_4090 systemctl --user start qwen-vllm.service
bash scripts/start_remote_model_tunnel.sh
bash scripts/start_agent_gateway_remote_model_background.sh
```

Then start GodotSpace normally. Only the PC Godot Server connects to the
local Gateway at `ws://127.0.0.1:7861/ws/godot`.

## Verification and shutdown

```bash
curl http://127.0.0.1:18000/v1/models
python scripts/check_agent_gateway.py
python scripts/smoke_remote_model_tool_call.py
ssh lab_4090 systemctl --user status qwen-vllm.service

bash scripts/stop_agent_gateway_remote_model.sh
bash scripts/stop_remote_model_tunnel.sh
ssh lab_4090 systemctl --user stop qwen-vllm.service
```

Do not expose vLLM directly on `0.0.0.0`. If the SSH tunnel is down,
`/readyz` correctly reports the Gateway as not ready.
