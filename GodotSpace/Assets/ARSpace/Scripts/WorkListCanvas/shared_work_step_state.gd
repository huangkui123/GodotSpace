extends Node

const SERVER_PEER_ID: int = 1
const MIN_WORK_STEP: int = 1
const MAX_WORK_STEP: int = 20
const SNAPSHOT_REQUEST_RETRY_MSEC: int = 500
const SERVER_SNAPSHOT_MIN_INTERVAL_MSEC: int = 250

signal work_step_state_changed(
	is_visible: bool,
	active_step: int,
	replay_animation: bool
)
signal snapshot_applied(
	state_revision: int,
	is_visible: bool,
	active_step: int
)

@export var peer_authority_path: NodePath = NodePath("/root/NetworkHandler")
@export var warn_on_rejection: bool = true

var _is_visible: bool = false
var _active_step: int = 0
var _state_revision: int = 0
var _next_client_request_sequence: int = 1
var _snapshot_request_pending: bool = false
var _last_snapshot_request_msec: int = -SNAPSHOT_REQUEST_RETRY_MSEC
var _has_authoritative_state: bool = false
var _server_request_sequence_by_peer: Dictionary = {}
var _server_snapshot_request_msec_by_peer: Dictionary = {}


func _ready() -> void:
	add_to_group("shared_work_step_state")
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


func get_state_revision() -> int:
	return _state_revision


func get_current_state() -> Dictionary:
	return {
		"is_visible": _is_visible,
		"active_step": _active_step,
		"state_revision": _state_revision,
	}


func request_work_step(step_index: int) -> bool:
	if not _is_valid_step(step_index):
		return false
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		_commit_state(true, step_index, true)
		return true
	if not _is_connected_client() or not _can_local_control():
		return false
	var request_sequence := _take_client_request_sequence()
	rpc_id(
		SERVER_PEER_ID,
		"_server_request_work_step",
		request_sequence,
		step_index
	)
	return true


func request_worklist_visibility(is_visible: bool) -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		_commit_state(is_visible, _active_step, false)
		return true
	if not _is_connected_client() or not _can_local_control():
		return false
	var request_sequence := _take_client_request_sequence()
	rpc_id(
		SERVER_PEER_ID,
		"_server_request_worklist_visibility",
		request_sequence,
		is_visible
	)
	return true


func request_snapshot() -> bool:
	if not _is_connected_client():
		return false
	var now_msec := Time.get_ticks_msec()
	if _snapshot_request_pending \
			and now_msec - _last_snapshot_request_msec < SNAPSHOT_REQUEST_RETRY_MSEC:
		return false
	_snapshot_request_pending = true
	_last_snapshot_request_msec = now_msec
	rpc_id(SERVER_PEER_ID, "_server_request_work_step_snapshot")
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_work_step(request_sequence: int, step_index: int) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _validate_remote_request(sender_id, request_sequence):
		_send_snapshot(sender_id)
		return
	if not _is_valid_step(step_index):
		_reject("工作步骤请求参数无效。")
		_send_snapshot(sender_id)
		return
	_server_request_sequence_by_peer[sender_id] = request_sequence
	_commit_state(true, step_index, true)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_worklist_visibility(
	request_sequence: int,
	is_visible: bool
) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _validate_remote_request(sender_id, request_sequence):
		_send_snapshot(sender_id)
		return
	_server_request_sequence_by_peer[sender_id] = request_sequence
	_commit_state(is_visible, _active_step, false)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_work_step_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
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
func _rpc_receive_work_step_state(
	state_revision: int,
	is_visible: bool,
	active_step: int,
	replay_animation: bool
) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	var force_emit := not _has_authoritative_state
	if not _accept_state(
		state_revision,
		is_visible,
		active_step,
		replay_animation,
		force_emit
	):
		return
	_has_authoritative_state = true
	_snapshot_request_pending = false


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_receive_work_step_snapshot(
	state_revision: int,
	is_visible: bool,
	active_step: int
) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	var force_emit := not _has_authoritative_state
	var replay_animation := force_emit and is_visible and _is_valid_step(active_step)
	if not _accept_state(
		state_revision,
		is_visible,
		active_step,
		replay_animation,
		force_emit
	):
		return
	_has_authoritative_state = true
	_snapshot_request_pending = false
	snapshot_applied.emit(_state_revision, _is_visible, _active_step)


