class_name SpatialDrawingManager
extends Node

signal stroke_added(stroke: Dictionary)
signal stroke_removed(stroke_id: int)
signal strokes_cleared()
signal operation_submitted(operation: String, request_sequence: int, local_id: int)
signal operation_completed(operation: String, request_sequence: int, local_id: int, stroke_id: int)
signal operation_failed(operation: String, request_sequence: int, local_id: int, message: String)
signal snapshot_applied(state_revision: int, stroke_count: int)
signal operation_rejected(message: String)

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const SERVER_PEER_ID: int = 1
const MAX_STROKES: int = 256
const MAX_POINTS_PER_STROKE: int = 2048
const POINTS_PER_CHUNK: int = 128
const MAX_CHUNKS_PER_STROKE: int = 16
const MIN_WIDTH_M: float = 0.002
const MAX_WIDTH_M: float = 0.05
const MAX_SHARED_COORDINATE_M: float = 100.0
const MAX_PENDING_STROKES_PER_PEER: int = 4
const MAX_PENDING_BYTES_PER_PEER: int = 64 * 1024
const MAX_SUBMISSIONS_PER_SECOND: int = 16
const PENDING_STROKE_TIMEOUT_MSEC: int = 10000
const SNAPSHOT_REQUEST_RETRY_MSEC: int = 500
const SERVER_SNAPSHOT_MIN_INTERVAL_MSEC: int = 250

@export_node_path("Node3D") var shared_space_origin_path: NodePath = NodePath("../..")
@export_node_path("Node") var renderer_path: NodePath = NodePath("../SpatialDrawingRenderer")
@export_node_path("Node") var peer_authority_path: NodePath = NodePath("/root/NetworkHandler")
@export var warn_on_rejection: bool = true

var _strokes: Dictionary = {}
var _state_revision: int = 0
var _next_stroke_id: int = 1
var _next_client_operation_sequence: int = 1
var _server_operation_sequence_by_peer: Dictionary = {}
var _server_submission_times_by_peer: Dictionary = {}
var _server_pending_submissions: Dictionary = {}
var _server_snapshot_request_msec_by_peer: Dictionary = {}
var _next_snapshot_id: int = 1
var _incoming_records: Dictionary = {}
var _incoming_snapshot: Dictionary = {}
var _pending_client_operations: Dictionary = {}
var _snapshot_request_pending: bool = false
var _last_snapshot_request_msec: int = -SNAPSHOT_REQUEST_RETRY_MSEC
var _last_cleanup_msec: int = 0
var _renderer: Node


func _ready() -> void:
	add_to_group("spatial_drawing_manager")
	_renderer = get_node_or_null(renderer_path)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	call_deferred("_request_initial_snapshot")


