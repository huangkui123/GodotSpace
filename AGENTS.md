# Repository Guidelines

## Project Structure & Module Organization

- `agent_service/` contains the FastAPI/Qwen-Agent gateway; Godot-backed tools live in `agent_service/tools/`.
- `agent_service/tests/` contains `unittest` tests named `test_*.py`.
- `examples/` holds standalone Qwen-Agent demonstrations; `web_demo/` is the browser testbench.
- `scripts/` contains WSL bootstrap, service lifecycle, health-check, and smoke-test commands.
- `models/`, `generated/`, and `logs/` are local runtime artifacts and must remain untracked.
- `PLAN.md` tracks integration. Make Godot Agent changes only on `feature/local-agent-voice-tools`; never develop them on `codex/unity-to-godot`.

## WSL Environment

The supported runtime is WSL2 `Ubuntu-20.04` with Python 3.12 and CUDA on the RTX 4060. Windows path `C:\Users\94580\Desktop\cxy\Model` maps to `/mnt/c/Users/94580/Desktop/cxy/Model`. Its `.venv` contains Linux executables; do not use Windows `python.exe`. Check with `wsl.exe --list --verbose`, then run `wsl.exe -d Ubuntu-20.04 --cd /mnt/c/Users/94580/Desktop/cxy/Model -- ...`. Registrations are per Windows user, so sandbox accounts may report no distributions. Ports `8000`, `7860`, and `7861` normally use localhost forwarding.

## Build, Test, and Development Commands

```bash
bash scripts/bootstrap_wsl.sh                 # recreate the Python 3.12 environment
bash scripts/start_vllm.sh                    # serve Qwen3-VL on port 8000
bash scripts/start_agent_gateway.sh           # serve the gateway on port 7861
python -m unittest discover -s agent_service/tests -v
bash scripts/smoke_agent_gateway.sh           # temporary live vLLM + gateway check
bash scripts/test_godot_bridge.sh             # mock Gateway + Godot headless RPC check
python scripts/check_agent_gateway.py         # inspect readiness
```

The smoke script cleans up automatically. Use matching `stop_*.sh` or PowerShell wrappers for manually started services.

## Coding Style & Naming Conventions

Use four-space indentation, type hints, and `from __future__ import annotations`. Use `snake_case` for files/functions, `PascalCase` for classes, and uppercase constants. Keep async I/O in FastAPI/WebSocket layers and run blocking Agent work through `asyncio.to_thread`. Tools require explicit JSON schemas and must reject arbitrary Godot paths or methods.

## Testing Guidelines

Use `unittest`; asynchronous tests use `IsolatedAsyncioTestCase`. Test protocol validation, timeout/disconnect behavior, argument rejection, and WebSocket flow. Every behavior change should include a regression test. Keep live model checks in the smoke script.

## Commit & Pull Request Guidelines

No commit format can be verified from this checkout. Use scoped, imperative subjects such as `Add Godot tool result validation`. Pull requests should explain behavior/protocol changes, list tests, link issues, and include screenshots for `web_demo` UI changes.

## Security & Configuration

Keep API keys in environment variables. Do not commit model weights, uploaded images, logs, or generated content. Bind development services to `127.0.0.1` unless authenticated remote access is explicitly required.
