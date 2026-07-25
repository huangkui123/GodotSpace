extends SceneTree

const GAME_PORT: int = 42069

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var network_handler := root.get_node_or_null("NetworkHandler")
	var voice_chat := root.get_node_or_null("VoiceChat")
	_expect(network_handler != null, "NetworkHandler autoload must exist.")
	_expect(voice_chat != null, "VoiceChat autoload must exist.")
	if network_handler == null:
		_finish()
		return

	network_handler.call("_close_network_peer")
	_expect(root.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Closing a session must restore OfflineMultiplayerPeer.")
	_expect(root.multiplayer.get_unique_id() == 1, "Offline multiplayer must keep a safe local peer id.")

	# Simulate the recovery branch without deliberately causing a noisy ENet
	# bind error in the regular test suite.
	root.multiplayer.multiplayer_peer = null
	network_handler.set("peer", ENetMultiplayerPeer.new())
	var recovered := bool(network_handler.call(
		"_handle_start_failure",
		"Simulated UDP port %d failure." % GAME_PORT,
		false
	))
	_expect(not recovered, "The startup failure recovery helper must return false.")
	_expect(network_handler.get("peer") == null, "A failed ENet peer must be released.")
	_expect(root.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "A failed Server startup must leave an OfflineMultiplayerPeer assigned.")
	_expect(root.multiplayer.get_unique_id() == 1, "Peer id queries must remain safe after Server startup failure.")
	_expect(str(network_handler.call("get_last_start_error")).contains(str(GAME_PORT)), "Server startup failure must expose the occupied port to the menu.")

	if voice_chat != null:
		var previous_endpoint_selected: bool = bool(voice_chat.get("voice_endpoint_selected"))
		var previous_accumulator: float = float(voice_chat.get("_voice_level_send_accum"))
		voice_chat.set("voice_endpoint_selected", true)
		voice_chat.set("_voice_level_send_accum", 0.0)
		voice_chat.call("_update_voice_level_state", 1.0)
		_expect(is_zero_approx(float(voice_chat.get("_voice_level_send_accum"))), "Offline voice level updates must wait for a real ENet session.")
		voice_chat.set("voice_endpoint_selected", previous_endpoint_selected)
		voice_chat.set("_voice_level_send_accum", previous_accumulator)

	network_handler.call("_close_network_peer")
	_expect(root.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Closing after recovery must preserve offline mode.")
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("Network startup recovery self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
