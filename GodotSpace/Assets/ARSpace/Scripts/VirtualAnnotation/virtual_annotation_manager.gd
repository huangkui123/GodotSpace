class_name VirtualAnnotationManager
extends Node3D

signal annotation_added(annotation: Dictionary)
signal annotation_updated(annotation: Dictionary)
signal annotation_removed(annotation_id: int)
signal annotations_cleared()
signal annotation_selected(annotation_id: int)
signal operation_rejected(message: String)
signal snapshot_applied(state_revision: int, annotation_count: int)

const SERVER_PEER_ID: int = 1
const MAX_ANNOTATIONS: int = 128
const MAX_TEXT_LENGTH: int = 80
const SNAPSHOT_REQUEST_RETRY_MSEC: int = 500
const SERVER_SNAPSHOT_MIN_INTERVAL_MSEC: int = 250
const DEFAULT_NORMAL: Vector3 = Vector3.UP
const MARKER_COLLISION_LAYER: int = 1 << 24
const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

@export_node_path("Node3D") var shared_space_origin_path: NodePath = NodePath("../..")
@export_node_path("Node") var target_root_path: NodePath
@export var marker_scene: PackedScene = preload("res://Assets/ARSpace/Scenes/VirtualAnnotationMarker.tscn")
@export var warn_on_rejection: bool = true

var _annotations: Dictionary = {}
var _markers: Dictionary = {}
var _state_revision: int = 0
var _next_annotation_id: int = 1
var _snapshot_request_pending: bool = false
var _last_snapshot_request_msec: int = -SNAPSHOT_REQUEST_RETRY_MSEC
var _server_snapshot_request_msec_by_peer: Dictionary = {}


func _ready() -> void:
	add_to_group("virtual_annotation_manager")
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	call_deferred("_request_initial_snapshot")


func create_annotation(draft: Dictionary) -> int:
	if not _is_server_authority():
		_reject("只有地面端可以创建虚拟标注。")
		return -1
	if _annotations.size() >= MAX_ANNOTATIONS:
		_reject("本次会话最多保留 %d 个虚拟标注。" % MAX_ANNOTATIONS)
		return -1

	var normalized := _normalize_draft(draft)
	if normalized.is_empty():
		return -1

	var annotation_id := _next_annotation_id
	_next_annotation_id += 1
	_state_revision += 1
	normalized["id"] = annotation_id
	normalized["revision"] = 1
	normalized["creator_peer_id"] = SERVER_PEER_ID
	normalized["created_at_ms"] = Time.get_ticks_msec()
	_annotations[annotation_id] = normalized
	_upsert_marker(normalized)
	annotation_added.emit(normalized.duplicate(true))
	_broadcast_upsert(normalized)
	return annotation_id


func update_annotation_text(annotation_id: int, text: String) -> bool:
	if not _is_server_authority():
		_reject("只有地面端可以更新虚拟标注。")
		return false
	if not _annotations.has(annotation_id):
		_reject("找不到虚拟标注 %d。" % annotation_id)
		return false

	var annotation: Dictionary = (_annotations[annotation_id] as Dictionary).duplicate(true)
	var normalized_text := _sanitize_text(text)
	if normalized_text == str(annotation.get("text", "")):
		return true
	annotation["text"] = normalized_text
	annotation["revision"] = int(annotation.get("revision", 0)) + 1
	_state_revision += 1
	_annotations[annotation_id] = annotation
	_upsert_marker(annotation)
	annotation_updated.emit(annotation.duplicate(true))
	_broadcast_upsert(annotation)
	return true


func delete_annotation(annotation_id: int) -> bool:
	if not _is_server_authority():
		_reject("只有地面端可以删除虚拟标注。")
		return false
	if not _annotations.has(annotation_id):
		return false

	_annotations.erase(annotation_id)
	_state_revision += 1
	_remove_marker(annotation_id)
	annotation_removed.emit(annotation_id)
	_broadcast_delete(annotation_id)
	return true


func clear_annotations() -> void:
	if not _is_server_authority():
		_reject("只有地面端可以清除虚拟标注。")
		return
	if _annotations.is_empty():
		return

	_annotations.clear()
	_state_revision += 1
	_clear_markers()
	annotations_cleared.emit()
	if multiplayer.has_multiplayer_peer():
		rpc("_rpc_clear_annotations", _state_revision)


