# Remote Qwen3-VL-8B Deployment

The Qwen3-VL inference server runs on one GPU of `lab_4090`. The local
Agent Gateway and GodotSpace remain on this PC. An SSH tunnel exposes the
remote loopback-only vLLM endpoint as `http://127.0.0.1:18400/v1`, so the
Godot protocol and tool implementations do not change.

## One-time deployment

The production checkpoint must exist at
`/home/admin/local-agent-qwen/models/Qwen3-VL-8B-Instruct-FP8`.
This checkout does not automate the initial 8B weight upload.
`scripts/deploy_remote_vllm.sh` stages the older 2B checkpoint and must not
be used to replace the production 8B weights.

The production runtime defaults are GPU 2, remote port 18400, 8,192 tokens,
and the remote 8B FP8 checkpoint. Runtime settings can be overridden with
`REMOTE_GPU`, `REMOTE_VLLM_PORT`, and `REMOTE_MODEL_DIR`.
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
curl http://127.0.0.1:18400/v1/models
python scripts/check_agent_gateway.py
python scripts/smoke_remote_model_tool_call.py
ssh lab_4090 systemctl --user status qwen-vllm.service

bash scripts/stop_agent_gateway_remote_model.sh
bash scripts/stop_remote_model_tunnel.sh
ssh lab_4090 systemctl --user stop qwen-vllm.service
```

Do not expose vLLM directly on `0.0.0.0`. If the SSH tunnel is down,
`/readyz` correctly reports the Gateway as not ready.
