extends RefCounted

# Local inference grants no multiplayer authority. Only the audited local UI
# tools below may execute in this mode; shared-scene tools need a separate,
# Server-authorized path and must not be added here implicitly.
const LOCAL_UI_TOOLS := [
	"open_album", "close_album", "get_album_state", "next_album_page",
	"previous_album_page", "go_to_album_page", "open_task_guide",
	"close_task_guide", "get_current_task_step", "next_task_step",
	"previous_task_step", "go_to_task_guide_page", "query_task_knowledge",
]
static var _last_local_peer_id := 1


static func is_local() -> bool:
	return not OS.get_cmdline_user_args().has("--local-agent-server-relay") and str(
		ProjectSettings.get_setting("arspace/local_agent/execution_mode", "server_hosted")
	) == "local"


static func endpoint_asr() -> bool:
	return not OS.get_cmdline_user_args().has("--local-agent-server-relay") and str(
		ProjectSettings.get_setting("arspace/local_agent/execution_mode", "server_hosted")
	) != "server_relay"


static func local_peer_id(api: MultiplayerAPI) -> int:
	if api.has_multiplayer_peer() and not api.multiplayer_peer is OfflineMultiplayerPeer:
		if api.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_last_local_peer_id = api.get_unique_id()
	return _last_local_peer_id
