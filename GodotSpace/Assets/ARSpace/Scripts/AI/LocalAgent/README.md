# Local Agent Bridge

`LocalAgentClient` is an Autoload client for the local Qwen-Agent Gateway at
`ws://127.0.0.1:7861/ws/godot`. It handles protocol `1.0` handshakes, heartbeats,
bounded reconnect backoff, session isolation, result correlation, and duplicate
`tool_call_id` replay. Conflicting reuse of an ID is rejected.

Inbound messages are limited by `arspace/local_agent/max_message_bytes` (256 KiB by
default). Missing pong responses close half-open connections. `get_debug_state()`
exposes the latest protocol or transport error for diagnostics. Disabling
`arspace/local_agent/enabled` at runtime immediately closes and clears the session.

Tools are available only through `LocalAgentToolRegistry`. Never add a generic node
path, method name, expression, or script execution tool. Each new tool needs a fixed
adapter, validated arguments, structured results, and headless tests.

The first registered tool is `open_album(page, refresh)`. Its adapter can only call
the fixed `PictureUIView.open_album` method and returns `album_not_ready` until that
UI has registered itself with `Global`.

Run the local logic test with Godot 4.4:

```powershell
Godot_v4.4-stable_win64.exe --headless --path F:\GodotSpace\GodotSpace `
  --script res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_bridge_self_test.gd
```

From the model repository in Ubuntu-20.04 WSL, run the real WebSocket RPC test:

```bash
bash scripts/test_godot_bridge.sh
```

To verify that a failed headless assertion cannot be overwritten by success, append
`-- --force-failure`; Godot must exit with code `1`.
