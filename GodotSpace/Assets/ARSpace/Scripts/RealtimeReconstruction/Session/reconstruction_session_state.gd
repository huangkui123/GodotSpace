extends Node

## Server-authoritative lifecycle for one realtime reconstruction source.
##
## The PC Server owns every transition. Sky clients may submit lifecycle
## requests, while Ground VR clients are intentionally view-only. Expensive
## work (preflight checks, solving, persistence and point-cloud transport) is
## performed by integration services that consume the hook signals below and
## report completion through the server_mark_* methods.

const SERVER_PEER_ID: int = 1
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"
const ROLE_UNKNOWN: String = "unknown"

const STATE_IDLE: int = 0
const STATE_PREFLIGHT: int = 1
const STATE_COLLECTING: int = 2
const STATE_SOLVING: int = 3
const STATE_PREVIEW: int = 4
const STATE_LIVE: int = 5
const STATE_STOPPED: int = 6
const STATE_IMPORTING: int = 7
const STATE_ERROR: int = 8

const ACTION_START: StringName = &"start"
const ACTION_STOP: StringName = &"stop"
const ACTION_RETRY: StringName = &"retry"
const ACTION_CONFIRM: StringName = &"confirm"
const ACTION_RESET: StringName = &"reset"
const ACTION_IMPORT: StringName = &"import"
const ACTION_EXPORT: StringName = &"export"
const ACTION_PREFLIGHT_READY: StringName = &"preflight_ready"
const ACTION_COLLECTION_COMPLETE: StringName = &"collection_complete"
const ACTION_SOLVE_COMPLETE: StringName = &"solve_complete"
const ACTION_IMPORT_READY: StringName = &"import_ready"
const ACTION_MAP_UPDATED: StringName = &"map_updated"
const ACTION_REPORT_ERROR: StringName = &"report_error"

const CLIENT_ACTIONS: Array[StringName] = [
	ACTION_START,
	ACTION_STOP,
	ACTION_RETRY,
	ACTION_CONFIRM,
	ACTION_RESET,
	ACTION_IMPORT,
	ACTION_EXPORT,
]
const VALID_STATES: Array[int] = [
	STATE_IDLE,
	STATE_PREFLIGHT,
	STATE_COLLECTING,
	STATE_SOLVING,
	STATE_PREVIEW,
	STATE_LIVE,
	STATE_STOPPED,
	STATE_IMPORTING,
	STATE_ERROR,
]
const SNAPSHOT_SCHEMA_VERSION: int = 2
const SNAPSHOT_REQUEST_RETRY_MSEC: int = 500
const SERVER_SNAPSHOT_MIN_INTERVAL_MSEC: int = 250
const MAX_IDENTIFIER_LENGTH: int = 128
const MAX_ERROR_CODE_LENGTH: int = 64
const MAX_ERROR_MESSAGE_LENGTH: int = 512
const MAX_PAYLOAD_JSON_LENGTH: int = 4096

signal state_changed(state: int, previous_state: int)
signal snapshot_changed(snapshot: Dictionary)
signal snapshot_applied(snapshot: Dictionary)
signal session_changed(session_id: String)
signal map_version_changed(map_version: int)
signal map_availability_changed(has_published_map: bool)
signal sky_source_changed(peer_id: int)
signal operation_rejected(action: StringName, message: String)

# Integration hooks. Receivers must run on the PC Server.
signal preflight_requested(session_id: String, source_peer_id: int, options: Dictionary)
signal collection_started(session_id: String)
signal solve_requested(session_id: String)
signal preview_ready(session_id: String, preview_info: Dictionary)
signal live_started(session_id: String, map_version: int)
signal reconstruction_stopped(session_id: String, map_version: int)
signal map_reset_requested(previous_session_id: String, map_version: int)
signal import_requested(session_id: String, map_id: String)
signal export_requested(session_id: String, suggested_name: String, map_version: int)
signal error_reported(session_id: String, error_code: String, message: String)

@export var peer_authority_path: NodePath = NodePath("/root/NetworkHandler")
@export var warn_on_rejection: bool = true