func request_annotation_snapshot() -> void:
	if _is_server_authority() or not multiplayer.has_multiplayer_peer():
		return
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_snapshot_request_pending = true
		return
	var now_msec := Time.get_ticks_msec()
	if _snapshot_request_pending and now_msec - _last_snapshot_request_msec < SNAPSHOT_REQUEST_RETRY_MSEC:
		return
	_snapshot_request_pending = true
	_last_snapshot_request_msec = now_msec
	rpc_id(SERVER_PEER_ID, "_server_request_annotation_snapshot")


func get_annotation(annotation_id: int) -> Dictionary:
	if not _annotations.has(annotation_id):
		return {}
	return (_annotations[annotation_id] as Dictionary).duplicate(true)


func get_annotations() -> Array:
	var result: Array = []
	var ids: Array = _annotations.keys()
	ids.sort()
	for annotation_id in ids:
		result.append((_annotations[annotation_id] as Dictionary).duplicate(true))
	return result


func get_annotation_count() -> int:
	return _annotations.size()


func get_state_revision() -> int:
	return _state_revision


func get_next_default_text() -> String:
	return "标注 %d" % _next_annotation_id


func get_marker_collision_layer() -> int:
	return MARKER_COLLISION_LAYER


func get_shared_space_origin() -> Node3D:
	return _get_shared_space_origin()


func get_target_root() -> Node:
	return _get_target_root()


func select_annotation(annotation_id: int) -> bool:
	if not _annotations.has(annotation_id):
		return false
	annotation_selected.emit(annotation_id)
	return true


func find_annotation_id_from_collider(collider: Object) -> int:
	if collider == null:
		return -1
	if collider.has_meta("virtual_annotation_id"):
		return int(collider.get_meta("virtual_annotation_id", -1))
	if collider is Node:
		var current := collider as Node
		while current != null:
			if current.has_meta("virtual_annotation_id"):
				return int(current.get_meta("virtual_annotation_id", -1))
			current = current.get_parent()
	return -1


func make_draft_from_hit(global_position: Vector3, global_normal: Vector3, collider: Object = null) -> Dictionary:
	var shared_origin := _get_shared_space_origin()
	var target_root := _get_target_root()
	if shared_origin == null or target_root == null or not _is_finite_vector(global_position) or not _is_valid_normal(global_normal):
		return {}

	var normal := global_normal.normalized()
	var draft := {
		"shared_position": shared_origin.to_local(global_position),
		"shared_normal": _world_normal_to_local(shared_origin, normal),
		"target_path": "",
		"target_local_position": Vector3.ZERO,
		"target_local_normal": DEFAULT_NORMAL,
		"text": get_next_default_text(),
	}

	var target := _resolve_hit_target(collider, target_root)
	if target != null:
		var target_path := str(target_root.get_path_to(target))
		if _is_safe_target_path(target_path):
			draft["target_path"] = target_path
			draft["target_local_position"] = target.to_local(global_position)
			draft["target_local_normal"] = _world_normal_to_local(target, normal)
	return draft


