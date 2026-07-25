extends Node

const SERVER_PEER_ID: int = 1
const SCOPE_SHARED: int = 1
const STATE_HIDDEN: int = 0
const STATE_FLOATING: int = 1
const STATE_DRAGGING: int = 2
const STATE_SNAP_CANDIDATE: int = 3
const STATE_SNAPPED: int = 4
const MAX_SHARED_WINDOWS: int = 32
const MAX_WINDOW_ID_LENGTH: int = 64
const MAX_SLOT_ID_LENGTH: int = 64
const MAX_SHARED_ORIGIN_DISTANCE_M: float = 50.0
const MAX_INTERACTION_DISTANCE_M: float = 12.0
const MIN_SCALE_RATIO: float = 0.25
const MAX_SCALE_RATIO: float = 3.0
const SNAPSHOT_REQUEST_RETRY_MSEC: int = 500
const SERVER_SNAPSHOT_MIN_INTERVAL_MSEC: int = 250
const DRAG_PREVIEW_MIN_INTERVAL_MSEC: int = 30

signal window_state_changed(record: Dictionary)
signal drag_preview_received(
	window_id: StringName,
	shared_transform: Transform3D,
	operator_peer_id: int
)
signal operation_failed(operation: String, window_id: StringName, message: String)
signal snapshot_applied(state_revision: int, window_count: int)

@export var shared_space_origin_path: NodePath = NodePath("..")
@export var dock_manager_path: NodePath = NodePath("../WindowDockSlots")
@export var peer_authority_path: NodePath = NodePath("/root/NetworkHandler")
@export var require_remote_interaction_pose: bool = true
@export var warn_on_rejection: bool = true

var _window_configs: Dictionary = {}
var _controllers: Dictionary = {}
var _window_states: Dictionary = {}
var _active_drags: Dictionary = {}
var _state_revision: int = 0
var _next_client_operation_sequence: int = 1
var _next_client_drag_token: int = 1
var _snapshot_request_pending: bool = false
var _last_snapshot_request_msec: int = -SNAPSHOT_REQUEST_RETRY_MSEC
var _server_operation_sequence_by_peer: Dictionary = {}
var _server_snapshot_request_msec_by_peer: Dictionary = {}
var _server_preview_sequence_by_drag: Dictionary = {}
var _server_preview_msec_by_drag: Dictionary = {}


func _ready() -> void:
	add_to_group("spatial_window_state_manager")
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	call_deferred("_request_initial_snapshot")


func _process(_delta: float) -> void:
	if not _snapshot_request_pending or not _is_connected_client():
		return
	if Time.get_ticks_msec() - _last_snapshot_request_msec >= SNAPSHOT_REQUEST_RETRY_MSEC:
		request_window_snapshot()


func _exit_tree() -> void:
	if multiplayer != null:
		if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
			multiplayer.connected_to_server.disconnect(_on_connected_to_server)
		if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
			multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)


func register_window(controller: Node) -> bool:
	if controller == null \
			or not is_instance_valid(controller) \
			or not controller.has_method("get_window_config"):
		return false
	var config := controller.call("get_window_config") as Dictionary
	var window_id := StringName(str(config.get("window_id", "")).strip_edges())
	if not _validate_config(config) or int(config.get("scope", -1)) != SCOPE_SHARED:
		return false
	var existing: Node = _controllers.get(window_id)
	if existing != null and is_instance_valid(existing) and existing != controller:
		push_error("Duplicate shared spatial window_id: %s" % window_id)
		return false
	_window_configs[window_id] = config.duplicate(true)
	_controllers[window_id] = controller
	if multiplayer.is_server() and not _window_states.has(window_id):
		var initial_record := _make_initial_record(controller)
		_window_states[window_id] = initial_record
	elif _window_states.has(window_id):
		controller.call("apply_authoritative_record", get_window_state(window_id))
	return true


func unregister_window(controller: Node) -> void:
	if controller == null or not controller.has_method("get_window_id"):
		return
	var window_id := StringName(str(controller.call("get_window_id")))
	if _controllers.get(window_id) == controller:
		_controllers.erase(window_id)
	# Configuration and authoritative records intentionally survive a scene
	# node's brief absence so a recreated pre-instanced window can consume the
	# same snapshot without changing its stable business ID.


func get_state_revision() -> int:
	return _state_revision


func get_window_state(window_id: StringName) -> Dictionary:
	if not _window_states.has(window_id):
		return {}
	return (_window_states[window_id] as Dictionary).duplicate(true)


