extends MultiplayerSpawner

const SERVER_PEER_ID: int = 1

@export var network_player: PackedScene

var _pending_spawn_ids: Dictionary = {}

func _ready() -> void:
	# Use one explicit custom-spawn path so the peer id is part of the replicated
	# spawn payload. This also lets late joiners reconstruct every existing peer.
	clear_spawnable_scenes()
	spawn_function = _instantiate_player
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(remove_player):
		multiplayer.peer_disconnected.connect(remove_player)
	var network_handler := _get_network_handler()
	if network_handler != null \
			and network_handler.has_signal("peer_role_changed") \
			and not network_handler.peer_role_changed.is_connected(_on_peer_role_changed):
		network_handler.peer_role_changed.connect(_on_peer_role_changed)
	call_deferred("_spawn_existing_players")

func _exit_tree() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(remove_player):
		multiplayer.peer_disconnected.disconnect(remove_player)
	var network_handler := _get_network_handler()
	if network_handler != null \
			and network_handler.has_signal("peer_role_changed") \
			and network_handler.peer_role_changed.is_connected(_on_peer_role_changed):
		network_handler.peer_role_changed.disconnect(_on_peer_role_changed)

func _spawn_existing_players() -> void:
	if not multiplayer.is_server():
		return

	spawn_player(SERVER_PEER_ID)
	for peer_id in multiplayer.get_peers():
		_try_spawn_registered_player(int(peer_id))


func _on_peer_connected(peer_id: int) -> void:
	_try_spawn_registered_player(peer_id)


func _on_peer_role_changed(peer_id: int, assigned_role: String) -> void:
	if not multiplayer.is_server() or peer_id <= SERVER_PEER_ID:
		return
	if assigned_role == "unknown":
		remove_player(peer_id)
		return
	_try_spawn_registered_player(peer_id)


func _try_spawn_registered_player(peer_id: int) -> void:
	if not multiplayer.is_server() or peer_id <= SERVER_PEER_ID:
		return
	if peer_id not in multiplayer.get_peers():
		return
	if _get_registered_peer_role(peer_id) not in ["ground_vr", "sky"]:
		return
	spawn_player(peer_id)

func spawn_player(id: int) -> void:
	if not multiplayer.is_server() or id <= 0:
		return

	var parent := get_node_or_null(spawn_path)
	if parent == null:
		push_error("MultiplayerSpawner cannot resolve spawn_path: %s" % spawn_path)
		return
	var player_name := str(id)
	if parent.get_node_or_null(player_name) != null or _pending_spawn_ids.has(id):
		return
	if network_player == null:
		push_error("MultiplayerSpawner cannot create player %d: network_player is not configured." % id)
		return

	_pending_spawn_ids[id] = true
	spawn({
		"peer_id": id,
		"session_role": _get_registered_peer_role(id),
	})
	_pending_spawn_ids.erase(id)

func _instantiate_player(data: Variant) -> Node:
	if network_player == null or not (data is Dictionary):
		return null

	var spawn_data := data as Dictionary
	var peer_id := int(spawn_data.get("peer_id", 0))
	if peer_id <= 0:
		return null

	var player: Node = network_player.instantiate()
	player.name = str(peer_id)
	if player.has_method("prepare_for_network_spawn"):
		var local_peer_id := multiplayer.get_unique_id() \
			if multiplayer.has_multiplayer_peer() else SERVER_PEER_ID
		player.call("prepare_for_network_spawn", peer_id == local_peer_id)
	if player.has_method("set_session_role"):
		player.call("set_session_role", str(spawn_data.get("session_role", "unknown")))
	return player

func _get_registered_peer_role(peer_id: int) -> String:
	var network_handler := _get_network_handler()
	if network_handler != null and network_handler.has_method("get_peer_role"):
		return str(network_handler.call("get_peer_role", peer_id))
	return "pc_ground" if peer_id == SERVER_PEER_ID else "sky"


func _get_network_handler() -> Node:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler != null and network_handler.multiplayer != multiplayer:
		return null
	return network_handler

func remove_player(id: int) -> void:
	if not multiplayer.is_server() or id == SERVER_PEER_ID:
		return

	_pending_spawn_ids.erase(id)
	var parent := get_node_or_null(spawn_path)
	if parent == null:
		return
	var player := parent.get_node_or_null(str(id))
	if player != null:
		parent.remove_child(player)
		player.queue_free()
