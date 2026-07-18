# Local Agent Bridge

`LocalAgentClient` is an Autoload client for the local Qwen-Agent Gateway at
`ws://127.0.0.1:7861/ws/godot`. It handles protocol `1.0` handshakes, heartbeats,
bounded reconnect backoff, session isolation, result correlation, and duplicate
`tool_call_id` replay. Conflicting reuse of an ID is rejected.

Inbound messages are limited by `arspace/local_agent/max_message_bytes` (256 KiB by
default). Missing pong responses close half-open connections. `get_debug_state()`
exposes the latest protocol or transport error for diagnostics. Disabling
`arspace/local_agent/enabled` at runtime immediately closes and clears the session.
Only the selected ENet server opens the Gateway connection; headless WebSocket
tests opt in with `-- --local-agent-testmode`.

Tools are available only through `LocalAgentToolRegistry`. Never add a generic node
path, method name, expression, or script execution tool. Each new tool needs a fixed
adapter, validated arguments, structured results, and headless tests.

`AssistantCommandRouter` is the only automatic final-transcript command consumer.
It keeps `speaker_peer_id` inside Godot, fetches the speaking Client's task snapshot,
and sends the Gateway only sanitized state plus a per-request tool allowlist.
Questions such as “下一步应该做什么” are read-only. Only explicit commands such
as “进入下一步” authorize `next_task_step`; the Server injects an operation ID and
the expected task/page before the target Client atomically advances.

The fixed tools are `open_album`, `open_task_guide`, `get_current_task_step`, and
`next_task_step`. Album and task mutations are targeted to the speaking Client;
there is no arbitrary NodePath, method, expression, or script execution endpoint.

Run the local logic test with Godot 4.4:

```powershell
Godot_v4.4-stable_win64.exe --headless --path F:\GodotSpace\GodotSpace `
  --script res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_bridge_self_test.gd

Godot_v4.4-stable_win64.exe --headless --path F:\GodotSpace\GodotSpace `
  --script res://Assets/ARSpace/Scripts/AI/LocalAgent/assistant_command_router_self_test.gd
```

From the model repository in Ubuntu-20.04 WSL, run the real WebSocket RPC test:

```bash
bash scripts/test_godot_bridge.sh
```

To verify that a failed headless assertion cannot be overwritten by success, append
`-- --force-failure`; Godot must exit with code `1`.
