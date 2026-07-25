extends Node

const SERVER_PEER_ID: int = 1
const MODE_LIFE: int = 0
const MODE_WORK: int = 1
const SNAPSHOT_REQUEST_RETRY_MSEC: int = 500
const SERVER_SNAPSHOT_MIN_INTERVAL_MSEC: int = 250

signal active_mode_changed(active_mode: int)
signal snapshot_applied(state_revision: int, active_mode: int)

@export var peer_authority_path: NodePath = NodePath("/root/NetworkHandler")
@export var warn_on_rejection: bool = true

var _active_mode: int = MODE_LIFE
var _state_revision: int = 0
var _next_client_request_sequence: int = 1
var _snapshot_request_pending: bool = false
var _last_snapshot_request_msec: int = -SNAPSHOT_REQUEST_RETRY_MSEC
var _server_request_sequence_by_peer: Dictionary = {}
var _server_snapshot_request_msec_by_peer: Dictionary = {}


func _ready() -> void:
	add_to_group("shared_main_menu_state")
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	call_deferred("_request_initial_snapshot")


func _process(_delta: float) -> void:
	if not _snapshot_request_pending or not _is_connected_client():
		return
	if Time.get_ticks_msec() - _last_snapshot_request_msec >= SNAPSHOT_REQUEST_RETRY_MSEC:
		request_snapshot()


func _exit_tree() -> void:
	if multiplayer == null:
		return
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)


func get_active_mode() -> int:
	return _active_mode


func get_state_revision() -> int:
	return _state_revision


func request_active_mode(active_mode: int) -> bool:
	if not _is_valid_mode(active_mode):
		return false
	if not multiplayer.has_multiplayer_peer():
		_commit_state(active_mode)
		return true
	if multiplayer.is_server():
		_commit_state(active_mode)
		return true
	if not _is_connected_client() or not _can_local_control():
		return false
	var request_sequence := _next_client_request_sequence
	_next_client_request_sequence += 1
	rpc_id(
		SERVER_PEER_ID,
		"_server_request_active_mode",
		request_sequence,
		active_mode
	)
	return true


func request_snapshot() -> bool:
	if not _is_connected_client():
		return false
	_snapshot_request_pending = true
	_last_snapshot_request_msec = Time.get_ticks_msec()
	rpc_id(SERVER_PEER_ID, "_server_request_main_menu_snapshot")
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_active_mode(request_sequence: int, active_mode: int) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _validate_remote_request(sender_id, request_sequence, active_mode):
		_send_snapshot(sender_id)
		return
	_server_request_sequence_by_peer[sender_id] = request_sequence
	if active_mode == _active_mode:
		_send_snapshot(sender_id)
		return
	_commit_state(active_mode)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_main_menu_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var now_msec := Time.get_ticks_msec()
	var previous_msec := int(_server_snapshot_request_msec_by_peer.get(
		sender_id,
		-SERVER_SNAPSHOT_MIN_INTERVAL_MSEC
	))
	if now_msec - previous_msec < SERVER_SNAPSHOT_MIN_INTERVAL_MSEC:
		return
	_server_snapshot_request_msec_by_peer[sender_id] = now_msec
	_send_snapshot(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_receive_main_menu_state(state_revision: int, active_mode: int) -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if not _accept_state(state_revision, active_mode, true):
		return
	_snapshot_request_pending = false
	snapshot_applied.emit(_state_revision, _active_mode)


func _commit_state(active_mode: int) -> void:
	if not _is_valid_mode(active_mode):
		return
	if active_mode != _active_mode:
		_state_revision += 1
		_accept_state(_state_revision, active_mode, false)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		rpc("_rpc_receive_main_menu_state", _state_revision, _active_mode)


func _accept_state(state_revision: int, active_mode: int, force_emit: bool) -> bool:
	if state_revision < 0 \
			or state_revision < _state_revision \
			or not _is_valid_mode(active_mode):
		return false
	var changed := state_revision != _state_revision or active_mode != _active_mode
	_state_revision = state_revision
	_active_mode = active_mode
	if changed or force_emit:
		active_mode_changed.emit(_active_mode)
	return true


func _validate_remote_request(
	sender_id: int,
	request_sequence: int,
	active_mode: int
) -> bool:
	if sender_id <= SERVER_PEER_ID \
			or request_sequence <= 0 \
			or not _is_valid_mode(active_mode):
		return _reject("MainMenu 模式请求参数无效。")
	var previous_sequence := int(_server_request_sequence_by_peer.get(sender_id, 0))
	if request_sequence <= previous_sequence:
		return _reject("MainMenu 模式请求已处理或已过期。")
	var authority := _get_peer_authority()
	if authority == null \
			or not authority.has_method("can_peer_control_shared_windows") \
			or not bool(authority.call("can_peer_control_shared_windows", sender_id)):
		return _reject("当前端没有共享 MainMenu 控制权限。")
	return true


func _send_snapshot(peer_id: int) -> void:
	if peer_id <= SERVER_PEER_ID \
			or not multiplayer.has_multiplayer_peer() \
			or peer_id not in multiplayer.get_peers():
		return
	rpc_id(
		peer_id,
		"_rpc_receive_main_menu_state",
		_state_revision,
		_active_mode
	)


func _can_local_control() -> bool:
	var authority := _get_peer_authority()
	if authority == null:
		return false
	if authority.has_method("can_peer_control_shared_windows"):
		return bool(authority.call(
			"can_peer_control_shared_windows",
			multiplayer.get_unique_id()
		))
	var role := str(authority.call("get_local_assigned_role")) \
		if authority.has_method("get_local_assigned_role") else ""
	return role in ["pc_ground", "ground_vr", "sky"]


func _get_peer_authority() -> Node:
	return get_node_or_null(peer_authority_path) if not peer_authority_path.is_empty() else null


func _is_connected_client() -> bool:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return false
	var active_peer := multiplayer.multiplayer_peer
	return active_peer != null \
		and active_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _is_valid_mode(active_mode: int) -> bool:
	return active_mode in [MODE_LIFE, MODE_WORK]


func _reject(message: String) -> bool:
	if warn_on_rejection:
		push_warning(message)
	return false


func _on_connected_to_server() -> void:
	_active_mode = MODE_LIFE
	_state_revision = 0
	_next_client_request_sequence = 1
	_snapshot_request_pending = false
	_last_snapshot_request_msec = -SNAPSHOT_REQUEST_RETRY_MSEC
	active_mode_changed.emit(_active_mode)
	call_deferred("request_snapshot")


func _on_peer_disconnected(peer_id: int) -> void:
	_server_request_sequence_by_peer.erase(peer_id)
	_server_snapshot_request_msec_by_peer.erase(peer_id)


func _request_initial_snapshot() -> void:
	if _is_connected_client():
		request_snapshot()
