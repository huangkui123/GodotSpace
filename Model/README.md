# GodotSpace Local Agent and ASR Services

This directory contains the local Qwen model gateway, evidence-gated knowledge
and tool-call harnesses, benchmarks, and the FunASR streaming service used by
GodotSpace. It is maintained as the `Model/` subtree of the GodotSpace
monorepo.

## Current target

- Host OS: Windows 10
- GPU: NVIDIA RTX 4060 8GB
- Runtime: WSL2 Ubuntu + vLLM. Ubuntu 20.04 is OK if the environment uses
  Python 3.10 or newer; this project creates a Python 3.12 environment with
  `uv`.
- Model: `Qwen/Qwen3-VL-2B-Instruct`
- Agent layer: Qwen-Agent `FnCallAgent`

vLLM is Linux-first, so this demo is intended to run inside WSL2 rather than
native Windows.

## Layout

- `scripts/bootstrap_wsl.sh`: installs Python build/runtime dependencies and
  creates a local virtual environment.
- `scripts/start_vllm.sh`: starts the Qwen3-VL-2B vLLM server.
- `scripts/check_vllm.py`: checks the OpenAI-compatible vLLM endpoint.
- `examples/qwen3vl_tool_call_demo.py`: Qwen-Agent tool-call demo using a local
  generated image and two custom tools.
- `web_demo/app.py`: a FastAPI web UI with the fixed inventory-label demo plus
  a custom image/prompt testbench for direct vision QA or Qwen-Agent tool calls.
- `agent_service/`: the local Qwen-Agent gateway for GodotSpace, including the
  versioned websocket protocol and the first `open_album` Godot RPC tool.
- `scripts/start_web_demo.sh`: starts the web UI from WSL.
- `scripts/start_web_demo_windows.ps1`: starts the web UI from PowerShell.
- `scripts/start_agent_gateway.sh`: starts the GodotSpace Agent Gateway on port
  `7861` after vLLM is available.

## Run

From WSL, run these commands inside this directory. In the current monorepo
checkout the path is `/mnt/f/GodotSpace/Model`.

```bash
bash scripts/bootstrap_wsl.sh
source .venv/bin/activate
source scripts/env.sh
bash scripts/download_model.sh
bash scripts/start_vllm.sh
```

Or start it in the background:

```bash
bash scripts/start_vllm_background.sh
tail -f logs/vllm.log
```

From PowerShell, use the Windows wrapper. This is the recommended way when
starting from outside an already-open WSL shell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_vllm_windows.ps1
Get-Content .\logs\vllm.out -Tail 80
```

Stop it from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_vllm_windows.ps1
```

If your distro is Ubuntu 20.04, that is fine. The default Python 3.8 from
Ubuntu 20.04 is too old for vLLM, so `bootstrap_wsl.sh` installs `uv` and uses
managed Python 3.12 instead of the system Python.

In another WSL terminal:

```bash
source .venv/bin/activate
source scripts/env.sh
python scripts/check_vllm.py
python examples/qwen3vl_tool_call_demo.py
```

Environment-only check:

```bash
bash scripts/check_env.sh
```

Direct vision check:

```bash
python scripts/check_vllm_vision.py
```

Endpoint check:

```bash
python scripts/check_vllm.py
```

Web demo from WSL:

```bash
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate
source scripts/env.sh
bash scripts/start_web_demo.sh
```

Web demo from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_web_demo_windows.ps1
```

Then open:

```text
http://127.0.0.1:7860
```

The page has two paths:

- Fixed label demo: runs the original generated inventory label through
  Qwen-Agent, calls `query_inventory`, then calls `estimate_shipping_days`.
- Custom vision test: upload an image or reuse the demo image, choose direct
  vision QA or Agent + tools, edit the prompt, and inspect the answer, event
  timeline, and raw response.

Stop the web demo:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_web_demo_windows.ps1
```

Or from WSL:

```bash
bash scripts/stop_web_demo.sh
```

## GodotSpace Agent Gateway

The Agent Gateway is separate from the existing web demo. It provides the Qwen
tool-routing websocket and an evidence-gated task-knowledge path. Godot returns
current task evidence through `query_task_knowledge`; the Gateway knowledge
Harness validates that evidence before producing the user-visible answer.

Start vLLM, then start the gateway:

```bash
bash scripts/start_vllm.sh
bash scripts/start_agent_gateway.sh
```

From PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_vllm_windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\start_agent_gateway_windows.ps1
```

Check the service:

```text
http://127.0.0.1:7861/healthz
http://127.0.0.1:7861/readyz
ws://127.0.0.1:7861/ws/godot
```

Run the gateway unit tests:

```bash
source .venv/bin/activate
python -m unittest discover -s agent_service/tests -v
```

Evaluate the deployed Qwen model against the fixed local knowledge-answering
suite (oracle evidence versus the current lexical retriever):

```bash
python scripts/benchmark_local_knowledge_qa.py \
  --endpoint http://127.0.0.1:18000/v1 \
  --mode both \
  --repeats 3
```

See `QWEN3_VL_DEEPSEEK_REPLACEMENT_EVAL.md` for the test design, acceptance
gates, and the first Qwen3-VL-2B result.

See `QWEN3_VL_8B_FP8_EVAL.md` for the single-RTX-4090 deployment, native and
Qwen-Agent tool-call results, knowledge-QA comparison with 2B and DeepSeek, and
the recommended evidence-gated replacement architecture.

Check readiness from WSL:

```bash
python scripts/check_agent_gateway.py
```

Run a temporary live vLLM plus gateway smoke test:

```bash
bash scripts/smoke_agent_gateway.sh
```

The websocket envelope and Godot response contract are documented in
`agent_service/README.md`.

## Notes for 8GB VRAM

The launch script keeps the workload small:

- `--max-model-len 2048`
- `--max-num-seqs 1`
- `--max-num-batched-tokens 2048`
- `--limit-mm-per-prompt '{"image": 1, "video": 0}'`
- `--mm-processor-kwargs '{"max_pixels": 401408}'`
- `--skip-mm-profiling`

If the server has memory headroom, try increasing `MAX_MODEL_LEN` to `4096`.
If image prompts are still too long, lower `MM_MAX_PIXELS`, for example:

```bash
MAX_MODEL_LEN=2048 MM_MAX_PIXELS=262144 bash scripts/start_vllm.sh
```

The default `scripts/env.sh` uses `HF_ENDPOINT=https://hf-mirror.com`, because
the plain `huggingface.co` endpoint can be unreachable from this WSL network.
It also disables Hugging Face Xet with `HF_HUB_DISABLE_XET=1`, which tends to be
more predictable with this mirror.

The bootstrap script pins `vllm==0.11.0` and `uv --torch-backend=cu126` for the
current Windows NVIDIA driver (`560.94`, CUDA 12.6). Newer vLLM wheels may pull
CUDA 13 runtime libraries and fail with "CUDA driver version is insufficient".

The Qwen-Agent demo uses `model_type="qwenvl_oai"` so local images are forwarded
through the OpenAI-compatible vLLM server. The function-call prompt is set to
`nous`, which worked reliably with `qwen-agent==0.0.34` in this environment.