func get_window_states() -> Array:
	var result: Array = []
	var ids: Array = _window_states.keys()
	ids.sort_custom(func(a, b): return str(a) < str(b))
	for window_id in ids:
		result.append((_window_states[window_id] as Dictionary).duplicate(true))
	return result


func request_open_window(window_id: StringName, shared_transform: Transform3D) -> bool:
	if not _can_local_control(window_id):
		return false
	var sequence := _take_client_operation_sequence()
	if multiplayer.is_server():
		return _server_apply_open(SERVER_PEER_ID, sequence, window_id, shared_transform)
	if not _is_connected_client():
		return false
	rpc_id(SERVER_PEER_ID, "_server_open_window", sequence, window_id, shared_transform)
	return true


func request_close_window(window_id: StringName) -> bool:
	if not _can_local_control(window_id):
		return false
	var sequence := _take_client_operation_sequence()
	if multiplayer.is_server():
		return _server_apply_close(SERVER_PEER_ID, sequence, window_id)
	if not _is_connected_client():
		return false
	rpc_id(SERVER_PEER_ID, "_server_close_window", sequence, window_id)
	return true


func request_settled_state(
	window_id: StringName,
	shared_transform: Transform3D,
	slot_id: StringName
) -> bool:
	if not _can_local_control(window_id):
		return false
	var sequence := _take_client_operation_sequence()
	if multiplayer.is_server():
		return _server_apply_settled(
			SERVER_PEER_ID,
			sequence,
			window_id,
			shared_transform,
			slot_id
		)
	if not _is_connected_client():
		return false
	rpc_id(
		SERVER_PEER_ID,
		"_server_settled_window",
		sequence,
		window_id,
		shared_transform,
		slot_id
	)
	return true


func request_begin_drag(
	window_id: StringName,
	shared_transform: Transform3D
) -> int:
	if not _can_local_control(window_id):
		return 0
	var token := _take_client_drag_token()
	var sequence := _take_client_operation_sequence()
	if multiplayer.is_server():
		return token if _server_apply_begin_drag(
			SERVER_PEER_ID,
			sequence,
			window_id,
			token,
			shared_transform
		) else 0
	if not _is_connected_client():
		return 0
	rpc_id(
		SERVER_PEER_ID,
		"_server_begin_drag",
		sequence,
		window_id,
		token,
		shared_transform
	)
	return token


func request_drag_preview(
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D
) -> bool:
	if not _can_local_control(window_id) or drag_token <= 0 or drag_sequence <= 0:
		return false
	if multiplayer.is_server():
		return _server_apply_drag_preview(
			SERVER_PEER_ID,
			window_id,
			drag_token,
			drag_sequence,
			shared_transform
		)
	if not _is_connected_client():
		return false
	rpc_id(
		SERVER_PEER_ID,
		"_server_drag_preview",
		window_id,
		drag_token,
		drag_sequence,
		shared_transform
	)
	return true


func request_finish_drag(
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D,
	slot_id: StringName
) -> bool:
	if not _can_local_control(window_id) or drag_token <= 0 or drag_sequence <= 0:
		return false
	var sequence := _take_client_operation_sequence()
	if multiplayer.is_server():
		return _server_apply_finish_drag(
			SERVER_PEER_ID,
			sequence,
			window_id,
			drag_token,
			drag_sequence,
			shared_transform,
			slot_id
		)
	if not _is_connected_client():
		return false
	rpc_id(
		SERVER_PEER_ID,
		"_server_finish_drag",
		sequence,
		window_id,
		drag_token,
		drag_sequence,
		shared_transform,
		slot_id
	)
	return true