var _state: int = STATE_IDLE
var _state_revision: int = 0
var _map_version: int = 0
var _has_published_map: bool = false
var _session_id: String = ""
var _sky_source_peer_id: int = 0
var _error_code: String = ""
var _error_message: String = ""
var _error_retry_state: int = STATE_PREFLIGHT
var _active_import_map_id: String = ""
var _session_counter: int = 0
var _session_is_imported: bool = false

var _next_client_request_sequence: int = 1
var _snapshot_request_pending: bool = false
var _last_snapshot_request_msec: int = -SNAPSHOT_REQUEST_RETRY_MSEC
var _server_request_sequence_by_peer: Dictionary = {}
var _server_snapshot_request_msec_by_peer: Dictionary = {}
var _last_rejection_message: String = ""


func _ready() -> void:
	add_to_group("reconstruction_session_state")
	add_to_group("reconstruction_session_controller")
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


func get_state() -> int:
	return _state


func get_state_name() -> String:
	return state_name(_state)


func get_state_revision() -> int:
	return _state_revision


func get_map_version() -> int:
	return _map_version


func has_published_map() -> bool:
	return _has_published_map


func get_session_id() -> String:
	return _session_id


func get_sky_source_peer_id() -> int:
	return _sky_source_peer_id


func get_error_code() -> String:
	return _error_code


func get_error_message() -> String:
	return _error_message


func is_imported_session() -> bool:
	return _session_is_imported


func get_snapshot() -> Dictionary:
	return {
		"schema_version": SNAPSHOT_SCHEMA_VERSION,
		"session_id": _session_id,
		"state": _state,
		"state_name": state_name(_state),
		"state_revision": _state_revision,
		"map_version": _map_version,
		"has_published_map": _has_published_map,
		"sky_source_peer_id": _sky_source_peer_id,
		"error_code": _error_code,
		"error_message": _error_message,
		"error_retry_state": _error_retry_state,
		"active_import_map_id": _active_import_map_id,
		"session_is_imported": _session_is_imported,
	}


func request_start(options: Dictionary = {}) -> bool:
	return _request_action(ACTION_START, options)


func request_stop() -> bool:
	return _request_action(ACTION_STOP, {})


func request_retry() -> bool:
	return _request_action(ACTION_RETRY, {})


func request_confirm() -> bool:
	return _request_action(ACTION_CONFIRM, {})


func request_reset() -> bool:
	return _request_action(ACTION_RESET, {"confirmed": true})


func request_import(map_id: String) -> bool:
	return _request_action(ACTION_IMPORT, {"map_id": map_id})


func request_export(suggested_name: String) -> bool:
	return _request_action(ACTION_EXPORT, {"suggested_name": suggested_name})


func request_snapshot() -> bool:
	if not _is_connected_client():
		return false
	_snapshot_request_pending = true
	_last_snapshot_request_msec = Time.get_ticks_msec()
	rpc_id(SERVER_PEER_ID, "_server_request_reconstruction_snapshot")
	return true


func server_mark_preflight_ready() -> bool:
	return _apply_server_hook(ACTION_PREFLIGHT_READY, {})


func server_mark_collection_complete() -> bool:
	return _apply_server_hook(ACTION_COLLECTION_COMPLETE, {})


func server_mark_solve_complete(preview_info: Dictionary = {}) -> bool:
	return _apply_server_hook(ACTION_SOLVE_COMPLETE, {"preview_info": preview_info})


func server_mark_import_ready(map_id: String, preview_info: Dictionary = {}) -> bool:
	return _apply_server_hook(ACTION_IMPORT_READY, {
		"map_id": map_id,
		"preview_info": preview_info,
	})


func server_note_map_update() -> bool:
	return _apply_server_hook(ACTION_MAP_UPDATED, {})


func server_report_error(error_code: String, message: String) -> bool:
	return _apply_server_hook(ACTION_REPORT_ERROR, {
		"error_code": error_code,
		"message": message,
	})


## Pure authoritative transition entry point. It deliberately remains usable
## without a MultiplayerPeer so the lifecycle can be verified headlessly.
## With a MultiplayerPeer present it only runs on the Server.
func apply_authoritative_action(
	action: StringName,
	payload: Dictionary,
	actor_role: String,
	actor_peer_id: int,
	expected_state_revision: int = -1
) -> bool:
	if not _is_authoritative_context():
		return _reject(action, "只有 PC Server 可以提交重建状态。")
	if expected_state_revision >= 0 and expected_state_revision != _state_revision:
		return _reject(action, "重建状态已更新，请刷新后重试。")
	if not _validate_action_payload(action, payload):
		return _reject(action, "重建请求参数无效。")
	if not _is_action_permitted(action, actor_role, actor_peer_id):
		return _reject(action, "当前角色没有执行该重建操作的权限。")
	return _apply_transition(action, payload, actor_peer_id, actor_role)


