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
The optional `payload.context` is a sanitized object for this request only, and
`payload.allowed_tools` is the Router authorization boundary. For example, a
read-only task query sends:

```json
{
  "text": "下一步应该做什么",
  "context": {"task_id": 1, "page_index": 2},
  "allowed_tools": ["get_current_task_step"]
}
```

Supported tools are `open_album`, `open_task_guide`,
`get_current_task_step`, and `next_task_step`; at most three may be authorized
for one run. When Qwen-Agent calls one, the gateway sends `tool_call`. Godot must
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
The websocket `session_id` identifies only the transport connection. Every Agent
request is stateless and contains only its current user text and request context;
Qwen conversation history is not shared across requests or speakers.
Within a session, each accepted `request_id` is idempotent: retransmitting an
active or recently completed ID returns `duplicate_request_id` without rerunning
the Agent. Recent IDs and idle sessions are retained in bounded in-memory caches.
An already connected `session_id` cannot be replaced by a second websocket.

## Test

```bash
source .venv/bin/activate
python -m unittest discover -s agent_service/tests -v
```

The protocol, connection manager, timeout, disconnect, deduplication, cancellation
barrier, stateless request construction, serial queueing, Agent configuration, and
tool registration tests do not require a live vLLM or Godot instance.

The Gateway rejects a Qwen final answer when an authorized tool was never called;
this prevents a state-changing voice command from being reported as complete after
the model merely repeats it.

To perform a live vLLM plus gateway smoke test and clean up both temporary
processes automatically:

```bash
bash scripts/smoke_agent_gateway.sh
```

Use `bash scripts/smoke_task_agent_live.sh` for the real Qwen + Godot
voice-to-tool path. The mock `test_task_agent_remote_e2e.sh` and
`test_task_agent_multi_client_e2e.sh` scripts validate target-Client isolation
without depending on model sampling.