func _commit_state(
	is_visible: bool,
	active_step: int,
	replay_animation: bool
) -> void:
	if not _is_valid_stored_step(active_step):
		return
	var changed := is_visible != _is_visible or active_step != _active_step
	if not changed and not replay_animation:
		return
	_state_revision += 1
	_accept_state(
		_state_revision,
		is_visible,
		active_step,
		replay_animation,
		false
	)
	_has_authoritative_state = true
	if _has_connected_multiplayer_peer() and multiplayer.is_server():
		rpc(
			"_rpc_receive_work_step_state",
			_state_revision,
			_is_visible,
			_active_step,
			replay_animation
		)


func _accept_state(
	state_revision: int,
	is_visible: bool,
	active_step: int,
	replay_animation: bool,
	force_emit: bool
) -> bool:
	if state_revision < 0 \
			or state_revision < _state_revision \
			or not _is_valid_stored_step(active_step):
		return false
	var changed := state_revision != _state_revision \
		or is_visible != _is_visible \
		or active_step != _active_step
	_state_revision = state_revision
	_is_visible = is_visible
	_active_step = active_step
	if changed or force_emit or replay_animation:
		work_step_state_changed.emit(
			_is_visible,
			_active_step,
			replay_animation
		)
	return true


func _validate_remote_request(sender_id: int, request_sequence: int) -> bool:
	if sender_id <= SERVER_PEER_ID \
			or sender_id not in multiplayer.get_peers() \
			or request_sequence <= 0:
		return _reject("工作步骤请求来源或序列无效。")
	var previous_sequence := int(_server_request_sequence_by_peer.get(sender_id, 0))
	if request_sequence <= previous_sequence:
		return _reject("工作步骤请求已处理或已过期。")
	var authority := _get_peer_authority()
	if authority == null:
		return _reject("工作步骤同步缺少会话权限服务。")
	if authority.has_method("can_peer_control_work_steps"):
		if not bool(authority.call("can_peer_control_work_steps", sender_id)):
			return _reject("当前端没有工作步骤控制权限。")
		return true
	if authority.has_method("can_peer_control_shared_windows"):
		if not bool(authority.call("can_peer_control_shared_windows", sender_id)):
			return _reject("当前端没有工作步骤控制权限。")
		return true
	return _reject("会话权限服务不支持工作步骤鉴权。")


func _send_snapshot(peer_id: int) -> void:
	if peer_id <= SERVER_PEER_ID \
			or not _has_connected_multiplayer_peer() \
			or peer_id not in multiplayer.get_peers():
		return
	rpc_id(
		peer_id,
		"_rpc_receive_work_step_snapshot",
		_state_revision,
		_is_visible,
		_active_step
	)


func _take_client_request_sequence() -> int:
	var sequence := _next_client_request_sequence
	_next_client_request_sequence += 1
	return sequence


func _can_local_control() -> bool:
	var authority := _get_peer_authority()
	if authority == null:
		return false
	var local_peer_id := multiplayer.get_unique_id()
	if authority.has_method("can_peer_control_work_steps"):
		return bool(authority.call("can_peer_control_work_steps", local_peer_id))
	if authority.has_method("can_peer_control_shared_windows"):
		return bool(authority.call("can_peer_control_shared_windows", local_peer_id))
	return false


func _get_peer_authority() -> Node:
	return get_node_or_null(peer_authority_path) \
		if not peer_authority_path.is_empty() else null


func _is_connected_client() -> bool:
	return not multiplayer.is_server() and _has_connected_multiplayer_peer()


func _has_connected_multiplayer_peer() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	var active_peer := multiplayer.multiplayer_peer
	return active_peer != null \
		and active_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _is_valid_step(step_index: int) -> bool:
	return step_index >= MIN_WORK_STEP and step_index <= MAX_WORK_STEP


func _is_valid_stored_step(step_index: int) -> bool:
	return step_index == 0 or _is_valid_step(step_index)


func _reject(message: String) -> bool:
	if warn_on_rejection:
		push_warning(message)
	return false


func _on_connected_to_server() -> void:
	_is_visible = false
	_active_step = 0
	_state_revision = 0
	_next_client_request_sequence = 1
	_snapshot_request_pending = false
	_last_snapshot_request_msec = -SNAPSHOT_REQUEST_RETRY_MSEC
	_has_authoritative_state = false
	work_step_state_changed.emit(false, 0, false)
	call_deferred("request_snapshot")


func _on_peer_disconnected(peer_id: int) -> void:
	_server_request_sequence_by_peer.erase(peer_id)
	_server_snapshot_request_msec_by_peer.erase(peer_id)


func _request_initial_snapshot() -> void:
	if _is_connected_client():
		request_snapshot()