func validate_snapshot(snapshot: Dictionary) -> bool:
	var required_keys: Array[String] = [
		"schema_version",
		"session_id",
		"state",
		"state_name",
		"state_revision",
		"map_version",
		"has_published_map",
		"sky_source_peer_id",
		"error_code",
		"error_message",
		"error_retry_state",
		"active_import_map_id",
		"session_is_imported",
	]
	for key in required_keys:
		if not snapshot.has(key):
			return false
	if typeof(snapshot["schema_version"]) != TYPE_INT \
			or int(snapshot["schema_version"]) != SNAPSHOT_SCHEMA_VERSION:
		return false
	if typeof(snapshot["state"]) != TYPE_INT \
			or int(snapshot["state"]) not in VALID_STATES:
		return false
	if typeof(snapshot["state_name"]) != TYPE_STRING \
			or str(snapshot["state_name"]) != state_name(int(snapshot["state"])):
		return false
	if typeof(snapshot["state_revision"]) != TYPE_INT \
			or int(snapshot["state_revision"]) < 0:
		return false
	if typeof(snapshot["map_version"]) != TYPE_INT \
			or int(snapshot["map_version"]) < 0:
		return false
	if typeof(snapshot["has_published_map"]) != TYPE_BOOL:
		return false
	if typeof(snapshot["session_is_imported"]) != TYPE_BOOL:
		return false
	if typeof(snapshot["sky_source_peer_id"]) != TYPE_INT \
			or int(snapshot["sky_source_peer_id"]) < 0:
		return false
	if typeof(snapshot["error_retry_state"]) != TYPE_INT \
			or int(snapshot["error_retry_state"]) not in [STATE_PREFLIGHT, STATE_IMPORTING]:
		return false
	if typeof(snapshot["session_id"]) != TYPE_STRING \
			or typeof(snapshot["error_code"]) != TYPE_STRING \
			or typeof(snapshot["error_message"]) != TYPE_STRING \
			or typeof(snapshot["active_import_map_id"]) != TYPE_STRING:
		return false
	var session_id := str(snapshot["session_id"])
	var error_code := str(snapshot["error_code"])
	var error_message := str(snapshot["error_message"])
	var active_import_map_id := str(snapshot["active_import_map_id"])
	if not _is_bounded_text(session_id, MAX_IDENTIFIER_LENGTH, true) \
			or not _is_bounded_text(error_code, MAX_ERROR_CODE_LENGTH, true) \
			or not _is_bounded_text(error_message, MAX_ERROR_MESSAGE_LENGTH, true) \
			or not _is_bounded_text(active_import_map_id, MAX_IDENTIFIER_LENGTH, true):
		return false
	var snapshot_state := int(snapshot["state"])
	var source_peer_id := int(snapshot["sky_source_peer_id"])
	if snapshot_state == STATE_IDLE:
		return session_id.is_empty() \
			and source_peer_id == 0 \
			and not bool(snapshot["has_published_map"]) \
			and not bool(snapshot["session_is_imported"])
	return not session_id.is_empty() and source_peer_id > SERVER_PEER_ID


static func state_name(state: int) -> String:
	match state:
		STATE_IDLE:
			return "idle"
		STATE_PREFLIGHT:
			return "preflight"
		STATE_COLLECTING:
			return "collecting"
		STATE_SOLVING:
			return "solving"
		STATE_PREVIEW:
			return "preview"
		STATE_LIVE:
			return "live"
		STATE_STOPPED:
			return "stopped"
		STATE_IMPORTING:
			return "importing"
		STATE_ERROR:
			return "error"
	return "unknown"


