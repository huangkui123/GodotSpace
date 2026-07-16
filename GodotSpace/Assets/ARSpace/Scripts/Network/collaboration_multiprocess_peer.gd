extends Node

const PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const SPAWNER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/Network/multiplayer_spawner.gd")
const ROLE_ARG: String = "--collab-process-role="
const PORT_ARG: String = "--collab-process-port="
const DEFAULT_PORT: int = 43195
const STAGE_TIMEOUT_MSEC: int = 10000

var _role: String = ""
var _port: int = DEFAULT_PORT
var _world: Node3D
var _peer: ENetMultiplayerPeer
var _failures: Array[String] = []


func _ready() -> void:
	_disable_unrelated_services()
	_role = _get_user_arg(ROLE_ARG).to_lower()
	var port_text := _get_user_arg(PORT_ARG)
	if port_text.is_valid_int():
		_port = int(port_text)
	call_deferred("_run")


func _disable_unrelated_services() -> void:
	# This harness owns the multiplayer peer directly and only exercises player
	# replication. Disable audio/LLM processing so offline reconnect intervals do
	# not make unrelated autoloads sample an intentionally detached peer.
	for service_path in [NodePath("/root/VoiceChat"), NodePath("/root/LLMAssistantService")]:
		var service := get_node_or_null(service_path)
		if service != null:
			service.process_mode = Node.PROCESS_MODE_DISABLED


func _run() -> void:
	match _role:
		"server":
			await _run_server()
		"first_client":
			await _run_first_client()
		"late_client":
			await _run_late_client()
		_:
			_failures.append("Unknown collaboration process role: %s" % _role)
	await _finish()


func _run_server() -> void:
	_peer = ENetMultiplayerPeer.new()
	_check(_peer.create_server(_port, 2, 3) == OK, "server should bind port %d" % _port)
	if not _failures.is_empty():
		return
	multiplayer.multiplayer_peer = _peer
	_world = _create_world("ServerWorld")
	_check(await _wait_for_player_count(2), "server should observe the first client")
	_check(await _wait_for_player_count(3), "server should observe the late client")
	_check(await _wait_for_player_count(2), "server should remove the disconnected first client")
	_check(await _wait_for_player_count(3), "server should observe the reconnected first client")
	_check(_has_unique_player_names(), "server should end with unique player instances")
	await get_tree().create_timer(0.75).timeout


func _run_first_client() -> void:
	_check(await _connect_client("FirstClientWorld"), "first client should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_player_count(2), "first client should initially see itself and peer 1")
	_check(await _wait_for_player_count(3), "first client should observe the late client")
	var old_peer_id := _peer.get_unique_id()
	await get_tree().create_timer(0.75).timeout
	_disconnect_and_free_world()
	await get_tree().create_timer(0.75).timeout
	_check(await _connect_client("ReconnectedClientWorld"), "first client should reconnect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_player_count(3), "reconnected client should receive the current player snapshot")
	var new_peer_id := _peer.get_unique_id()
	if new_peer_id != old_peer_id:
		_check(_world.get_node_or_null(str(old_peer_id)) == null, "reconnected client should not retain its stale player id")
	_check(_has_unique_player_names(), "reconnected client should end with unique player instances")
	await get_tree().create_timer(1.0).timeout


func _run_late_client() -> void:
	_check(await _connect_client("LateClientWorld"), "late client should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_player_count(3), "late client should receive all existing players")
	_check(await _wait_for_player_count(2), "late client should observe first-client cleanup")
	_check(await _wait_for_player_count(3), "late client should observe first-client reconnection")
	_check(_has_unique_player_names(), "late client should end with unique player instances")
	await get_tree().create_timer(0.75).timeout


func _connect_client(world_name: String) -> bool:
	_peer = ENetMultiplayerPeer.new()
	if _peer.create_client("127.0.0.1", _port, 3) != OK:
		return false
	multiplayer.multiplayer_peer = _peer
	_world = _create_world(world_name)
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var status := _peer.get_connection_status()
		if status == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if status == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await get_tree().process_frame
	return false


func _create_world(_world_name: String) -> Node3D:
	var world := Node3D.new()
	# MultiplayerSpawner RPC paths must match exactly across OS processes.
	world.name = "CollaborationWorld"
	get_tree().root.add_child(world)
	var spawner := SPAWNER_SCRIPT.new() as MultiplayerSpawner
	spawner.name = "MultiplayerSpawner"
	spawner.spawn_path = NodePath("..")
	spawner.network_player = PLAYER_SCENE
	world.add_child(spawner)
	return world


func _disconnect_and_free_world() -> void:
	if _world != null and is_instance_valid(_world):
		var parent := _world.get_parent()
		if parent != null:
			parent.remove_child(_world)
		_world.queue_free()
	_world = null
	var old_peer := _peer
	_peer = null
	multiplayer.multiplayer_peer = null
	if old_peer != null:
		old_peer.close()


func _wait_for_player_count(expected_count: int) -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _count_player_nodes() == expected_count:
			return true
		await get_tree().process_frame
	return false


func _count_player_nodes() -> int:
	if _world == null or not is_instance_valid(_world):
		return 0
	var count := 0
	for child in _world.get_children():
		if str(child.name).is_valid_int():
			count += 1
	return count


func _has_unique_player_names() -> bool:
	if _world == null or not is_instance_valid(_world):
		return false
	var names: Dictionary = {}
	for child in _world.get_children():
		var child_name := str(child.name)
		if not child_name.is_valid_int():
			continue
		if names.has(child_name):
			return false
		names[child_name] = true
	return names.size() == 3


func _get_user_arg(prefix: String) -> String:
	for value in OS.get_cmdline_user_args():
		var arg := str(value)
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	_disconnect_and_free_world()
	await get_tree().process_frame
	if _failures.is_empty():
		print("COLLABORATION_MULTIPROCESS_%s PASS" % _role.to_upper())
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("COLLABORATION_MULTIPROCESS_%s: %s" % [_role.to_upper(), failure])
	get_tree().quit(1)
