# Local Agent Gateway

This package is the Python side of the GodotSpace local Qwen-Agent integration.
Qwen routes UI tools and may select evidence IDs. Knowledge answers are rendered
locally from registered evidence; untrusted model-written knowledge prose is
never returned to the user. Godot exposes task evidence through
`query_task_knowledge`, and the Gateway publishes the semantic route
`knowledge_qa`.

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
| `AGENT_KNOWLEDGE_CONTEXT_TOOL_TIMEOUT` | `5.0` |
| `TOOL_SEMANTIC_TIMEOUT` | `10.0` |
| `AGENT_MAX_TOOL_CALLS` | `6` |
| `AGENT_MAX_MESSAGE_CHARS` | `8000` |
| `KNOWLEDGE_CORPUS_PATH` | empty server-owned JSON corpus |
| `KNOWLEDGE_MODEL_TIMEOUT` | `2.0` |

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

Supported tools cover album navigation, work-checklist navigation and state,
plus the read-only `query_task_knowledge` evidence tool. Godot dynamically
authorizes only tools valid for the current UI snapshot. When Qwen-Agent calls
one, the gateway sends `tool_call`. Godot must answer with the same `session_id`,
`request_id`, and `tool_call_id`:

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

For `query_task_knowledge`, `payload.data` must contain bounded evidence entries
instead of a model-written answer:

```json
{
  "ok": true,
  "data": {
    "entries": [
      {
        "id": "voice-current-task-step",
        "title": "无容器样品实验流程",
        "tags": ["当前任务", "当前步骤", "17.固定机构"],
        "content": "当前页：17/20\n当前步骤：17.固定机构\n要求：使用2.5N·m的力矩锁紧6颗M6螺钉。"
      }
    ]
  },
  "error": null
}
```

The Gateway owns evidence filtering and final answer rendering. An `answer`
field returned by this Godot tool is not a supported knowledge contract.

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

Qwen now calls selection-only proxy tools and supplies a structured semantic
frame. State changes additionally require an independent action-entailment
verdict. Code checks UI state, strict arguments, and `allowed_tools` before the
real Godot RPC is dispatched.

Tool routing and knowledge answering publish one versioned audit envelope in
`assistant_final.payload.harness_trace`. An ordinary UI request has one
`tool_call` stage; a knowledge request has ordered `tool_call` and `knowledge_qa`
stages. Each stage shares outcome, reason, model-attempt, fallback, and latency
fields while keeping domain data under `details`. The former
`assistant_final.payload.tool_harness` field remains as a compatibility view.
See [HARNESS_PROTOCOL.md](HARNESS_PROTOCOL.md),
[TOOL_CALL_HARNESS.md](TOOL_CALL_HARNESS.md), and
[KNOWLEDGE_HARNESS.md](KNOWLEDGE_HARNESS.md).

With live vLLM and the gateway running, the fixed tool-routing benchmark can run
without opening Godot:

```bash
python scripts/benchmark_tool_call_harness.py --repeats 3
```

It reports raw Qwen selection accuracy separately from harness-protected dispatch
accuracy and fails on every forbidden or unauthorized state mutation.

## Evidence-gated knowledge answers

`POST /v1/knowledge/answer` accepts a question, optional server-registered
`corpus_entry_ids`, and optional `runtime_entries`. Static source, trust, and
priority fields are server-owned; runtime entries may contain only `id`, `title`,
`content`, and optional `tags`. When `corpus_entry_ids` is omitted, the service
searches the configured corpus.

```json
{
  "question": "固定轴心机构的目标力矩是多少？",
  "runtime_entries": [
    {
      "id": "step-17",
      "title": "当前步骤17",
      "content": "使用2.5N·m力矩按对角线原则锁紧6颗M6螺钉。"
    }
  ]
}
```

The harness filters prompt injection, checks requested entities and values,
rejects conflicting parameters, and abstains when evidence is insufficient.
For multiple candidates Qwen may select evidence IDs under a strict JSON schema;
the server copies the registered text itself, preserves safety directives, and
falls back to deterministic evidence if the model times out or omits required
safety evidence. See [KNOWLEDGE_HARNESS.md](KNOWLEDGE_HARNESS.md).

To perform a live vLLM plus gateway smoke test and clean up both temporary
processes automatically:

```bash
bash scripts/smoke_agent_gateway.sh
```

Use `bash scripts/smoke_task_agent_live.sh` for the real Qwen + Godot
voice-to-tool path. The mock `test_task_agent_remote_e2e.sh` and
`test_task_agent_multi_client_e2e.sh` scripts validate target-Client isolation
without depending on model sampling.