func validate_annotation_record(annotation: Dictionary) -> bool:
	if not annotation.has("id") or int(annotation.get("id", 0)) <= 0:
		return false
	if int(annotation.get("revision", 0)) <= 0:
		return false
	if not _is_finite_vector(annotation.get("shared_position", Vector3.INF)):
		return false
	if not _is_valid_normal(annotation.get("shared_normal", Vector3.ZERO)):
		return false
	var text := str(annotation.get("text", ""))
	if text.length() > MAX_TEXT_LENGTH:
		return false
	var target_path := str(annotation.get("target_path", ""))
	if not _is_safe_target_path(target_path):
		return false
	if target_path != "":
		if not _is_finite_vector(annotation.get("target_local_position", Vector3.INF)):
			return false
		if not _is_valid_normal(annotation.get("target_local_normal", Vector3.ZERO)):
			return false
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_annotation_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	var now_msec := Time.get_ticks_msec()
	var previous_request_msec := int(_server_snapshot_request_msec_by_peer.get(sender_id, -SERVER_SNAPSHOT_MIN_INTERVAL_MSEC))
	if now_msec - previous_request_msec < SERVER_SNAPSHOT_MIN_INTERVAL_MSEC:
		return
	_server_snapshot_request_msec_by_peer[sender_id] = now_msec
	rpc_id(sender_id, "_rpc_receive_snapshot", _state_revision, get_annotations())


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_receive_snapshot(server_revision: int, snapshot: Array) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_apply_snapshot(server_revision, snapshot)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_upsert_annotation(server_revision: int, annotation: Dictionary) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if not validate_annotation_record(annotation):
		request_annotation_snapshot()
		return
	if server_revision <= _state_revision:
		return
	if server_revision > _state_revision + 1:
		request_annotation_snapshot()
		return

	var annotation_id := int(annotation["id"])
	var previous: Dictionary = get_annotation(annotation_id)
	if not previous.is_empty() and int(previous.get("revision", 0)) >= int(annotation.get("revision", 0)):
		request_annotation_snapshot()
		return
	_state_revision = server_revision
	_annotations[annotation_id] = annotation.duplicate(true)
	_upsert_marker(annotation)
	if previous.is_empty():
		annotation_added.emit(annotation.duplicate(true))
	else:
		annotation_updated.emit(annotation.duplicate(true))


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_delete_annotation(server_revision: int, annotation_id: int) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if server_revision <= _state_revision:
		return
	if server_revision > _state_revision + 1:
		request_annotation_snapshot()
		return
	_state_revision = server_revision
	_annotations.erase(annotation_id)
	_remove_marker(annotation_id)
	annotation_removed.emit(annotation_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_clear_annotations(server_revision: int) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if server_revision <= _state_revision:
		return
	_state_revision = server_revision
	_annotations.clear()
	_clear_markers()
	annotations_cleared.emit()


func _normalize_draft(draft: Dictionary) -> Dictionary:
	var shared_position = draft.get("shared_position", Vector3.INF)
	var shared_normal = draft.get("shared_normal", Vector3.ZERO)
	if not _is_finite_vector(shared_position):
		_reject("标注位置无效。")
		return {}
	if not _is_valid_normal(shared_normal):
		_reject("标注表面法线无效。")
		return {}

	var target_path := str(draft.get("target_path", ""))
	if not _is_safe_target_path(target_path):
		_reject("标注目标路径无效。")
		return {}
	var target_local_position = draft.get("target_local_position", Vector3.ZERO)
	var target_local_normal = draft.get("target_local_normal", DEFAULT_NORMAL)
	if target_path != "" and (not _is_finite_vector(target_local_position) or not _is_valid_normal(target_local_normal)):
		_reject("标注目标的局部坐标无效。")
		return {}

	return {
		"shared_position": shared_position,
		"shared_normal": (shared_normal as Vector3).normalized(),
		"target_path": target_path,
		"target_local_position": target_local_position,
		"target_local_normal": (target_local_normal as Vector3).normalized(),
		"text": _sanitize_text(str(draft.get("text", ""))),
	}


func _apply_snapshot(server_revision: int, snapshot: Array) -> bool:
	if server_revision < _state_revision:
		return false
	if snapshot.size() > MAX_ANNOTATIONS:
		return false

	var replacement: Dictionary = {}
	var highest_id := 0
	for value in snapshot:
		if not (value is Dictionary):
			return false
		var annotation := (value as Dictionary).duplicate(true)
		if not validate_annotation_record(annotation):
			return false
		var annotation_id := int(annotation["id"])
		if replacement.has(annotation_id):
			return false
		replacement[annotation_id] = annotation
		highest_id = maxi(highest_id, annotation_id)
	if server_revision == _state_revision and replacement == _annotations:
		_snapshot_request_pending = false
		return true

	_annotations = replacement
	_state_revision = server_revision
	_next_annotation_id = maxi(_next_annotation_id, highest_id + 1)
	_clear_markers()
	for annotation in get_annotations():
		_upsert_marker(annotation)
	_snapshot_request_pending = false
	snapshot_applied.emit(_state_revision, _annotations.size())
	return true


func _broadcast_upsert(annotation: Dictionary) -> void:
	if multiplayer.has_multiplayer_peer():
		rpc("_rpc_upsert_annotation", _state_revision, annotation)


func _broadcast_delete(annotation_id: int) -> void:
	if multiplayer.has_multiplayer_peer():
		rpc("_rpc_delete_annotation", _state_revision, annotation_id)


func _upsert_marker(annotation: Dictionary) -> void:
	var annotation_id := int(annotation.get("id", -1))
	if annotation_id <= 0:
		return
	var marker: Node = _markers.get(annotation_id)
	if marker == null or not is_instance_valid(marker):
		if marker_scene == null:
			return
		marker = marker_scene.instantiate()
		marker.name = "VirtualAnnotation_%d" % annotation_id
		add_child(marker)
		_markers[annotation_id] = marker
	if marker.has_method("configure"):
		marker.call("configure", annotation, _get_shared_space_origin(), false, _get_target_root())


func _remove_marker(annotation_id: int) -> void:
	var marker: Node = _markers.get(annotation_id)
	if marker != null and is_instance_valid(marker):
		marker.queue_free()
	_markers.erase(annotation_id)


func _clear_markers() -> void:
	for marker in _markers.values():
		if marker is Node and is_instance_valid(marker):
			(marker as Node).queue_free()
	_markers.clear()


func _resolve_hit_target(collider: Object, target_root: Node) -> Node3D:
	if collider == null:
		return null
	var target_path := ""
	if collider.has_meta("annotation_target_path"):
		target_path = str(collider.get_meta("annotation_target_path", ""))
	if target_path != "" and _is_safe_target_path(target_path):
		return target_root.get_node_or_null(NodePath(target_path)) as Node3D
	if collider is Node3D and target_root.is_ancestor_of(collider as Node3D):
		return collider as Node3D
	return null


func _get_shared_space_origin() -> Node3D:
	if shared_space_origin_path.is_empty():
		return get_tree().current_scene as Node3D
	return get_node_or_null(shared_space_origin_path) as Node3D


func _get_target_root() -> Node:
	if target_root_path.is_empty():
		return get_tree().current_scene
	return get_node_or_null(target_root_path)


func _is_server_authority() -> bool:
	var profile = RuntimeProfile.current()
	return profile.can_annotate() \
		and (not multiplayer.has_multiplayer_peer() or multiplayer.is_server())


func _on_connected_to_server() -> void:
	_reset_client_session_state()
	call_deferred("request_annotation_snapshot")


func _on_peer_disconnected(peer_id: int) -> void:
	_server_snapshot_request_msec_by_peer.erase(peer_id)


func _reset_client_session_state() -> void:
	var had_annotations := not _annotations.is_empty()
	_annotations.clear()
	_state_revision = 0
	_next_annotation_id = 1
	_snapshot_request_pending = false
	_last_snapshot_request_msec = -SNAPSHOT_REQUEST_RETRY_MSEC
	_clear_markers()
	if had_annotations:
		annotations_cleared.emit()


func _request_initial_snapshot() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		request_annotation_snapshot()


func _sanitize_text(text: String) -> String:
	var clean := text.replace("\r", " ").replace("\n", " ").replace("\t", " ").strip_edges()
	while clean.find("  ") != -1:
		clean = clean.replace("  ", " ")
	if clean.length() > MAX_TEXT_LENGTH:
		clean = clean.left(MAX_TEXT_LENGTH)
	return clean


func _is_safe_target_path(path_text: String) -> bool:
	if path_text == "":
		return true
	var path := NodePath(path_text)
	if path.is_absolute() or path.get_subname_count() > 0:
		return false
	for index in range(path.get_name_count()):
		var segment := str(path.get_name(index))
		if segment == "" or segment == "." or segment == "..":
			return false
	return true


func _is_valid_normal(value: Variant) -> bool:
	return value is Vector3 and _is_finite_vector(value) and (value as Vector3).length_squared() > 0.000001


func _is_finite_vector(value: Variant) -> bool:
	if not (value is Vector3):
		return false
	var vector := value as Vector3
	return is_finite(vector.x) and is_finite(vector.y) and is_finite(vector.z)


func _world_normal_to_local(target: Node3D, world_normal: Vector3) -> Vector3:
	var local_normal := target.global_transform.basis.transposed() * world_normal
	if not _is_valid_normal(local_normal):
		return DEFAULT_NORMAL
	return local_normal.normalized()


func _reject(message: String) -> void:
	operation_rejected.emit(message)
	if warn_on_rejection:
		push_warning(message)