func request_window_snapshot() -> void:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_snapshot_request_pending = true
		return
	var now_msec := Time.get_ticks_msec()
	if _snapshot_request_pending \
			and now_msec - _last_snapshot_request_msec < SNAPSHOT_REQUEST_RETRY_MSEC:
		return
	_snapshot_request_pending = true
	_last_snapshot_request_msec = now_msec
	rpc_id(SERVER_PEER_ID, "_server_request_window_snapshot")


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_open_window(
	request_sequence: int,
	window_id: StringName,
	shared_transform: Transform3D
) -> void:
	_server_apply_open(
		multiplayer.get_remote_sender_id(),
		request_sequence,
		window_id,
		shared_transform
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_close_window(request_sequence: int, window_id: StringName) -> void:
	_server_apply_close(multiplayer.get_remote_sender_id(), request_sequence, window_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_settled_window(
	request_sequence: int,
	window_id: StringName,
	shared_transform: Transform3D,
	slot_id: StringName
) -> void:
	_server_apply_settled(
		multiplayer.get_remote_sender_id(),
		request_sequence,
		window_id,
		shared_transform,
		slot_id
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_begin_drag(
	request_sequence: int,
	window_id: StringName,
	drag_token: int,
	shared_transform: Transform3D
) -> void:
	_server_apply_begin_drag(
		multiplayer.get_remote_sender_id(),
		request_sequence,
		window_id,
		drag_token,
		shared_transform
	)


@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _server_drag_preview(
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D
) -> void:
	_server_apply_drag_preview(
		multiplayer.get_remote_sender_id(),
		window_id,
		drag_token,
		drag_sequence,
		shared_transform
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_finish_drag(
	request_sequence: int,
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D,
	slot_id: StringName
) -> void:
	_server_apply_finish_drag(
		multiplayer.get_remote_sender_id(),
		request_sequence,
		window_id,
		drag_token,
		drag_sequence,
		shared_transform,
		slot_id
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_window_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	var now_msec := Time.get_ticks_msec()
	var previous := int(_server_snapshot_request_msec_by_peer.get(
		sender_id,
		-SERVER_SNAPSHOT_MIN_INTERVAL_MSEC
	))
	if now_msec - previous < SERVER_SNAPSHOT_MIN_INTERVAL_MSEC:
		return
	_server_snapshot_request_msec_by_peer[sender_id] = now_msec
	rpc_id(sender_id, "_rpc_receive_window_snapshot", _state_revision, get_window_states())


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_upsert_window(server_revision: int, record: Dictionary) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if server_revision <= _state_revision:
		return
	if server_revision > _state_revision + 1 or not _validate_record(record):
		request_window_snapshot()
		return
	_state_revision = server_revision
	_apply_record(record)


@rpc("authority", "call_remote", "unreliable_ordered", 0)
func _rpc_window_drag_preview(
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D,
	operator_peer_id: int
) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	var record := get_window_state(window_id)
	if record.is_empty() \
			or int(record.get("state", -1)) != STATE_DRAGGING \
			or int(record.get("drag_token", 0)) != drag_token \
			or int(record.get("operator_peer_id", 0)) != operator_peer_id \
			or drag_sequence <= 0 \
			or not _validate_transform_for_window(window_id, shared_transform):
		return
	_apply_drag_preview_to_controller(window_id, shared_transform, operator_peer_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_receive_window_snapshot(server_revision: int, snapshot: Array) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_apply_snapshot(server_revision, snapshot)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_window_operation_failed(
	operation: String,
	window_id: StringName,
	message: String,
	current_record: Dictionary
) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if not current_record.is_empty() and _validate_record(current_record):
		_apply_record(current_record)
	var detail := message if not message.is_empty() else "地面 Server 拒绝了窗口操作。"
	if warn_on_rejection:
		push_warning(detail)
	operation_failed.emit(operation, window_id, detail)


func _server_apply_open(
	sender_id: int,
	request_sequence: int,
	window_id: StringName,
	shared_transform: Transform3D
) -> bool:
	var error := _get_operation_error(sender_id, request_sequence, window_id)
	if error.is_empty() and _active_drags.has(window_id):
		error = "窗口正在由另一项拖拽操作控制。"
	if error.is_empty():
		error = _get_transform_error(sender_id, window_id, shared_transform)
	if not error.is_empty():
		return _reject_remote(sender_id, "open", window_id, error)
	var record := get_window_state(window_id)
	record["visible"] = true
	record["state"] = STATE_FLOATING
	record["transform"] = shared_transform
	record["slot_id"] = ""
	record["operator_peer_id"] = 0
	record["drag_token"] = 0
	_commit_record(record)
	return true


func _server_apply_close(
	sender_id: int,
	request_sequence: int,
	window_id: StringName
) -> bool:
	var error := _get_operation_error(sender_id, request_sequence, window_id)
	if error.is_empty() and _active_drags.has(window_id):
		var active := _active_drags[window_id] as Dictionary
		if int(active.get("peer_id", 0)) != sender_id:
			error = "窗口正在由另一端拖拽。"
	if not error.is_empty():
		return _reject_remote(sender_id, "close", window_id, error)
	_active_drags.erase(window_id)
	var record := get_window_state(window_id)
	record["visible"] = false
	record["state"] = STATE_HIDDEN
	record["slot_id"] = ""
	record["operator_peer_id"] = 0
	record["drag_token"] = 0
	_commit_record(record)
	return true


func _server_apply_settled(
	sender_id: int,
	request_sequence: int,
	window_id: StringName,
	shared_transform: Transform3D,
	slot_id: StringName
) -> bool:
	var error := _get_operation_error(sender_id, request_sequence, window_id)
	if error.is_empty() and _active_drags.has(window_id):
		error = "窗口仍处于拖拽锁定状态。"
	if error.is_empty():
		error = _get_transform_error(sender_id, window_id, shared_transform)
	if error.is_empty():
		error = _get_slot_error(window_id, slot_id)
	if not error.is_empty():
		return _reject_remote(sender_id, "settle", window_id, error)
	var record := get_window_state(window_id)
	record["visible"] = true
	record["state"] = STATE_SNAPPED if not slot_id.is_empty() else STATE_FLOATING
	record["transform"] = _canonicalize_slot_transform(window_id, slot_id, shared_transform)
	record["slot_id"] = str(slot_id)
	record["operator_peer_id"] = 0
	record["drag_token"] = 0
	_commit_record(record)
	return true


func _server_apply_begin_drag(
	sender_id: int,
	request_sequence: int,
	window_id: StringName,
	drag_token: int,
	shared_transform: Transform3D
) -> bool:
	var error := _get_operation_error(sender_id, request_sequence, window_id)
	if error.is_empty() and drag_token <= 0:
		error = "窗口拖拽令牌无效。"
	if error.is_empty() and _active_drags.has(window_id):
		error = "窗口已被另一端锁定。"
	if error.is_empty():
		error = _get_transform_error(sender_id, window_id, shared_transform)
	if not error.is_empty():
		return _reject_remote(sender_id, "begin_drag", window_id, error)
	_active_drags[window_id] = {
		"peer_id": sender_id,
		"token": drag_token,
		"last_sequence": 0,
		"last_transform": shared_transform,
	}
	var record := get_window_state(window_id)
	record["visible"] = true
	record["state"] = STATE_DRAGGING
	record["transform"] = shared_transform
	record["slot_id"] = ""
	record["operator_peer_id"] = sender_id
	record["drag_token"] = drag_token
	_commit_record(record)
	return true


func _server_apply_drag_preview(
	sender_id: int,
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D
) -> bool:
	var error := _get_preview_error(
		sender_id,
		window_id,
		drag_token,
		drag_sequence,
		shared_transform
	)
	if not error.is_empty():
		return false
	var active := _active_drags[window_id] as Dictionary
	active["last_sequence"] = drag_sequence
	active["last_transform"] = shared_transform
	_active_drags[window_id] = active
	var key := "%d:%s" % [sender_id, window_id]
	_server_preview_sequence_by_drag[key] = drag_sequence
	_server_preview_msec_by_drag[key] = Time.get_ticks_msec()
	_apply_drag_preview_to_controller(window_id, shared_transform, sender_id)
	if multiplayer.has_multiplayer_peer():
		rpc(
			"_rpc_window_drag_preview",
			window_id,
			drag_token,
			drag_sequence,
			shared_transform,
			sender_id
		)
	return true


func _server_apply_finish_drag(
	sender_id: int,
	request_sequence: int,
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D,
	slot_id: StringName
) -> bool:
	var error := _get_operation_error(sender_id, request_sequence, window_id)
	if error.is_empty():
		error = _get_drag_lock_error(sender_id, window_id, drag_token, drag_sequence)
	if not error.is_empty():
		return _reject_remote(sender_id, "finish_drag", window_id, error)
	var active := _active_drags[window_id] as Dictionary
	var transform_error := _get_transform_error(sender_id, window_id, shared_transform)
	var slot_error := _get_slot_error(window_id, slot_id) \
		if transform_error.is_empty() else ""
	if not transform_error.is_empty() or not slot_error.is_empty():
		_active_drags.erase(window_id)
		var fallback_record := get_window_state(window_id)
		fallback_record["visible"] = true
		fallback_record["state"] = STATE_FLOATING
		fallback_record["transform"] = active.get(
			"last_transform",
			fallback_record.get("transform", Transform3D.IDENTITY)
		) if not transform_error.is_empty() else shared_transform
		fallback_record["slot_id"] = ""
		fallback_record["operator_peer_id"] = 0
		fallback_record["drag_token"] = 0
		_commit_record(fallback_record)
		return _reject_remote(
			sender_id,
			"finish_drag",
			window_id,
			transform_error if not transform_error.is_empty() else slot_error
		)
	_active_drags.erase(window_id)
	var key := "%d:%s" % [sender_id, window_id]
	_server_preview_sequence_by_drag.erase(key)
	_server_preview_msec_by_drag.erase(key)
	var record := get_window_state(window_id)
	record["visible"] = true
	record["state"] = STATE_SNAPPED if not slot_id.is_empty() else STATE_FLOATING
	record["transform"] = _canonicalize_slot_transform(window_id, slot_id, shared_transform)
	record["slot_id"] = str(slot_id)
	record["operator_peer_id"] = 0
	record["drag_token"] = 0
	_commit_record(record)
	return true


func _commit_record(record: Dictionary) -> void:
	var window_id := StringName(str(record.get("window_id", "")))
	_state_revision += 1
	record["revision"] = _state_revision
	_apply_record(record)
	if multiplayer.has_multiplayer_peer():
		rpc("_rpc_upsert_window", _state_revision, record)


func _apply_record(record: Dictionary) -> void:
	var window_id := StringName(str(record.get("window_id", "")))
	var replacement := record.duplicate(true)
	_window_states[window_id] = replacement
	_reconcile_window_occupancy(window_id, StringName(str(record.get("slot_id", ""))))
	var controller: Node = _controllers.get(window_id)
	if controller != null and is_instance_valid(controller):
		controller.call("apply_authoritative_record", replacement.duplicate(true))
	window_state_changed.emit(replacement.duplicate(true))


func _apply_drag_preview_to_controller(
	window_id: StringName,
	shared_transform: Transform3D,
	operator_peer_id: int
) -> void:
	var controller: Node = _controllers.get(window_id)
	if controller != null and is_instance_valid(controller):
		controller.call(
			"apply_authoritative_drag_preview",
			shared_transform,
			operator_peer_id
		)
	drag_preview_received.emit(window_id, shared_transform, operator_peer_id)


func _apply_snapshot(server_revision: int, snapshot: Array) -> bool:
	if server_revision < _state_revision or snapshot.size() > MAX_SHARED_WINDOWS:
		return false
	var replacement: Dictionary = {}
	var occupied_slots: Dictionary = {}
	for value in snapshot:
		if not (value is Dictionary):
			return false
		var record := (value as Dictionary).duplicate(true)
		if not _validate_record(record):
			return false
		var window_id := StringName(str(record.get("window_id", "")))
		if replacement.has(window_id):
			return false
		var slot_id := StringName(str(record.get("slot_id", "")))
		if not slot_id.is_empty():
			if occupied_slots.has(slot_id):
				return false
			occupied_slots[slot_id] = window_id
		replacement[window_id] = record
	if server_revision == _state_revision and replacement == _window_states:
		_snapshot_request_pending = false
		return true
	for window_id_value in _window_configs.keys():
		_release_manager_window(StringName(window_id_value))
	_window_states = {}
	var ids: Array = replacement.keys()
	ids.sort_custom(func(a, b): return str(a) < str(b))
	for window_id in ids:
		_apply_record(replacement[window_id] as Dictionary)
	_state_revision = server_revision
	_snapshot_request_pending = false
	snapshot_applied.emit(_state_revision, _window_states.size())
	return true


func _validate_record(record: Dictionary) -> bool:
	if record.size() > 10:
		return false
	var window_id := StringName(str(record.get("window_id", "")).strip_edges())
	if window_id.is_empty() \
			or str(window_id).length() > MAX_WINDOW_ID_LENGTH \
			or not _window_configs.has(window_id):
		return false
	if int(record.get("revision", 0)) < 0:
		return false
	var visible_value = record.get("visible", null)
	if not (visible_value is bool):
		return false
	var state := int(record.get("state", -1))
	var slot_id := StringName(str(record.get("slot_id", "")))
	var operator_peer_id := int(record.get("operator_peer_id", 0))
	var drag_token := int(record.get("drag_token", 0))
	var transform_value = record.get("transform", null)
	if not (transform_value is Transform3D) \
			or not _validate_transform_for_window(window_id, transform_value as Transform3D):
		return false
	match state:
		STATE_HIDDEN:
			return not bool(visible_value) \
				and slot_id.is_empty() \
				and operator_peer_id == 0 \
				and drag_token == 0
		STATE_FLOATING:
			return bool(visible_value) \
				and slot_id.is_empty() \
				and operator_peer_id == 0 \
				and drag_token == 0
		STATE_DRAGGING:
			return bool(visible_value) \
				and slot_id.is_empty() \
				and operator_peer_id > 0 \
				and drag_token > 0
		STATE_SNAPPED:
			return bool(visible_value) \
				and not slot_id.is_empty() \
				and _get_dock_slot(slot_id) != null \
				and operator_peer_id == 0 \
				and drag_token == 0
	return false


func _validate_config(config: Dictionary) -> bool:
	var window_id := str(config.get("window_id", "")).strip_edges()
	if window_id.is_empty() or window_id.length() > MAX_WINDOW_ID_LENGTH:
		return false
	var size_value = config.get("size_m", null)
	var base_scale_value = config.get("base_scale", null)
	return size_value is Vector2 \
		and _is_finite_vector2(size_value as Vector2) \
		and (size_value as Vector2).x > 0.0 \
		and (size_value as Vector2).y > 0.0 \
		and base_scale_value is Vector3 \
		and _is_finite_vector(base_scale_value as Vector3) \
		and (base_scale_value as Vector3).x > 0.0 \
		and (base_scale_value as Vector3).y > 0.0 \
		and (base_scale_value as Vector3).z > 0.0


func _get_operation_error(
	sender_id: int,
	request_sequence: int,
	window_id: StringName
) -> String:
	if not multiplayer.is_server():
		return "当前节点不是共享窗口 Server。"
	if not _window_configs.has(window_id):
		return "窗口编号未在生产场景中注册。"
	if sender_id != SERVER_PEER_ID:
		if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
			return "窗口请求发送者无效。"
		var authority := _get_peer_authority()
		if authority == null \
			or not authority.has_method("can_peer_control_shared_windows") \
			or not bool(authority.call("can_peer_control_shared_windows", sender_id)):
			return "当前端没有共享窗口控制权限。"
	if request_sequence <= 0:
		return "窗口请求序号无效。"
	var previous := int(_server_operation_sequence_by_peer.get(sender_id, 0))
	if request_sequence <= previous:
		return "窗口请求已处理或已过期。"
	_server_operation_sequence_by_peer[sender_id] = request_sequence
	return ""


func _get_preview_error(
	sender_id: int,
	window_id: StringName,
	drag_token: int,
	drag_sequence: int,
	shared_transform: Transform3D
) -> String:
	if not multiplayer.is_server() or not _window_configs.has(window_id):
		return "拖拽预览窗口无效。"
	if sender_id != SERVER_PEER_ID:
		if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
			return "拖拽预览发送者无效。"
		var authority := _get_peer_authority()
		if authority == null \
			or not authority.has_method("can_peer_control_shared_windows") \
			or not bool(authority.call("can_peer_control_shared_windows", sender_id)):
			return "拖拽预览发送者没有权限。"
	var lock_error := _get_drag_lock_error(
		sender_id,
		window_id,
		drag_token,
		drag_sequence
	)
	if not lock_error.is_empty():
		return lock_error
	var transform_error := _get_transform_error(
		sender_id,
		window_id,
		shared_transform
	)
	if not transform_error.is_empty():
		return transform_error
	var key := "%d:%s" % [sender_id, window_id]
	var previous_msec := int(_server_preview_msec_by_drag.get(
		key,
		-DRAG_PREVIEW_MIN_INTERVAL_MSEC
	))
	if Time.get_ticks_msec() - previous_msec < DRAG_PREVIEW_MIN_INTERVAL_MSEC:
		return "拖拽预览更新过于频繁。"
	return ""


func _get_drag_lock_error(
	sender_id: int,
	window_id: StringName,
	drag_token: int,
	drag_sequence: int
) -> String:
	if not _active_drags.has(window_id):
		return "窗口没有活动拖拽锁。"
	var active := _active_drags[window_id] as Dictionary
	if int(active.get("peer_id", 0)) != sender_id \
		or int(active.get("token", 0)) != drag_token:
		return "窗口拖拽锁不属于当前发送者。"
	if drag_sequence <= int(active.get("last_sequence", 0)):
		return "窗口拖拽更新已处理或乱序。"
	return ""


func _get_transform_error(
	sender_id: int,
	window_id: StringName,
	shared_transform: Transform3D
) -> String:
	if not _validate_transform_for_window(window_id, shared_transform):
		return "窗口 Transform 非法或超出比例/空间范围。"
	if sender_id != SERVER_PEER_ID and require_remote_interaction_pose:
		var interaction_distance := _get_sender_interaction_distance(
			sender_id,
			shared_transform
		)
		if interaction_distance > MAX_INTERACTION_DISTANCE_M:
			return "窗口超出操作者允许的交互距离（Server 距离 %.2f 米）。" % interaction_distance
	return ""


func _get_slot_error(window_id: StringName, slot_id: StringName) -> String:
	if slot_id.is_empty():
		return ""
	if str(slot_id).length() > MAX_SLOT_ID_LENGTH:
		return "窗口槽位编号过长。"
	var slot := _get_dock_slot(slot_id)
	if slot == null:
		return "窗口请求了不存在的吸附槽位。"
	var config := _window_configs[window_id] as Dictionary
	if not bool(slot.call(
		"can_accept",
		window_id,
		StringName(str(config.get("category", ""))),
		config.get("size_m", Vector2.ZERO)
	)):
		return "窗口与吸附槽位类型、尺寸或占用状态不兼容。"
	var dock_manager := _get_dock_manager()
	if dock_manager != null:
		var occupant := StringName(dock_manager.call("get_slot_occupant", slot_id))
		if not occupant.is_empty() and occupant != window_id:
			return "吸附槽位已被另一窗口占用。"
	return ""


func _validate_transform_for_window(
	window_id: StringName,
	value: Transform3D
) -> bool:
	if not _window_configs.has(window_id) \
		or not _is_finite_vector(value.origin) \
		or value.origin.length() > MAX_SHARED_ORIGIN_DISTANCE_M \
		or not _is_finite_vector(value.basis.x) \
		or not _is_finite_vector(value.basis.y) \
		or not _is_finite_vector(value.basis.z):
		return false
	var scale_value := value.basis.get_scale()
	var base_scale := (_window_configs[window_id] as Dictionary).get(
		"base_scale",
		Vector3.ONE
	) as Vector3
	for axis in range(3):
		var base_component := base_scale[axis]
		var ratio := scale_value[axis] / base_component if base_component > 0.0 else INF
		if ratio < MIN_SCALE_RATIO or ratio > MAX_SCALE_RATIO:
			return false
	var normalized := value.basis.orthonormalized()
	return absf(normalized.x.dot(normalized.y)) < 0.01 \
		and absf(normalized.x.dot(normalized.z)) < 0.01 \
		and absf(normalized.y.dot(normalized.z)) < 0.01 \
		and absf(value.basis.determinant()) > 0.000000000001


func _get_sender_interaction_distance(
	sender_id: int,
	shared_transform: Transform3D
) -> float:
	var shared_origin := _get_shared_origin()
	if shared_origin == null:
		return INF
	var player := _find_player(sender_id)
	if player == null:
		return INF
	if player.has_method("has_received_network_pose") \
			and not bool(player.call("has_received_network_pose")):
		return INF
	var viewpoint: Node3D = player.call("get_network_viewpoint") as Node3D \
		if player.has_method("get_network_viewpoint") else null
	if viewpoint == null:
		return INF
	var global_position := (shared_origin.global_transform * shared_transform).origin
	return viewpoint.global_position.distance_to(global_position)


func _find_player(peer_id: int) -> Node:
	var shared_origin := _get_shared_origin()
	if shared_origin != null and shared_origin.get_parent() != null:
		var shared_world_player := shared_origin.get_parent().get_node_or_null(str(peer_id))
		if shared_world_player != null:
			return shared_world_player
	var scene := get_tree().current_scene
	if scene != null:
		var direct := scene.get_node_or_null(str(peer_id))
		if direct != null:
			return direct
		var recursive := scene.find_child(str(peer_id), true, false)
		if recursive != null:
			return recursive
	return null


func _canonicalize_slot_transform(
	window_id: StringName,
	slot_id: StringName,
	fallback: Transform3D
) -> Transform3D:
	if slot_id.is_empty():
		return fallback
	var dock_manager := _get_dock_manager()
	var shared_origin := _get_shared_origin()
	var config: Dictionary = _window_configs.get(window_id, {})
	if dock_manager == null or shared_origin == null or config.is_empty():
		return fallback
	var global_snap: Transform3D = dock_manager.call(
		"get_snap_transform",
		slot_id,
		config.get("base_scale", Vector3.ONE),
		config.get("size_m", Vector2.ZERO)
	)
	return shared_origin.global_transform.affine_inverse() * global_snap


func _reconcile_window_occupancy(
	window_id: StringName,
	slot_id: StringName
) -> void:
	var dock_manager := _get_dock_manager()
	if dock_manager == null:
		return
	dock_manager.call("release_window", window_id)
	if not slot_id.is_empty():
		dock_manager.call("apply_authoritative_occupancy", slot_id, window_id)


func _release_manager_window(window_id: StringName) -> void:
	var dock_manager := _get_dock_manager()
	if dock_manager != null:
		dock_manager.call("release_window", window_id)


func _make_initial_record(controller: Node) -> Dictionary:
	var visible_value := bool(controller.call("is_window_open"))
	var state := int(controller.call("get_state"))
	if not visible_value:
		state = STATE_HIDDEN
	elif state not in [STATE_FLOATING, STATE_SNAPPED]:
		state = STATE_FLOATING
	var slot_id := StringName(str(controller.call("get_current_slot_id")))
	if state != STATE_SNAPPED:
		slot_id = &""
	return {
		"window_id": str(controller.call("get_window_id")),
		"revision": 0,
		"visible": visible_value,
		"state": state,
		"transform": controller.call("get_shared_transform") as Transform3D,
		"slot_id": str(slot_id),
		"operator_peer_id": 0,
		"drag_token": 0,
	}


func _reject_remote(
	sender_id: int,
	operation: String,
	window_id: StringName,
	message: String
) -> bool:
	if warn_on_rejection:
		push_warning(message)
	operation_failed.emit(operation, window_id, message)
	if sender_id > SERVER_PEER_ID \
		and multiplayer.has_multiplayer_peer() \
		and sender_id in multiplayer.get_peers():
		rpc_id(
			sender_id,
			"_rpc_window_operation_failed",
			operation,
			window_id,
			message,
			get_window_state(window_id)
		)
	return false


func _can_local_control(window_id: StringName) -> bool:
	if not _window_configs.has(window_id):
		return false
	if multiplayer.is_server():
		return true
	if not _is_connected_client():
		return false
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


func _get_dock_manager() -> Node:
	return get_node_or_null(dock_manager_path) if not dock_manager_path.is_empty() else null


func _get_dock_slot(slot_id: StringName) -> Node:
	var manager := _get_dock_manager()
	return manager.call("get_slot", slot_id) as Node if manager != null else null


func _get_shared_origin() -> Node3D:
	return get_node_or_null(shared_space_origin_path) as Node3D \
		if not shared_space_origin_path.is_empty() else null


func _is_connected_client() -> bool:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return false
	var active_peer := multiplayer.multiplayer_peer
	return active_peer != null \
		and active_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _take_client_operation_sequence() -> int:
	var sequence := _next_client_operation_sequence
	_next_client_operation_sequence += 1
	return sequence


func _take_client_drag_token() -> int:
	var token := _next_client_drag_token
	_next_client_drag_token += 1
	return token


func _on_connected_to_server() -> void:
	_reset_client_session_state()
	call_deferred("request_window_snapshot")


func _on_peer_disconnected(peer_id: int) -> void:
	_server_snapshot_request_msec_by_peer.erase(peer_id)
	_server_operation_sequence_by_peer.erase(peer_id)
	var interrupted: Array[StringName] = []
	for window_id_value in _active_drags.keys():
		var window_id := StringName(window_id_value)
		var active := _active_drags[window_id] as Dictionary
		if int(active.get("peer_id", 0)) == peer_id:
			interrupted.append(window_id)
	for window_id in interrupted:
		var active := _active_drags[window_id] as Dictionary
		_active_drags.erase(window_id)
		var record := get_window_state(window_id)
		record["state"] = STATE_FLOATING
		record["transform"] = active.get("last_transform", record.get("transform"))
		record["slot_id"] = ""
		record["operator_peer_id"] = 0
		record["drag_token"] = 0
		_commit_record(record)
	var key_prefix := "%d:" % peer_id
	for key in _server_preview_sequence_by_drag.keys():
		if str(key).begins_with(key_prefix):
			_server_preview_sequence_by_drag.erase(key)
			_server_preview_msec_by_drag.erase(key)


func _reset_client_session_state() -> void:
	for window_id_value in _window_configs.keys():
		_release_manager_window(StringName(window_id_value))
	_window_states.clear()
	_active_drags.clear()
	_state_revision = 0
	_next_client_operation_sequence = 1
	_next_client_drag_token = 1
	_snapshot_request_pending = false
	_last_snapshot_request_msec = -SNAPSHOT_REQUEST_RETRY_MSEC


func _request_initial_snapshot() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		request_window_snapshot()


func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
