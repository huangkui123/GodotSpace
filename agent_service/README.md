# Local Agent Gateway

This package is the Python side of the GodotSpace local Qwen-Agent integration.
It keeps the existing DeepSeek assistant path untouched and provides a separate,
opt-in websocket path for local Qwen tool calls.

## Run

Start vLLM first, then start the gateway:

```bash
bash scripts/start_vllm.sh
bash scripts/start_agent_gateway.sh
```

Defaults:

- vLLM: `http://127.0.0.1:8000/v1`
- Agent health: `http://127.0.0.1:7861/healthz`
- Agent readiness: `http://127.0.0.1:7861/readyz`
- Godot websocket: `ws://127.0.0.1:7861/ws/godot`

Relevant environment variables:

| Variable | Default |
| --- | --- |
| `AGENT_HOST` | `127.0.0.1` |
| `AGENT_PORT` | `7861` |
| `MODEL_SERVER` | `http://127.0.0.1:8000/v1` |
| `MODEL_NAME` | `Qwen/Qwen3-VL-2B-Instruct` |
| `API_KEY` | `EMPTY` |
| `AGENT_TOOL_TIMEOUT` | `5.0` |
| `AGENT_MAX_HISTORY_MESSAGES` | `8` |
| `AGENT_MAX_TOOL_CALLS` | `6` |
| `AGENT_MAX_MESSAGE_CHARS` | `8000` |

## Protocol

The first websocket message must be `hello`:

```json
{
  "protocol_version": "1.0",
  "type": "hello",
  "session_id": "",
  "request_id": "",
  "tool_call_id": "",
  "timestamp_ms": 1780000000000,
  "payload": {"client_id": "godotspace-dev"}
}
```

The server replies with `hello_ack` and assigns a session ID when the client did
not provide one. The client must use that session ID in subsequent messages.

To start an Agent run, Godot sends `user_message` with a non-empty `payload.text`.
When Qwen-Agent calls `open_album`, the gateway sends `tool_call`. Godot must
answer with the same `session_id`, `request_id`, and `tool_call_id`:

```json
{
  "protocol_version": "1.0",
  "type": "tool_result",
  "session_id": "session-...",
  "request_id": "request-1",
  "tool_call_id": "tool-...",
  "timestamp_ms": 1780000000000,
  "payload": {
    "ok": true,
    "data": {"visible": true, "page": 1, "picture_count": 18},
    "error": null
  }
}
```

The run ends with `assistant_final` or `run_error`. Tool calls are correlated by
ID, timeout independently, and fail when the owning Godot connection disconnects.
Within a session, each accepted `request_id` is idempotent: retransmitting an
active or recently completed ID returns `duplicate_request_id` without rerunning
the Agent. Recent IDs and idle sessions are retained in bounded in-memory caches.

## Test

```bash
source .venv/bin/activate
python -m unittest discover -s agent_service/tests -v
```

The protocol, connection manager, timeout, disconnect, deduplication, cancellation,
serial queueing, Agent configuration, tool registration, and session-history tests
do not require a live vLLM or Godot instance.

To perform a live vLLM plus gateway smoke test and clean up both temporary
processes automatically:

```bash
bash scripts/smoke_agent_gateway.sh
```