func _process(_delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if not multiplayer.is_server():
		return
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_cleanup_msec < 1000:
		return
	_last_cleanup_msec = now_msec
	for key in _server_pending_submissions.keys():
		var pending := _server_pending_submissions[key] as Dictionary
		if now_msec - int(pending.get("created_msec", now_msec)) > PENDING_STROKE_TIMEOUT_MSEC:
			_abort_server_submission(str(key), "空间笔画提交超时，未发布任何数据。")


func submit_drafts(drafts: Array) -> PackedInt32Array:
	var request_sequences := PackedInt32Array()
	if not can_local_draw():
		_reject("当前端没有空间绘制权限。")
		return request_sequences
	for draft_value in drafts:
		if not (draft_value is Dictionary):
			continue
		var draft := _normalize_draft(draft_value as Dictionary)
		if draft.is_empty():
			continue
		var local_id := int(draft.get("local_id", 0))
		if _is_server_authority():
			var stroke_id := _create_stroke_authoritative(draft, SERVER_PEER_ID)
			if stroke_id > 0:
				operation_completed.emit("submit", 0, local_id, stroke_id)
			continue
		if not _is_connected_client():
			_reject("尚未连接 PC 地面 Server。")
			break
		var request_sequence := _take_client_operation_sequence()
		request_sequences.append(request_sequence)
		_pending_client_operations[request_sequence] = {
			"operation": "submit",
			"local_id": local_id,
		}
		operation_submitted.emit("submit", request_sequence, local_id)
		_send_submission_to_server(request_sequence, draft)
	return request_sequences


func delete_stroke(stroke_id: int) -> bool:
	if not can_local_draw() or stroke_id <= 0:
		return false
	if _is_server_authority():
		var succeeded := _delete_stroke_authoritative(stroke_id, SERVER_PEER_ID)
		if succeeded:
			operation_completed.emit("delete", 0, 0, stroke_id)
		return succeeded
	if not _is_connected_client():
		return false
	var request_sequence := _take_client_operation_sequence()
	_pending_client_operations[request_sequence] = {
		"operation": "delete",
		"local_id": 0,
	}
	operation_submitted.emit("delete", request_sequence, 0)
	rpc_id(SERVER_PEER_ID, "_server_delete_stroke", request_sequence, stroke_id)
	return true


func request_clear_published() -> bool:
	if not can_local_draw():
		_reject("当前端没有同步清空空间笔画的权限。")
		return false
	if _is_server_authority():
		_clear_strokes_authoritative()
		operation_completed.emit("clear", 0, 0, 0)
		return true
	if not _is_connected_client():
		return false
	var request_sequence := _take_client_operation_sequence()
	_pending_client_operations[request_sequence] = {
		"operation": "clear",
		"local_id": 0,
	}
	operation_submitted.emit("clear", request_sequence, 0)
	rpc_id(SERVER_PEER_ID, "_server_clear_strokes", request_sequence)
	return true


func request_snapshot() -> void:
	if _is_server_authority() or not multiplayer.has_multiplayer_peer():
		return
	var active_peer := multiplayer.multiplayer_peer
	if active_peer == null \
			or active_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_snapshot_request_pending = true
		return
	var now_msec := Time.get_ticks_msec()
	if _snapshot_request_pending \
			and now_msec - _last_snapshot_request_msec < SNAPSHOT_REQUEST_RETRY_MSEC:
		return
	_snapshot_request_pending = true
	_last_snapshot_request_msec = now_msec
	rpc_id(SERVER_PEER_ID, "_server_request_drawing_snapshot")


func get_stroke(stroke_id: int) -> Dictionary:
	if not _strokes.has(stroke_id):
		return {}
	return (_strokes[stroke_id] as Dictionary).duplicate(true)


func get_strokes() -> Array:
	var result: Array = []
	var stroke_ids: Array = _strokes.keys()
	stroke_ids.sort()
	for stroke_id in stroke_ids:
		result.append((_strokes[stroke_id] as Dictionary).duplicate(true))
	return result


func get_stroke_count() -> int:
	return _strokes.size()


func get_state_revision() -> int:
	return _state_revision


func get_shared_space_origin() -> Node3D:
	return get_node_or_null(shared_space_origin_path) as Node3D


func can_local_draw() -> bool:
	if _is_server_authority():
		var profile = RuntimeProfile.current()
		if profile != null and profile.has_method("can_draw"):
			return bool(profile.call("can_draw"))
		return profile != null and profile.is_ground() and profile.uses_xr()
	if not _is_connected_client():
		return false
	var permission_service := _get_permission_service()
	if permission_service == null:
		return false
	if permission_service.has_method("get_local_assigned_role"):
		return str(permission_service.call("get_local_assigned_role")) in ["ground_vr", "sky"]
	if permission_service.has_method("can_peer_draw"):
		return bool(permission_service.call("can_peer_draw", multiplayer.get_unique_id()))
	return false


func validate_stroke_record(stroke: Dictionary) -> bool:
	if stroke.size() > 9:
		return false
	if int(stroke.get("stroke_id", 0)) <= 0:
		return false
	if int(stroke.get("creator_peer_id", 0)) <= 0:
		return false
	if int(stroke.get("revision", 0)) <= 0:
		return false
	if not bool(stroke.get("completed", false)):
		return false
	if not _is_valid_color(stroke.get("color")):
		return false
	var width_m := float(stroke.get("width_m", 0.0))
	if not is_finite(width_m) or width_m < MIN_WIDTH_M or width_m > MAX_WIDTH_M:
		return false
	var points_value = stroke.get("points")
	if not (points_value is PackedVector3Array):
		return false
	return _validate_points(points_value as PackedVector3Array)


func _send_submission_to_server(request_sequence: int, draft: Dictionary) -> void:
	var points: PackedVector3Array = draft.get("points", PackedVector3Array())
	var metadata := {
		"local_id": int(draft.get("local_id", 0)),
		"color": draft.get("color", Color.WHITE),
		"width_m": float(draft.get("width_m", 0.01)),
		"completed": true,
	}
	var chunk_count := ceili(float(points.size()) / float(POINTS_PER_CHUNK))
	rpc_id(
		SERVER_PEER_ID,
		"_server_begin_stroke_submission",
		request_sequence,
		metadata,
		points.size(),
		chunk_count
	)
	for chunk_index in range(chunk_count):
		var start := chunk_index * POINTS_PER_CHUNK
		var finish := mini(start + POINTS_PER_CHUNK, points.size())
		rpc_id(
			SERVER_PEER_ID,
			"_server_receive_stroke_chunk",
			request_sequence,
			chunk_index,
			points.slice(start, finish)
		)
	rpc_id(SERVER_PEER_ID, "_server_finish_stroke_submission", request_sequence)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_begin_stroke_submission(
	request_sequence: int,
	metadata: Dictionary,
	point_count: int,
	chunk_count: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var permission_error := _get_remote_operation_error(sender_id, request_sequence, true)
	var local_id := int(metadata.get("local_id", 0))
	if not permission_error.is_empty():
		_send_operation_result(sender_id, request_sequence, "submit", local_id, 0, false, permission_error)
		return
	var metadata_error := _get_submission_metadata_error(metadata, point_count, chunk_count)
	if not metadata_error.is_empty():
		_send_operation_result(sender_id, request_sequence, "submit", local_id, 0, false, metadata_error)
		return
	if _pending_submission_count(sender_id) >= MAX_PENDING_STROKES_PER_PEER:
		_send_operation_result(
			sender_id,
			request_sequence,
			"submit",
			local_id,
			0,
			false,
			"当前端有过多未完成的空间笔画提交。"
		)
		return
	var incoming_point_bytes := point_count * 3 * 4
	if _pending_submission_bytes(sender_id) + incoming_point_bytes > MAX_PENDING_BYTES_PER_PEER:
		_send_operation_result(
			sender_id,
			request_sequence,
			"submit",
			local_id,
			0,
			false,
			"当前端未完成的空间笔画数据量过大。"
		)
		return
	var key := _submission_key(sender_id, request_sequence)
	_server_pending_submissions[key] = {
		"sender_id": sender_id,
		"request_sequence": request_sequence,
		"local_id": local_id,
		"metadata": metadata.duplicate(true),
		"point_count": point_count,
		"point_bytes": incoming_point_bytes,
		"chunk_count": chunk_count,
		"chunks": {},
		"created_msec": Time.get_ticks_msec(),
	}


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_receive_stroke_chunk(
	request_sequence: int,
	chunk_index: int,
	points: PackedVector3Array
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var key := _submission_key(sender_id, request_sequence)
	if not _server_pending_submissions.has(key):
		return
	var pending := _server_pending_submissions[key] as Dictionary
	var chunk_count := int(pending.get("chunk_count", 0))
	if chunk_index < 0 \
			or chunk_index >= chunk_count \
			or points.is_empty() \
			or points.size() > POINTS_PER_CHUNK \
			or not _validate_chunk_points(points):
		_abort_server_submission(key, "空间笔画分块无效。")
		return
	var chunks := pending.get("chunks", {}) as Dictionary
	if chunks.has(chunk_index):
		_abort_server_submission(key, "空间笔画分块重复。")
		return
	chunks[chunk_index] = points.duplicate()
	pending["chunks"] = chunks
	_server_pending_submissions[key] = pending


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_finish_stroke_submission(request_sequence: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var key := _submission_key(sender_id, request_sequence)
	if not _server_pending_submissions.has(key):
		return
	var pending := _server_pending_submissions[key] as Dictionary
	_server_pending_submissions.erase(key)
	var points := _assemble_chunks(pending)
	var local_id := int(pending.get("local_id", 0))
	if points.size() != int(pending.get("point_count", -1)) or not _validate_points(points):
		_send_operation_result(
			sender_id,
			request_sequence,
			"submit",
			local_id,
			0,
			false,
			"空间笔画分块不完整或点数据无效。"
		)
		return
	var metadata := pending.get("metadata", {}) as Dictionary
	var draft := {
		"local_id": local_id,
		"points": points,
		"color": metadata.get("color", Color.WHITE),
		"width_m": float(metadata.get("width_m", 0.01)),
		"completed": true,
	}
	var stroke_id := _create_stroke_authoritative(draft, sender_id)
	_send_operation_result(
		sender_id,
		request_sequence,
		"submit",
		local_id,
		stroke_id,
		stroke_id > 0,
		"" if stroke_id > 0 else "空间笔画发布失败。"
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_delete_stroke(request_sequence: int, stroke_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var permission_error := _get_remote_operation_error(sender_id, request_sequence, false)
	if not permission_error.is_empty():
		_send_operation_result(sender_id, request_sequence, "delete", 0, stroke_id, false, permission_error)
		return
	var succeeded := _delete_stroke_authoritative(stroke_id, sender_id)
	_send_operation_result(
		sender_id,
		request_sequence,
		"delete",
		0,
		stroke_id,
		succeeded,
		"" if succeeded else "只能删除自己已经同步的空间笔画。"
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_clear_strokes(request_sequence: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var permission_error := _get_remote_operation_error(sender_id, request_sequence, false)
	if not permission_error.is_empty():
		_send_operation_result(sender_id, request_sequence, "clear", 0, 0, false, permission_error)
		return
	_clear_strokes_authoritative()
	_send_operation_result(sender_id, request_sequence, "clear", 0, 0, true, "")


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_receive_drawing_operation_result(
	request_sequence: int,
	operation: String,
	local_id: int,
	stroke_id: int,
	succeeded: bool,
	message: String
) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if request_sequence <= 0 or operation not in ["submit", "delete", "clear"]:
		return
	_pending_client_operations.erase(request_sequence)
	if succeeded:
		operation_completed.emit(operation, request_sequence, local_id, stroke_id)
		return
	var rejection_message := message if not message.is_empty() else "PC 地面 Server 拒绝了空间绘制操作。"
	_reject(rejection_message)
	operation_failed.emit(operation, request_sequence, local_id, rejection_message)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_drawing_snapshot() -> void:
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
	_send_snapshot(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_begin_stroke_record(
	server_revision: int,
	metadata: Dictionary,
	point_count: int,
	chunk_count: int
) -> void:
	if not _is_valid_server_sender():
		return
	var stroke_id := int(metadata.get("stroke_id", 0))
	if server_revision <= _state_revision \
			or stroke_id <= 0 \
			or _get_record_metadata_error(metadata, point_count, chunk_count) != "":
		return
	var key := _record_key(server_revision, stroke_id)
	_incoming_records[key] = {
		"server_revision": server_revision,
		"metadata": metadata.duplicate(true),
		"point_count": point_count,
		"chunk_count": chunk_count,
		"chunks": {},
	}


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_receive_stroke_record_chunk(
	server_revision: int,
	stroke_id: int,
	chunk_index: int,
	points: PackedVector3Array
) -> void:
	if not _is_valid_server_sender():
		return
	var key := _record_key(server_revision, stroke_id)
	if not _incoming_records.has(key):
		return
	var pending := _incoming_records[key] as Dictionary
	var chunks := pending.get("chunks", {}) as Dictionary
	if chunk_index < 0 \
			or chunk_index >= int(pending.get("chunk_count", 0)) \
			or chunks.has(chunk_index) \
			or points.is_empty() \
			or points.size() > POINTS_PER_CHUNK \
			or not _validate_chunk_points(points):
		_incoming_records.erase(key)
		request_snapshot()
		return
	chunks[chunk_index] = points.duplicate()
	pending["chunks"] = chunks
	_incoming_records[key] = pending


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_finish_stroke_record(server_revision: int, stroke_id: int) -> void:
	if not _is_valid_server_sender():
		return
	var key := _record_key(server_revision, stroke_id)
	if not _incoming_records.has(key):
		return
	var pending := _incoming_records[key] as Dictionary
	_incoming_records.erase(key)
	var points := _assemble_chunks(pending)
	var record := (pending.get("metadata", {}) as Dictionary).duplicate(true)
	record["points"] = points
	if points.size() != int(pending.get("point_count", -1)) \
			or not validate_stroke_record(record):
		request_snapshot()
		return
	if server_revision != _state_revision + 1:
		request_snapshot()
		return
	_apply_stroke_record(server_revision, record)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_delete_stroke(server_revision: int, stroke_id: int) -> void:
	if not _is_valid_server_sender() or server_revision <= _state_revision:
		return
	if server_revision != _state_revision + 1:
		request_snapshot()
		return
	_state_revision = server_revision
	_strokes.erase(stroke_id)
	_remove_rendered_stroke(stroke_id)
	stroke_removed.emit(stroke_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_clear_strokes(server_revision: int) -> void:
	if not _is_valid_server_sender() or server_revision <= _state_revision:
		return
	if server_revision != _state_revision + 1:
		request_snapshot()
		return
	_state_revision = server_revision
	_strokes.clear()
	_clear_rendered_strokes()
	strokes_cleared.emit()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_begin_drawing_snapshot(snapshot_id: int, server_revision: int, stroke_count: int) -> void:
	if not _is_valid_server_sender() \
			or snapshot_id <= 0 \
			or server_revision < _state_revision \
			or stroke_count < 0 \
			or stroke_count > MAX_STROKES:
		return
	_incoming_snapshot = {
		"snapshot_id": snapshot_id,
		"server_revision": server_revision,
		"stroke_count": stroke_count,
		"records": {},
		"pending": {},
	}


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_begin_snapshot_stroke(
	snapshot_id: int,
	metadata: Dictionary,
	point_count: int,
	chunk_count: int
) -> void:
	if not _snapshot_matches(snapshot_id):
		return
	var stroke_id := int(metadata.get("stroke_id", 0))
	if stroke_id <= 0 or _get_record_metadata_error(metadata, point_count, chunk_count) != "":
		_incoming_snapshot.clear()
		return
	var pending := _incoming_snapshot.get("pending", {}) as Dictionary
	if pending.has(stroke_id):
		_incoming_snapshot.clear()
		return
	pending[stroke_id] = {
		"metadata": metadata.duplicate(true),
		"point_count": point_count,
		"chunk_count": chunk_count,
		"chunks": {},
	}
	_incoming_snapshot["pending"] = pending


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_receive_snapshot_stroke_chunk(
	snapshot_id: int,
	stroke_id: int,
	chunk_index: int,
	points: PackedVector3Array
) -> void:
	if not _snapshot_matches(snapshot_id):
		return
	var pending_records := _incoming_snapshot.get("pending", {}) as Dictionary
	if not pending_records.has(stroke_id):
		return
	var pending := pending_records[stroke_id] as Dictionary
	var chunks := pending.get("chunks", {}) as Dictionary
	if chunk_index < 0 \
			or chunk_index >= int(pending.get("chunk_count", 0)) \
			or chunks.has(chunk_index) \
			or points.is_empty() \
			or points.size() > POINTS_PER_CHUNK \
			or not _validate_chunk_points(points):
		_incoming_snapshot.clear()
		return
	chunks[chunk_index] = points.duplicate()
	pending["chunks"] = chunks
	pending_records[stroke_id] = pending
	_incoming_snapshot["pending"] = pending_records


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_finish_snapshot_stroke(snapshot_id: int, stroke_id: int) -> void:
	if not _snapshot_matches(snapshot_id):
		return
	var pending_records := _incoming_snapshot.get("pending", {}) as Dictionary
	if not pending_records.has(stroke_id):
		_incoming_snapshot.clear()
		return
	var pending := pending_records[stroke_id] as Dictionary
	pending_records.erase(stroke_id)
	var record := (pending.get("metadata", {}) as Dictionary).duplicate(true)
	record["points"] = _assemble_chunks(pending)
	if (record["points"] as PackedVector3Array).size() != int(pending.get("point_count", -1)) \
			or not validate_stroke_record(record):
		_incoming_snapshot.clear()
		return
	var records := _incoming_snapshot.get("records", {}) as Dictionary
	records[stroke_id] = record
	_incoming_snapshot["records"] = records
	_incoming_snapshot["pending"] = pending_records


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_finish_drawing_snapshot(snapshot_id: int) -> void:
	if not _snapshot_matches(snapshot_id):
		return
	var snapshot := _incoming_snapshot.duplicate(true)
	_incoming_snapshot.clear()
	var records := snapshot.get("records", {}) as Dictionary
	var pending := snapshot.get("pending", {}) as Dictionary
	if not pending.is_empty() or records.size() != int(snapshot.get("stroke_count", -1)):
		request_snapshot()
		return
	_apply_snapshot(int(snapshot.get("server_revision", 0)), records)


func _create_stroke_authoritative(draft: Dictionary, creator_peer_id: int) -> int:
	if _strokes.size() >= MAX_STROKES:
		_reject("本次会话最多保留 %d 条空间笔画。" % MAX_STROKES)
		return -1
	var normalized := _normalize_draft(draft)
	if normalized.is_empty():
		return -1
	var stroke_id := _next_stroke_id
	_next_stroke_id += 1
	_state_revision += 1
	var record := {
		"stroke_id": stroke_id,
		"creator_peer_id": creator_peer_id,
		"revision": _state_revision,
		"points": normalized.get("points", PackedVector3Array()),
		"color": normalized.get("color", Color.WHITE),
		"width_m": normalized.get("width_m", 0.01),
		"created_at_msec": Time.get_ticks_msec(),
		"completed": true,
	}
	_strokes[stroke_id] = record
	_render_stroke(record)
	stroke_added.emit(record.duplicate(true))
	_broadcast_stroke(record)
	return stroke_id


func _delete_stroke_authoritative(stroke_id: int, requester_peer_id: int) -> bool:
	if not _strokes.has(stroke_id):
		return false
	var record := _strokes[stroke_id] as Dictionary
	if int(record.get("creator_peer_id", 0)) != requester_peer_id:
		return false
	_strokes.erase(stroke_id)
	_state_revision += 1
	_remove_rendered_stroke(stroke_id)
	stroke_removed.emit(stroke_id)
	for peer_id_value in multiplayer.get_peers():
		rpc_id(int(peer_id_value), "_rpc_delete_stroke", _state_revision, stroke_id)
	return true


func _clear_strokes_authoritative() -> void:
	if _strokes.is_empty():
		return
	_strokes.clear()
	_state_revision += 1
	_clear_rendered_strokes()
	strokes_cleared.emit()
	for peer_id_value in multiplayer.get_peers():
		rpc_id(int(peer_id_value), "_rpc_clear_strokes", _state_revision)


func _broadcast_stroke(record: Dictionary) -> void:
	for peer_id_value in multiplayer.get_peers():
		_send_record_to_peer(int(peer_id_value), record)


func _send_record_to_peer(peer_id: int, record: Dictionary) -> void:
	var points: PackedVector3Array = record.get("points", PackedVector3Array())
	var metadata := record.duplicate(true)
	metadata.erase("points")
	var chunk_count := ceili(float(points.size()) / float(POINTS_PER_CHUNK))
	var revision := int(record.get("revision", 0))
	var stroke_id := int(record.get("stroke_id", 0))
	rpc_id(peer_id, "_rpc_begin_stroke_record", revision, metadata, points.size(), chunk_count)
	for chunk_index in range(chunk_count):
		var start := chunk_index * POINTS_PER_CHUNK
		var finish := mini(start + POINTS_PER_CHUNK, points.size())
		rpc_id(
			peer_id,
			"_rpc_receive_stroke_record_chunk",
			revision,
			stroke_id,
			chunk_index,
			points.slice(start, finish)
		)
	rpc_id(peer_id, "_rpc_finish_stroke_record", revision, stroke_id)


func _send_snapshot(peer_id: int) -> void:
	var snapshot_id := _next_snapshot_id
	_next_snapshot_id += 1
	rpc_id(
		peer_id,
		"_rpc_begin_drawing_snapshot",
		snapshot_id,
		_state_revision,
		_strokes.size()
	)
	for record_value in get_strokes():
		var record := record_value as Dictionary
		var points: PackedVector3Array = record.get("points", PackedVector3Array())
		var metadata := record.duplicate(true)
		metadata.erase("points")
		var chunk_count := ceili(float(points.size()) / float(POINTS_PER_CHUNK))
		var stroke_id := int(record.get("stroke_id", 0))
		rpc_id(
			peer_id,
			"_rpc_begin_snapshot_stroke",
			snapshot_id,
			metadata,
			points.size(),
			chunk_count
		)
		for chunk_index in range(chunk_count):
			var start := chunk_index * POINTS_PER_CHUNK
			var finish := mini(start + POINTS_PER_CHUNK, points.size())
			rpc_id(
				peer_id,
				"_rpc_receive_snapshot_stroke_chunk",
				snapshot_id,
				stroke_id,
				chunk_index,
				points.slice(start, finish)
			)
		rpc_id(peer_id, "_rpc_finish_snapshot_stroke", snapshot_id, stroke_id)
	rpc_id(peer_id, "_rpc_finish_drawing_snapshot", snapshot_id)


func _apply_stroke_record(server_revision: int, record: Dictionary) -> void:
	var stroke_id := int(record.get("stroke_id", 0))
	_state_revision = server_revision
	_strokes[stroke_id] = record.duplicate(true)
	_next_stroke_id = maxi(_next_stroke_id, stroke_id + 1)
	_render_stroke(record)
	stroke_added.emit(record.duplicate(true))


func _apply_snapshot(server_revision: int, records: Dictionary) -> void:
	if server_revision < _state_revision:
		return
	if server_revision == _state_revision and _records_equal(_strokes, records):
		_snapshot_request_pending = false
		return
	_strokes.clear()
	_clear_rendered_strokes()
	_next_stroke_id = 1
	var stroke_ids: Array = records.keys()
	stroke_ids.sort()
	for stroke_id_value in stroke_ids:
		var stroke_id := int(stroke_id_value)
		var record := (records[stroke_id_value] as Dictionary).duplicate(true)
		_strokes[stroke_id] = record
		_next_stroke_id = maxi(_next_stroke_id, stroke_id + 1)
		_render_stroke(record)
	_state_revision = server_revision
	_snapshot_request_pending = false
	snapshot_applied.emit(_state_revision, _strokes.size())


func _normalize_draft(draft: Dictionary) -> Dictionary:
	if draft.size() > 6:
		_reject("空间笔画草稿包含过多字段。")
		return {}
	var points_value = draft.get("points")
	if not (points_value is PackedVector3Array):
		_reject("空间笔画点数据格式无效。")
		return {}
	var points := points_value as PackedVector3Array
	if not _validate_points(points):
		_reject("空间笔画必须包含 2～%d 个有限共享坐标点。" % MAX_POINTS_PER_STROKE)
		return {}
	var width_m := float(draft.get("width_m", 0.0))
	if not is_finite(width_m) or width_m < MIN_WIDTH_M or width_m > MAX_WIDTH_M:
		_reject("空间笔画线宽必须位于 %.3f～%.3f 米。" % [MIN_WIDTH_M, MAX_WIDTH_M])
		return {}
	var color_value = draft.get("color")
	if not _is_valid_color(color_value):
		_reject("空间笔画颜色无效。")
		return {}
	return {
		"local_id": int(draft.get("local_id", 0)),
		"points": points.duplicate(),
		"color": color_value as Color,
		"width_m": width_m,
		"completed": true,
	}


func _validate_points(points: PackedVector3Array) -> bool:
	if points.size() < 2 or points.size() > MAX_POINTS_PER_STROKE:
		return false
	var previous := Vector3.INF
	var has_nonzero_segment := false
	for point in points:
		if not _is_valid_shared_point(point):
			return false
		if previous != Vector3.INF and previous.distance_squared_to(point) > 0.00000001:
			has_nonzero_segment = true
		previous = point
	return has_nonzero_segment


func _validate_chunk_points(points: PackedVector3Array) -> bool:
	for point in points:
		if not _is_valid_shared_point(point):
			return false
	return true


func _is_valid_shared_point(point: Vector3) -> bool:
	return is_finite(point.x) \
		and is_finite(point.y) \
		and is_finite(point.z) \
		and absf(point.x) <= MAX_SHARED_COORDINATE_M \
		and absf(point.y) <= MAX_SHARED_COORDINATE_M \
		and absf(point.z) <= MAX_SHARED_COORDINATE_M


func _is_valid_color(value: Variant) -> bool:
	if not (value is Color):
		return false
	var color := value as Color
	return is_finite(color.r) \
		and is_finite(color.g) \
		and is_finite(color.b) \
		and is_finite(color.a) \
		and color.r >= 0.0 and color.r <= 1.0 \
		and color.g >= 0.0 and color.g <= 1.0 \
		and color.b >= 0.0 and color.b <= 1.0 \
		and color.a >= 0.0 and color.a <= 1.0


func _get_submission_metadata_error(
	metadata: Dictionary,
	point_count: int,
	chunk_count: int
) -> String:
	if metadata.size() > 4:
		return "空间笔画元数据字段过多。"
	if point_count < 2 or point_count > MAX_POINTS_PER_STROKE:
		return "空间笔画点数越界。"
	var expected_chunks := ceili(float(point_count) / float(POINTS_PER_CHUNK))
	if chunk_count != expected_chunks or chunk_count <= 0 or chunk_count > MAX_CHUNKS_PER_STROKE:
		return "空间笔画分块数量无效。"
	if not _is_valid_color(metadata.get("color")):
		return "空间笔画颜色无效。"
	var width_m := float(metadata.get("width_m", 0.0))
	if not is_finite(width_m) or width_m < MIN_WIDTH_M or width_m > MAX_WIDTH_M:
		return "空间笔画线宽无效。"
	if not bool(metadata.get("completed", false)):
		return "空间笔画尚未封笔。"
	return ""


func _get_record_metadata_error(
	metadata: Dictionary,
	point_count: int,
	chunk_count: int
) -> String:
	if metadata.size() > 7:
		return "空间笔画权威元数据字段过多。"
	if int(metadata.get("stroke_id", 0)) <= 0 \
			or int(metadata.get("creator_peer_id", 0)) <= 0 \
			or int(metadata.get("revision", 0)) <= 0:
		return "空间笔画权威元数据无效。"
	if point_count < 2 or point_count > MAX_POINTS_PER_STROKE:
		return "空间笔画点数越界。"
	var expected_chunks := ceili(float(point_count) / float(POINTS_PER_CHUNK))
	if chunk_count != expected_chunks or chunk_count <= 0 or chunk_count > MAX_CHUNKS_PER_STROKE:
		return "空间笔画分块数量无效。"
	if not _is_valid_color(metadata.get("color")):
		return "空间笔画颜色无效。"
	var width_m := float(metadata.get("width_m", 0.0))
	if not is_finite(width_m) or width_m < MIN_WIDTH_M or width_m > MAX_WIDTH_M:
		return "空间笔画线宽无效。"
	if not bool(metadata.get("completed", false)):
		return "空间笔画尚未封笔。"
	return ""


func _get_remote_operation_error(
	sender_id: int,
	request_sequence: int,
	count_submission: bool
) -> String:
	if not multiplayer.is_server():
		return "当前节点不是空间绘制状态 Server。"
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return "空间绘制请求发送者无效。"
	var permission_service := _get_permission_service()
	if permission_service == null or not permission_service.has_method("can_peer_draw"):
		return "空间绘制权限服务未就绪。"
	if not bool(permission_service.call("can_peer_draw", sender_id)):
		return "当前端未登记为 ground_vr 或 sky，无权绘制。"
	if request_sequence <= 0:
		return "空间绘制请求序号无效。"
	var previous_sequence := int(_server_operation_sequence_by_peer.get(sender_id, 0))
	if request_sequence <= previous_sequence:
		return "空间绘制请求已处理或已过期。"
	_server_operation_sequence_by_peer[sender_id] = request_sequence
	if count_submission and not _accept_submission_rate(sender_id):
		return "空间笔画提交频率过高。"
	return ""


func _accept_submission_rate(sender_id: int) -> bool:
	var now_msec := Time.get_ticks_msec()
	var timestamps: Array = _server_submission_times_by_peer.get(sender_id, [])
	var retained: Array = []
	for timestamp_value in timestamps:
		if now_msec - int(timestamp_value) < 1000:
			retained.append(int(timestamp_value))
	if retained.size() >= MAX_SUBMISSIONS_PER_SECOND:
		_server_submission_times_by_peer[sender_id] = retained
		return false
	retained.append(now_msec)
	_server_submission_times_by_peer[sender_id] = retained
	return true


func _pending_submission_count(sender_id: int) -> int:
	var count := 0
	for pending_value in _server_pending_submissions.values():
		if int((pending_value as Dictionary).get("sender_id", 0)) == sender_id:
			count += 1
	return count


func _pending_submission_bytes(sender_id: int) -> int:
	var total_bytes := 0
	for pending_value in _server_pending_submissions.values():
		var pending := pending_value as Dictionary
		if int(pending.get("sender_id", 0)) == sender_id:
			total_bytes += int(pending.get("point_bytes", 0))
	return total_bytes


func _abort_server_submission(key: String, message: String) -> void:
	if not _server_pending_submissions.has(key):
		return
	var pending := _server_pending_submissions[key] as Dictionary
	_server_pending_submissions.erase(key)
	_send_operation_result(
		int(pending.get("sender_id", 0)),
		int(pending.get("request_sequence", 0)),
		"submit",
		int(pending.get("local_id", 0)),
		0,
		false,
		message
	)


func _assemble_chunks(pending: Dictionary) -> PackedVector3Array:
	var points := PackedVector3Array()
	var chunks := pending.get("chunks", {}) as Dictionary
	var chunk_count := int(pending.get("chunk_count", 0))
	if chunks.size() != chunk_count:
		return points
	for chunk_index in range(chunk_count):
		if not chunks.has(chunk_index):
			return PackedVector3Array()
		points.append_array(chunks[chunk_index] as PackedVector3Array)
	return points


func _send_operation_result(
	peer_id: int,
	request_sequence: int,
	operation: String,
	local_id: int,
	stroke_id: int,
	succeeded: bool,
	message: String
) -> void:
	if peer_id <= SERVER_PEER_ID or peer_id not in multiplayer.get_peers():
		return
	rpc_id(
		peer_id,
		"_rpc_receive_drawing_operation_result",
		request_sequence,
		operation,
		local_id,
		stroke_id,
		succeeded,
		message
	)


func _render_stroke(record: Dictionary) -> void:
	if _renderer != null and _renderer.has_method("upsert_published_stroke"):
		_renderer.call("upsert_published_stroke", record)


func _remove_rendered_stroke(stroke_id: int) -> void:
	if _renderer != null and _renderer.has_method("remove_published_stroke"):
		_renderer.call("remove_published_stroke", stroke_id)


func _clear_rendered_strokes() -> void:
	if _renderer != null and _renderer.has_method("clear_published_strokes"):
		_renderer.call("clear_published_strokes")


func _records_equal(left: Dictionary, right: Dictionary) -> bool:
	if left.size() != right.size():
		return false
	for key in left:
		if not right.has(key) or left[key] != right[key]:
			return false
	return true


func _take_client_operation_sequence() -> int:
	var sequence := _next_client_operation_sequence
	_next_client_operation_sequence += 1
	return sequence


func _submission_key(peer_id: int, request_sequence: int) -> String:
	return "%d:%d" % [peer_id, request_sequence]


func _record_key(revision: int, stroke_id: int) -> String:
	return "%d:%d" % [revision, stroke_id]


func _snapshot_matches(snapshot_id: int) -> bool:
	return not _incoming_snapshot.is_empty() \
		and int(_incoming_snapshot.get("snapshot_id", 0)) == snapshot_id \
		and _is_valid_server_sender()


func _is_valid_server_sender() -> bool:
	return not multiplayer.is_server() \
		and multiplayer.get_remote_sender_id() == SERVER_PEER_ID


func _get_permission_service() -> Node:
	if peer_authority_path.is_empty():
		return null
	return get_node_or_null(peer_authority_path)


func _is_server_authority() -> bool:
	return multiplayer.is_server()


func _is_connected_client() -> bool:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return false
	var active_peer := multiplayer.multiplayer_peer
	return active_peer != null \
		and active_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _on_connected_to_server() -> void:
	_reset_client_session()
	call_deferred("request_snapshot")


func _on_server_disconnected() -> void:
	for request_sequence_value in _pending_client_operations.keys():
		var request_sequence := int(request_sequence_value)
		var pending := _pending_client_operations[request_sequence_value] as Dictionary
		operation_failed.emit(
			str(pending.get("operation", "submit")),
			request_sequence,
			int(pending.get("local_id", 0)),
			"PC 地面 Server 已断开。"
		)
	_reset_client_session()


func _on_peer_disconnected(peer_id: int) -> void:
	_server_operation_sequence_by_peer.erase(peer_id)
	_server_submission_times_by_peer.erase(peer_id)
	_server_snapshot_request_msec_by_peer.erase(peer_id)
	for key in _server_pending_submissions.keys():
		var pending := _server_pending_submissions[key] as Dictionary
		if int(pending.get("sender_id", 0)) == peer_id:
			_server_pending_submissions.erase(key)


func _reset_client_session() -> void:
	_strokes.clear()
	_state_revision = 0
	_next_stroke_id = 1
	_next_client_operation_sequence = 1
	_pending_client_operations.clear()
	_incoming_records.clear()
	_incoming_snapshot.clear()
	_snapshot_request_pending = false
	_last_snapshot_request_msec = -SNAPSHOT_REQUEST_RETRY_MSEC
	_clear_rendered_strokes()
	strokes_cleared.emit()


func _request_initial_snapshot() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		request_snapshot()


func _reject(message: String) -> void:
	if warn_on_rejection:
		push_warning(message)
	operation_rejected.emit(message)