func _request_action(action: StringName, payload: Dictionary) -> bool:
	if not _validate_action_payload(action, payload):
		return _reject(action, "重建请求参数无效。")
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return apply_authoritative_action(
			action,
			payload,
			_get_local_role(),
			_get_safe_local_peer_id(),
			_state_revision
		)
	if not _is_connected_client() or _get_local_role() != ROLE_SKY:
		return _reject(action, "只有天上端可以请求该重建操作。")
	var request_sequence := _next_client_request_sequence
	_next_client_request_sequence += 1
	print(
		"Realtime reconstruction request submitted: action=%s sequence=%d revision=%d peer=%d"
		% [action, request_sequence, _state_revision, _get_safe_local_peer_id()]
	)
	rpc_id(
		SERVER_PEER_ID,
		"_server_request_reconstruction_action",
		request_sequence,
		_state_revision,
		action,
		payload
	)
	return true


func _apply_server_hook(action: StringName, payload: Dictionary) -> bool:
	if not _is_authoritative_context():
		return _reject(action, "重建完成回调只能在 PC Server 上执行。")
	return apply_authoritative_action(
		action,
		payload,
		ROLE_PC_GROUND,
		SERVER_PEER_ID,
		_state_revision
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_reconstruction_action(
	request_sequence: int,
	expected_state_revision: int,
	action: StringName,
	payload: Dictionary
) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var basic_error := _get_remote_request_error(
		sender_id,
		request_sequence,
		expected_state_revision,
		action,
		payload
	)
	if not basic_error.is_empty():
		_reject_remote(sender_id, action, basic_error)
		return
	print(
		"Realtime reconstruction request received: action=%s sequence=%d revision=%d peer=%d"
		% [action, request_sequence, expected_state_revision, sender_id]
	)
	_server_request_sequence_by_peer[sender_id] = request_sequence
	var role := _get_peer_role(sender_id)
	if not apply_authoritative_action(
		action,
		payload,
		role,
		sender_id,
		expected_state_revision
	):
		_reject_remote(sender_id, action, _last_rejection_message)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_reconstruction_snapshot() -> void:
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
func _rpc_receive_reconstruction_snapshot(snapshot: Dictionary) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if not validate_snapshot(snapshot):
		request_snapshot()
		return
	var revision := int(snapshot["state_revision"])
	if revision < _state_revision:
		return
	_apply_snapshot(snapshot, true)
	_snapshot_request_pending = false
	snapshot_applied.emit(get_snapshot())


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_reconstruction_operation_failed(action: StringName, message: String) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	var safe_message := message.left(MAX_ERROR_MESSAGE_LENGTH)
	operation_rejected.emit(action, safe_message)
	request_snapshot()


func _get_remote_request_error(
	sender_id: int,
	request_sequence: int,
	expected_state_revision: int,
	action: StringName,
	payload: Dictionary
) -> String:
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return "重建请求发送者无效。"
	if request_sequence <= 0:
		return "重建请求序号无效。"
	var previous_sequence := int(_server_request_sequence_by_peer.get(sender_id, 0))
	if request_sequence <= previous_sequence:
		return "重建请求已处理或已过期。"
	if expected_state_revision < 0:
		return "重建状态版本无效。"
	if action not in CLIENT_ACTIONS or not _validate_action_payload(action, payload):
		return "重建请求参数无效。"
	if _get_peer_role(sender_id) != ROLE_SKY:
		return "只有已注册的天上端可以控制重建会话。"
	return ""


func _apply_transition(
	action: StringName,
	payload: Dictionary,
	actor_peer_id: int,
	actor_role: String
) -> bool:
	match action:
		ACTION_START:
			if _state not in [STATE_IDLE, STATE_STOPPED]:
				return _reject(action, "当前状态不能开始新的重建会话。")
			var start_source_peer_id := _resolve_sky_source_peer_id(
				actor_peer_id,
				actor_role
			)
			if start_source_peer_id <= SERVER_PEER_ID:
				return _reject(action, "开始重建前必须有已注册的天上端。")
			var start_previous_snapshot := get_snapshot()
			if _state == STATE_STOPPED and _has_published_map:
				_map_version += 1
				_has_published_map = false
			_begin_session(start_source_peer_id, false)
			_commit_state(STATE_PREFLIGHT, start_previous_snapshot)
			preflight_requested.emit(_session_id, _sky_source_peer_id, payload.duplicate(true))
			return true
		ACTION_PREFLIGHT_READY:
			if _state != STATE_PREFLIGHT:
				return _reject(action, "预检完成回调与当前状态不匹配。")
			_commit_state(STATE_COLLECTING)
			collection_started.emit(_session_id)
			return true
		ACTION_COLLECTION_COMPLETE:
			if _state != STATE_COLLECTING:
				return _reject(action, "采集完成回调与当前状态不匹配。")
			_commit_state(STATE_SOLVING)
			solve_requested.emit(_session_id)
			return true
		ACTION_SOLVE_COMPLETE:
			if _state != STATE_SOLVING:
				return _reject(action, "求解完成回调与当前状态不匹配。")
			_commit_state(STATE_PREVIEW)
			preview_ready.emit(_session_id, payload["preview_info"].duplicate(true))
			return true
		ACTION_CONFIRM:
			if _state != STATE_PREVIEW:
				return _reject(action, "只有预览中的地图可以确认发布。")
			var confirm_previous_snapshot := get_snapshot()
			_map_version += 1
			_has_published_map = true
			_commit_state(STATE_LIVE, confirm_previous_snapshot)
			live_started.emit(_session_id, _map_version)
			return true
		ACTION_STOP:
			if _state != STATE_LIVE:
				return _reject(action, "只有实时重建中的会话可以停止。")
			_commit_state(STATE_STOPPED)
			reconstruction_stopped.emit(_session_id, _map_version)
			return true
		ACTION_RETRY:
			if _state not in [
				STATE_PREFLIGHT,
				STATE_COLLECTING,
				STATE_SOLVING,
				STATE_PREVIEW,
				STATE_LIVE,
				STATE_ERROR,
			] or _session_id.is_empty():
				return _reject(action, "当前状态不能重新初始化。")
			if _session_is_imported and _state != STATE_ERROR:
				return _reject(
					action,
					"导入地图不连接原 LingBot 会话，不能重新采集或重新配准。",
				)
			var retry_previous_state := _state
			var retry_state := _error_retry_state \
				if retry_previous_state == STATE_ERROR else STATE_PREFLIGHT
			var restart_stream := (
				retry_previous_state == STATE_ERROR
				and retry_state == STATE_PREFLIGHT
			)
			var retry_previous_snapshot := get_snapshot()
			if _has_published_map \
					and (retry_previous_state == STATE_LIVE or restart_stream):
				_map_version += 1
				_has_published_map = false
			_clear_error()
			_commit_state(retry_state, retry_previous_snapshot)
			if retry_state == STATE_IMPORTING:
				import_requested.emit(_session_id, _active_import_map_id)
			else:
				preflight_requested.emit(_session_id, _sky_source_peer_id, {
					"retry": true,
					"restart_stream": restart_stream,
				})
			return true
		ACTION_RESET:
			if not bool(payload["confirmed"]):
				return _reject(action, "清空地图需要明确确认。")
			if _state == STATE_IDLE:
				return _reject(action, "空闲状态没有可清空的重建会话。")
			var reset_previous_snapshot := get_snapshot()
			var previous_session_id := _session_id
			_map_version += 1
			_has_published_map = false
			_session_id = ""
			_sky_source_peer_id = 0
			_active_import_map_id = ""
			_session_is_imported = false
			_clear_error()
			_commit_state(STATE_IDLE, reset_previous_snapshot)
			map_reset_requested.emit(previous_session_id, _map_version)
			return true
		ACTION_IMPORT:
			if _state not in [STATE_IDLE, STATE_STOPPED]:
				return _reject(action, "当前状态不能导入地图。")
			var import_source_peer_id := _resolve_sky_source_peer_id(
				actor_peer_id,
				actor_role
			)
			if import_source_peer_id <= SERVER_PEER_ID:
				return _reject(action, "导入预览前必须有已注册的天上端。")
			var import_previous_snapshot := get_snapshot()
			if _has_published_map:
				_map_version += 1
				_has_published_map = false
			_begin_session(import_source_peer_id, true)
			_active_import_map_id = str(payload["map_id"])
			_commit_state(STATE_IMPORTING, import_previous_snapshot)
			import_requested.emit(_session_id, _active_import_map_id)
			return true
		ACTION_IMPORT_READY:
			if _state != STATE_IMPORTING:
				return _reject(action, "导入完成回调与当前状态不匹配。")
			if str(payload["map_id"]) != _active_import_map_id:
				return _reject(action, "导入完成回调的地图 ID 与当前请求不匹配。")
			_commit_state(STATE_PREVIEW)
			preview_ready.emit(_session_id, payload["preview_info"].duplicate(true))
			return true
		ACTION_EXPORT:
			if _state not in [STATE_LIVE, STATE_STOPPED]:
				return _reject(action, "只有已确认的地图可以导出。")
			export_requested.emit(
				_session_id,
				str(payload["suggested_name"]),
				_map_version
			)
			return true
		ACTION_MAP_UPDATED:
			if _state != STATE_LIVE:
				return _reject(action, "只有实时地图可以发布新版本。")
			var map_previous_snapshot := get_snapshot()
			_map_version += 1
			_commit_state(STATE_LIVE, map_previous_snapshot)
			return true
		ACTION_REPORT_ERROR:
			if _state == STATE_IDLE:
				return _reject(action, "空闲状态没有可失败的重建会话。")
			var error_previous_snapshot := get_snapshot()
			_error_retry_state = STATE_IMPORTING \
				if _state == STATE_IMPORTING else STATE_PREFLIGHT
			_error_code = str(payload["error_code"])
			_error_message = str(payload["message"])
			_commit_state(STATE_ERROR, error_previous_snapshot)
			error_reported.emit(_session_id, _error_code, _error_message)
			return true
	return _reject(action, "未知的重建操作。")


func _begin_session(source_peer_id: int, is_imported: bool = false) -> void:
	_session_counter += 1
	_session_id = "rr_%d_%d_%d_%d" % [
		int(Time.get_unix_time_from_system()),
		Time.get_ticks_msec(),
		source_peer_id,
		_session_counter,
	]
	_sky_source_peer_id = source_peer_id
	_active_import_map_id = ""
	_session_is_imported = is_imported
	_clear_error()


func _commit_state(next_state: int, previous_snapshot: Dictionary = {}) -> void:
	if previous_snapshot.is_empty():
		previous_snapshot = get_snapshot()
	var previous_state := _state
	if previous_snapshot.has("state"):
		previous_state = int(previous_snapshot["state"])
	_state = next_state
	_state_revision += 1
	print(
		"Realtime reconstruction state changed: %s -> %s revision=%d session=%s"
		% [
			state_name(previous_state),
			state_name(_state),
			_state_revision,
			_session_id,
		]
	)
	var current_snapshot := get_snapshot()
	_emit_snapshot_differences(previous_snapshot, current_snapshot, previous_state)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		rpc("_rpc_receive_reconstruction_snapshot", current_snapshot)


func _emit_snapshot_differences(
	previous_snapshot: Dictionary,
	current_snapshot: Dictionary,
	previous_state: int
) -> void:
	if _state != previous_state:
		state_changed.emit(_state, previous_state)
	if str(previous_snapshot["session_id"]) != _session_id:
		session_changed.emit(_session_id)
	if int(previous_snapshot["map_version"]) != _map_version:
		map_version_changed.emit(_map_version)
	if bool(previous_snapshot["has_published_map"]) != _has_published_map:
		map_availability_changed.emit(_has_published_map)
	if int(previous_snapshot["sky_source_peer_id"]) != _sky_source_peer_id:
		sky_source_changed.emit(_sky_source_peer_id)
	snapshot_changed.emit(current_snapshot.duplicate(true))


func _apply_snapshot(snapshot: Dictionary, force_emit: bool) -> void:
	var previous_snapshot := get_snapshot()
	var previous_state := _state
	_state = int(snapshot["state"])
	_state_revision = int(snapshot["state_revision"])
	_map_version = int(snapshot["map_version"])
	_has_published_map = bool(snapshot["has_published_map"])
	_session_id = str(snapshot["session_id"])
	_sky_source_peer_id = int(snapshot["sky_source_peer_id"])
	_error_code = str(snapshot["error_code"])
	_error_message = str(snapshot["error_message"])
	_error_retry_state = int(snapshot["error_retry_state"])
	_active_import_map_id = str(snapshot["active_import_map_id"])
	_session_is_imported = bool(snapshot["session_is_imported"])
	var changed := previous_snapshot != get_snapshot()
	if changed:
		_emit_snapshot_differences(previous_snapshot, get_snapshot(), previous_state)
	elif force_emit:
		snapshot_changed.emit(get_snapshot())


func _is_action_permitted(
	action: StringName,
	actor_role: String,
	actor_peer_id: int
) -> bool:
	if actor_role == ROLE_PC_GROUND and actor_peer_id == SERVER_PEER_ID:
		return true
	if actor_role != ROLE_SKY or actor_peer_id <= SERVER_PEER_ID:
		return false
	if action not in CLIENT_ACTIONS:
		return false
	return _sky_source_peer_id == 0 or _sky_source_peer_id == actor_peer_id


func _validate_action_payload(action: StringName, payload: Dictionary) -> bool:
	if JSON.stringify(payload).length() > MAX_PAYLOAD_JSON_LENGTH:
		return false
	match action:
		ACTION_START:
			if not _payload_has_only_keys(payload, ["label"]):
				return false
			return not payload.has("label") \
				or (
					typeof(payload["label"]) == TYPE_STRING
					and _is_bounded_text(
						str(payload["label"]),
						MAX_IDENTIFIER_LENGTH,
						true
					)
				)
		ACTION_STOP, ACTION_RETRY, ACTION_CONFIRM, ACTION_PREFLIGHT_READY, \
				ACTION_COLLECTION_COMPLETE, ACTION_MAP_UPDATED:
			return payload.is_empty()
		ACTION_RESET:
			return _payload_has_only_keys(payload, ["confirmed"]) \
				and typeof(payload.get("confirmed")) == TYPE_BOOL
		ACTION_IMPORT:
			return _payload_has_only_keys(payload, ["map_id"]) \
				and typeof(payload.get("map_id")) == TYPE_STRING \
				and _is_bounded_text(str(payload.get("map_id", "")), MAX_IDENTIFIER_LENGTH)
		ACTION_EXPORT:
			return _payload_has_only_keys(payload, ["suggested_name"]) \
				and typeof(payload.get("suggested_name")) == TYPE_STRING \
				and _is_bounded_text(
					str(payload.get("suggested_name", "")),
					MAX_IDENTIFIER_LENGTH
				)
		ACTION_SOLVE_COMPLETE:
			return _payload_has_only_keys(payload, ["preview_info"]) \
				and typeof(payload.get("preview_info")) == TYPE_DICTIONARY
		ACTION_IMPORT_READY:
			return _payload_has_only_keys(payload, ["map_id", "preview_info"]) \
				and typeof(payload.get("map_id")) == TYPE_STRING \
				and _is_bounded_text(
					str(payload.get("map_id", "")),
					MAX_IDENTIFIER_LENGTH
				) \
				and typeof(payload.get("preview_info")) == TYPE_DICTIONARY
		ACTION_REPORT_ERROR:
			return _payload_has_only_keys(payload, ["error_code", "message"]) \
				and typeof(payload.get("error_code")) == TYPE_STRING \
				and typeof(payload.get("message")) == TYPE_STRING \
				and _is_bounded_text(
					str(payload.get("error_code", "")),
					MAX_ERROR_CODE_LENGTH
				) \
				and _is_bounded_text(
					str(payload.get("message", "")),
					MAX_ERROR_MESSAGE_LENGTH
				)
	return false


func _payload_has_only_keys(payload: Dictionary, allowed_keys: Array[String]) -> bool:
	for key_value in payload:
		if typeof(key_value) != TYPE_STRING or str(key_value) not in allowed_keys:
			return false
	return true


func _is_bounded_text(value: String, max_length: int, allow_empty: bool = false) -> bool:
	if not allow_empty and value.strip_edges().is_empty():
		return false
	return value.length() <= max_length


func _is_authoritative_context() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func _get_local_role() -> String:
	var authority := _get_peer_authority()
	if authority != null and authority.has_method("get_local_assigned_role"):
		return str(authority.call("get_local_assigned_role"))
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return ROLE_PC_GROUND
	return ROLE_UNKNOWN


func _get_peer_role(peer_id: int) -> String:
	var authority := _get_peer_authority()
	if authority != null and authority.has_method("get_peer_role"):
		return str(authority.call("get_peer_role", peer_id))
	return ROLE_PC_GROUND if peer_id == SERVER_PEER_ID else ROLE_UNKNOWN


func _resolve_sky_source_peer_id(actor_peer_id: int, actor_role: String) -> int:
	if actor_role == ROLE_SKY and actor_peer_id > SERVER_PEER_ID:
		return actor_peer_id
	if actor_role != ROLE_PC_GROUND or actor_peer_id != SERVER_PEER_ID:
		return 0
	var authority := _get_peer_authority()
	if authority == null:
		return 0
	if authority.has_method("get_sky_peer_id"):
		var registered_sky_peer_id := int(authority.call("get_sky_peer_id"))
		if registered_sky_peer_id > SERVER_PEER_ID \
				and _get_peer_role(registered_sky_peer_id) == ROLE_SKY:
			return registered_sky_peer_id
	if authority.has_method("get_peer_roles"):
		var roles := authority.call("get_peer_roles") as Dictionary
		for peer_id_value in roles:
			var peer_id := int(peer_id_value)
			if peer_id > SERVER_PEER_ID and str(roles[peer_id_value]) == ROLE_SKY:
				return peer_id
	return 0


func _get_peer_authority() -> Node:
	return get_node_or_null(peer_authority_path) if not peer_authority_path.is_empty() else null


func _get_safe_local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return SERVER_PEER_ID
	return multiplayer.get_unique_id()


func _is_connected_client() -> bool:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return false
	var active_peer := multiplayer.multiplayer_peer
	return active_peer != null \
		and active_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _clear_error() -> void:
	_error_code = ""
	_error_message = ""
	_error_retry_state = STATE_PREFLIGHT


func _send_snapshot(peer_id: int) -> void:
	if peer_id <= SERVER_PEER_ID \
			or not multiplayer.has_multiplayer_peer() \
			or peer_id not in multiplayer.get_peers():
		return
	rpc_id(peer_id, "_rpc_receive_reconstruction_snapshot", get_snapshot())


func _reject_remote(sender_id: int, action: StringName, message: String) -> void:
	var safe_message := message.left(MAX_ERROR_MESSAGE_LENGTH)
	if warn_on_rejection:
		push_warning(safe_message)
	operation_rejected.emit(action, safe_message)
	if sender_id > SERVER_PEER_ID and sender_id in multiplayer.get_peers():
		rpc_id(
			sender_id,
			"_rpc_reconstruction_operation_failed",
			action,
			safe_message
		)
		_send_snapshot(sender_id)


func _reject(action: StringName, message: String) -> bool:
	_last_rejection_message = message.left(MAX_ERROR_MESSAGE_LENGTH)
	if warn_on_rejection:
		push_warning(_last_rejection_message)
	operation_rejected.emit(action, _last_rejection_message)
	return false


func _on_connected_to_server() -> void:
	_state = STATE_IDLE
	_state_revision = 0
	_map_version = 0
	_has_published_map = false
	_session_id = ""
	_sky_source_peer_id = 0
	_active_import_map_id = ""
	_session_is_imported = false
	_clear_error()
	_next_client_request_sequence = 1
	_snapshot_request_pending = false
	_last_snapshot_request_msec = -SNAPSHOT_REQUEST_RETRY_MSEC
	snapshot_changed.emit(get_snapshot())
	call_deferred("request_snapshot")


func _on_peer_disconnected(peer_id: int) -> void:
	_server_request_sequence_by_peer.erase(peer_id)
	_server_snapshot_request_msec_by_peer.erase(peer_id)
	if not multiplayer.is_server() or peer_id != _sky_source_peer_id:
		return
	if _state == STATE_LIVE:
		apply_authoritative_action(
			ACTION_STOP,
			{},
			ROLE_PC_GROUND,
			SERVER_PEER_ID,
			_state_revision
		)
	elif _state in [
		STATE_PREFLIGHT,
		STATE_COLLECTING,
		STATE_SOLVING,
		STATE_PREVIEW,
		STATE_IMPORTING,
	]:
		server_report_error("SKY_SOURCE_DISCONNECTED", "天上端已断开，重建会话无法继续。")


func _request_initial_snapshot() -> void:
	if _is_connected_client():
		request_snapshot()
