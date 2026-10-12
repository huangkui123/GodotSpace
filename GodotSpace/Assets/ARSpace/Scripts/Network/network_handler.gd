extends Node

const RuntimeProfileScript = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

const IP_ADDRESS: String = "127.0.0.1"
const PORT: int = 42069
const MAX_CLIENTS: int = 8
const CHANNEL_COUNT: int = 3
const START_MENU_SCENE: String = "res://Assets/ARSpace/Scenes/StartMenu.tscn"
const SERVER_PEER_ID: int = 1
const ROLE_UNKNOWN: String = "unknown"
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"
const GROUND_VR_TOKEN_ENV: String = "GODOTSPACE_GROUND_VR_TOKEN"
const REJECTED_PEER_DISCONNECT_DELAY_SEC: float = 0.5
const VALID_SESSION_ROLES: Array[String] = [
	ROLE_UNKNOWN,
	ROLE_PC_GROUND,
	ROLE_GROUND_VR,
	ROLE_SKY,
]

signal network_ready
signal network_role_selected(is_server: bool)
signal connection_failed(reason: String)
signal server_connection_lost
signal remote_annotation_received(position: Vector3, data: Dictionary)
signal peer_role_changed(peer_id: int, assigned_role: String)
signal local_role_assigned(assigned_role: String, can_annotate: bool)
signal peer_role_request_rejected(peer_id: int, requested_role: String, reason: String)

@export var marker_scene: PackedScene = preload("res://Assets/ARSpace/Prefabs/Marker.prefab.tscn")

var peer: ENetMultiplayerPeer
var spatial_calibration_preview_marker: Node3D
var _client_session_active: bool = false
var _returning_to_menu: bool = false
var _last_start_error: String = ""
var _peer_roles: Dictionary = {}
var _resolved_role_requests: Dictionary = {}
var _ground_vr_peer_id: int = 0
var _sky_peer_id: int = 0
var _peer_role_revision: int = 0
var _role_rejection_pending: bool = false


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)


func _on_peer_connected(peer_id: int) -> void:
	print("Peer %d connected" % peer_id)
	if not multiplayer.is_server() or peer_id <= SERVER_PEER_ID:
		return
	_ensure_server_role_registry()
	# Peers remain unregistered until the Server validates their role request.
	# This prevents a second Sky client from briefly entering the shared scene.
	_set_peer_role(peer_id, ROLE_UNKNOWN)
	call_deferred("_send_peer_role_snapshot", peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("Peer %d disconnected" % peer_id)
	if multiplayer.is_server():
		_remove_peer_role(peer_id)


func start_server() -> bool:
	_close_network_peer()
	_last_start_error = ""
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, MAX_CLIENTS, CHANNEL_COUNT)
	if error != OK:
		return _handle_start_failure(
			"无法启动地面 Server：UDP 端口 %d 不可用（错误 %d）。请关闭旧的 Godot Server 进程或释放该端口。" % [PORT, error]
		)

	multiplayer.multiplayer_peer = peer
	_reset_peer_roles(true)
	_client_session_active = false
	_returning_to_menu = false
	print("Server started")
	network_role_selected.emit(true)
	network_ready.emit()
	return true


func start_client(ip: String = IP_ADDRESS) -> bool:
	_close_network_peer()
	_last_start_error = ""
	var target_ip := _get_server_ip_from_args(ip)
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_client(target_ip, PORT, CHANNEL_COUNT)
	if error != OK:
		return _handle_start_failure(
			"无法创建到 %s:%d 的 Client 连接（错误 %d）。" % [target_ip, PORT, error]
		)

	multiplayer.multiplayer_peer = peer
	_reset_peer_roles(false)
	_role_rejection_pending = false
	_client_session_active = true
	_returning_to_menu = false
	network_role_selected.emit(false)
	print("Client connecting to ", target_ip)
	return true


func get_last_start_error() -> String:
	return _last_start_error


func _handle_start_failure(message: String, report_warning: bool = true) -> bool:
	_last_start_error = message
	if peer != null:
		peer.close()
	peer = null
	_restore_offline_multiplayer_peer()
	if report_warning:
		push_warning(_last_start_error)
	return false


func _get_server_ip_from_args(default_ip: String) -> String:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--server-ip="):
			var value := arg.get_slice("=", 1).strip_edges()
			if value != "":
				return value
	return default_ip


func _on_connected_to_server() -> void:
	print("Connected to server")
	_reset_peer_roles(false)
	_request_local_role_assignment()
	network_ready.emit()


func _on_connection_failed() -> void:
	if not _client_session_active:
		return
	push_warning("Unable to connect to the Ground Server. Returning to the start menu.")
	connection_failed.emit("Unable to connect to the Ground Server.")
	call_deferred("_return_client_to_start_menu")


func _on_server_disconnected() -> void:
	if not _client_session_active:
		return
	if _role_rejection_pending:
		return
	push_warning("Ground Server disconnected. Returning to the start menu.")
	server_connection_lost.emit()
	call_deferred("_return_client_to_start_menu")


func _return_client_to_start_menu() -> void:
	if _returning_to_menu:
		return
	_returning_to_menu = true
	_close_network_peer()
	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path != START_MENU_SCENE:
		get_tree().change_scene_to_file(START_MENU_SCENE)
	else:
		_returning_to_menu = false


func _close_network_peer() -> void:
	_client_session_active = false
	if peer != null:
		peer.close()
	peer = null
	_reset_peer_roles(false)
	_restore_offline_multiplayer_peer()


func _restore_offline_multiplayer_peer() -> void:
	# SceneMultiplayer normally owns an OfflineMultiplayerPeer. Keeping that
	# invariant prevents is_server()/get_unique_id() calls from observing a
	# transient null peer when ENet startup fails or a session is closed.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


func get_peer_role(peer_id: int) -> String:
	if peer_id == SERVER_PEER_ID:
		return ROLE_PC_GROUND
	return str(_peer_roles.get(peer_id, ROLE_UNKNOWN))


func get_peer_roles() -> Dictionary:
	return _peer_roles.duplicate(true)


func get_local_assigned_role() -> String:
	return get_peer_role(_get_safe_local_peer_id())


func get_ground_vr_peer_id() -> int:
	return _ground_vr_peer_id


func get_sky_peer_id() -> int:
	return _sky_peer_id


func is_peer_ground(peer_id: int) -> bool:
	return get_peer_role(peer_id) in [ROLE_PC_GROUND, ROLE_GROUND_VR]


func can_peer_annotate(peer_id: int) -> bool:
	# Annotation authority is derived only from the Server-owned registry. A
	# role string supplied in an annotation RPC payload has no effect here.
	return is_peer_ground(peer_id)


func can_peer_control_shared_windows(peer_id: int) -> bool:
	# Shared spatial windows are the common three-end workspace. Unlike virtual
	# annotations, their supported open/drag/snap operations are available to
	# every Server-registered session role, including the unique Sky peer.
	return get_peer_role(peer_id) in [
		ROLE_PC_GROUND,
		ROLE_GROUND_VR,
		ROLE_SKY,
	]


func can_peer_draw(peer_id: int) -> bool:
	# Space drawing is deliberately narrower than annotations and shared
	# windows: only the two immersive roles may publish strokes. Peer 1 is
	# normally the desktop PC Ground authority, but a VR Ground Server uses the
	# same ENet id and is allowed through its runtime presentation profile.
	if peer_id == SERVER_PEER_ID:
		var profile = RuntimeProfileScript.current()
		return profile != null \
			and profile.has_method("can_draw") \
			and bool(profile.call("can_draw"))
	return get_peer_role(peer_id) in [ROLE_GROUND_VR, ROLE_SKY]


func is_ground_vr_pairing_protected() -> bool:
	return not OS.get_environment(GROUND_VR_TOKEN_ENV).is_empty()


func _reset_peer_roles(is_server_session: bool) -> void:
	var previous_roles := _peer_roles.duplicate(true)
	_peer_roles.clear()
	_resolved_role_requests.clear()
	_ground_vr_peer_id = 0
	_sky_peer_id = 0
	_peer_role_revision = 0
	if is_server_session:
		_peer_roles[SERVER_PEER_ID] = ROLE_PC_GROUND
		_resolved_role_requests[SERVER_PEER_ID] = true
		_peer_role_revision = 1
	_emit_role_changes(previous_roles, _peer_roles)


func _ensure_server_role_registry() -> void:
	if get_peer_role(SERVER_PEER_ID) == ROLE_PC_GROUND and _peer_roles.has(SERVER_PEER_ID):
		return
	_peer_roles[SERVER_PEER_ID] = ROLE_PC_GROUND
	_resolved_role_requests[SERVER_PEER_ID] = true
	_peer_role_revision = maxi(_peer_role_revision + 1, 1)
	peer_role_changed.emit(SERVER_PEER_ID, ROLE_PC_GROUND)


func _request_local_role_assignment() -> void:
	if multiplayer.is_server() or not _has_connected_multiplayer_peer():
		return
	var requested_role := _get_requested_local_role()
	var pairing_token := OS.get_environment(GROUND_VR_TOKEN_ENV) \
		if requested_role == ROLE_GROUND_VR else ""
	rpc_id(SERVER_PEER_ID, "_server_request_session_role", requested_role, pairing_token)


func _get_requested_local_role() -> String:
	var profile = RuntimeProfileScript.current()
	if profile != null \
			and profile.has_method("is_ground") \
			and bool(profile.call("is_ground")) \
			and profile.has_method("uses_xr") \
			and bool(profile.call("uses_xr")):
		return ROLE_GROUND_VR
	return ROLE_SKY


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_session_role(requested_role: String, pairing_token: String = "") -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	_assign_requested_role(sender_id, requested_role, pairing_token)
	_broadcast_peer_role_snapshot()


func _assign_requested_role(peer_id: int, requested_role: String, pairing_token: String = "") -> String:
	if peer_id <= SERVER_PEER_ID:
		return ROLE_PC_GROUND if peer_id == SERVER_PEER_ID else ROLE_UNKNOWN
	if _resolved_role_requests.has(peer_id):
		return get_peer_role(peer_id)

	var normalized_request := requested_role.strip_edges().to_lower()
	var assigned_role := ROLE_UNKNOWN
	var rejection_reason := ""
	if normalized_request == ROLE_GROUND_VR:
		if _ground_vr_peer_id > SERVER_PEER_ID and _ground_vr_peer_id != peer_id:
			rejection_reason = "ground_vr_slot_occupied"
		elif not _is_valid_ground_vr_pairing_token(pairing_token):
			rejection_reason = "invalid_ground_vr_token"
		else:
			assigned_role = ROLE_GROUND_VR
	elif normalized_request == ROLE_SKY:
		if _sky_peer_id > SERVER_PEER_ID and _sky_peer_id != peer_id:
			rejection_reason = "sky_slot_occupied"
		else:
			assigned_role = ROLE_SKY
	else:
		rejection_reason = "unsupported_role_request"

	_resolved_role_requests[peer_id] = true
	_set_peer_role(peer_id, assigned_role)
	if not rejection_reason.is_empty():
		peer_role_request_rejected.emit(peer_id, normalized_request, rejection_reason)
		if assigned_role == ROLE_UNKNOWN:
			_notify_hard_role_rejection(peer_id, normalized_request, rejection_reason)
	return assigned_role


func _notify_hard_role_rejection(peer_id: int, requested_role: String, reason: String) -> void:
	if not multiplayer.is_server() or peer_id not in multiplayer.get_peers():
		return
	rpc_id(peer_id, "_client_receive_role_rejection", requested_role, reason)
	call_deferred("_disconnect_rejected_peer", peer_id)


func _disconnect_rejected_peer(peer_id: int) -> void:
	await get_tree().create_timer(REJECTED_PEER_DISCONNECT_DELAY_SEC).timeout
	if not multiplayer.is_server() or peer_id not in multiplayer.get_peers():
		return
	var multiplayer_peer := multiplayer.multiplayer_peer
	if multiplayer_peer != null:
		multiplayer_peer.disconnect_peer(peer_id)


@rpc("authority", "call_remote", "reliable", 0)
func _client_receive_role_rejection(requested_role: String, reason: String) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	var local_peer_id := _get_safe_local_peer_id()
	_role_rejection_pending = true
	_last_start_error = _format_role_rejection_message(requested_role, reason)
	peer_role_request_rejected.emit(local_peer_id, requested_role, reason)
	connection_failed.emit(_last_start_error)
	if _client_session_active:
		call_deferred("_return_client_to_start_menu")


func _format_role_rejection_message(requested_role: String, reason: String) -> String:
	match reason:
		"sky_slot_occupied":
			return "天上端名额已被占用（sky_slot_occupied），本次连接已拒绝。"
		"ground_vr_slot_occupied":
			return "地面 VR 名额已被占用（ground_vr_slot_occupied），本次连接已拒绝。"
		"invalid_ground_vr_token":
			return "地面 VR 配对凭据无效（invalid_ground_vr_token），本次连接已拒绝。"
		_:
			return "会话角色 %s 被拒绝：%s" % [requested_role, reason]


func _is_valid_ground_vr_pairing_token(pairing_token: String) -> bool:
	var expected_token := OS.get_environment(GROUND_VR_TOKEN_ENV)
	if expected_token.is_empty():
		# Trusted-LAN compatibility mode still keeps the role Server-assigned and
		# limits it to one peer. Configure the environment variable on both Ground
		# processes when role authentication is required.
		return true
	return _constant_time_text_equals(expected_token, pairing_token)


func _constant_time_text_equals(left: String, right: String) -> bool:
	var left_bytes := left.to_utf8_buffer()
	var right_bytes := right.to_utf8_buffer()
	var difference := left_bytes.size() ^ right_bytes.size()
	var comparison_length := maxi(left_bytes.size(), right_bytes.size())
	for index in range(comparison_length):
		var left_value := int(left_bytes[index]) if index < left_bytes.size() else 0
		var right_value := int(right_bytes[index]) if index < right_bytes.size() else 0
		difference |= left_value ^ right_value
	return difference == 0


func _set_peer_role(peer_id: int, assigned_role: String) -> void:
	var normalized_role := assigned_role if assigned_role in VALID_SESSION_ROLES else ROLE_UNKNOWN
	if peer_id == SERVER_PEER_ID:
		normalized_role = ROLE_PC_GROUND
	var previous_role := get_peer_role(peer_id)
	if previous_role == normalized_role and _peer_roles.has(peer_id):
		return
	if previous_role == ROLE_GROUND_VR and _ground_vr_peer_id == peer_id:
		_ground_vr_peer_id = 0
	if previous_role == ROLE_SKY and _sky_peer_id == peer_id:
		_sky_peer_id = 0
	if normalized_role == ROLE_SKY \
			and _sky_peer_id > SERVER_PEER_ID \
			and _sky_peer_id != peer_id:
		normalized_role = ROLE_UNKNOWN
	_peer_roles[peer_id] = normalized_role
	if normalized_role == ROLE_GROUND_VR:
		_ground_vr_peer_id = peer_id
	elif normalized_role == ROLE_SKY:
		_sky_peer_id = peer_id
	_peer_role_revision += 1
	peer_role_changed.emit(peer_id, normalized_role)
	if peer_id == _get_safe_local_peer_id():
		local_role_assigned.emit(normalized_role, can_peer_annotate(peer_id))


func _remove_peer_role(peer_id: int) -> void:
	if peer_id <= SERVER_PEER_ID:
		return
	var previous_role := get_peer_role(peer_id)
	if previous_role == ROLE_GROUND_VR and _ground_vr_peer_id == peer_id:
		_ground_vr_peer_id = 0
	if previous_role == ROLE_SKY and _sky_peer_id == peer_id:
		_sky_peer_id = 0
	_peer_roles.erase(peer_id)
	_resolved_role_requests.erase(peer_id)
	_peer_role_revision += 1
	peer_role_changed.emit(peer_id, ROLE_UNKNOWN)
	_broadcast_peer_role_snapshot()


func _broadcast_peer_role_snapshot() -> void:
	if not multiplayer.is_server() or not _has_connected_multiplayer_peer():
		return
	for peer_id_value in multiplayer.get_peers():
		_send_peer_role_snapshot(int(peer_id_value))


func _send_peer_role_snapshot(peer_id: int) -> void:
	if not multiplayer.is_server() or peer_id <= SERVER_PEER_ID:
		return
	if peer_id not in multiplayer.get_peers():
		return
	rpc_id(peer_id, "_client_receive_peer_roles", _peer_role_revision, _peer_roles)


@rpc("authority", "call_remote", "reliable", 0)
func _client_receive_peer_roles(revision: int, roles: Dictionary) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if revision < _peer_role_revision or not _validate_peer_role_snapshot(roles):
		return
	var previous_roles := _peer_roles.duplicate(true)
	_peer_roles = roles.duplicate(true)
	_peer_role_revision = revision
	_ground_vr_peer_id = 0
	_sky_peer_id = 0
	for peer_id_value in _peer_roles:
		var peer_id := int(peer_id_value)
		if str(_peer_roles[peer_id_value]) == ROLE_GROUND_VR:
			_ground_vr_peer_id = peer_id
		elif str(_peer_roles[peer_id_value]) == ROLE_SKY:
			_sky_peer_id = peer_id
	_emit_role_changes(previous_roles, _peer_roles)
	var local_peer_id := _get_safe_local_peer_id()
	local_role_assigned.emit(get_peer_role(local_peer_id), can_peer_annotate(local_peer_id))


func _validate_peer_role_snapshot(roles: Dictionary) -> bool:
	if str(roles.get(SERVER_PEER_ID, ROLE_UNKNOWN)) != ROLE_PC_GROUND:
		return false
	var ground_vr_count := 0
	var sky_count := 0
	for peer_id_value in roles:
		var peer_id := int(peer_id_value)
		var assigned_role := str(roles[peer_id_value])
		if peer_id <= 0 or assigned_role not in VALID_SESSION_ROLES:
			return false
		if peer_id == SERVER_PEER_ID and assigned_role != ROLE_PC_GROUND:
			return false
		if peer_id != SERVER_PEER_ID and assigned_role == ROLE_PC_GROUND:
			return false
		if assigned_role == ROLE_GROUND_VR:
			ground_vr_count += 1
		elif assigned_role == ROLE_SKY:
			sky_count += 1
	return ground_vr_count <= 1 and sky_count <= 1


func _emit_role_changes(previous_roles: Dictionary, current_roles: Dictionary) -> void:
	var peer_ids: Dictionary = {}
	for peer_id in previous_roles:
		peer_ids[peer_id] = true
	for peer_id in current_roles:
		peer_ids[peer_id] = true
	for peer_id_value in peer_ids:
		var peer_id := int(peer_id_value)
		var previous_role := str(previous_roles.get(peer_id_value, ROLE_UNKNOWN))
		var current_role := str(current_roles.get(peer_id_value, ROLE_UNKNOWN))
		if previous_role != current_role:
			peer_role_changed.emit(peer_id, current_role)


func _get_safe_local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return SERVER_PEER_ID
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return 0
	return multiplayer.get_unique_id()


func _has_connected_multiplayer_peer() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


@rpc("authority", "call_local", "reliable")
func create_marker_at_position(position: Vector3) -> void:
	if marker_scene == null:
		return

	var marker: Node = marker_scene.instantiate()
	var main_scene := get_tree().current_scene
	if main_scene == null:
		return

	main_scene.add_child(marker)
	if marker.has_method("setup"):
		marker.setup(position)
	elif marker is Node3D:
		(marker as Node3D).global_position = position


@rpc("authority", "call_local", "reliable")
func highlight_model_part(node_path: String, is_highlight: bool) -> void:
	var tree_list = get_tree().get_first_node_in_group("tree_list")
	if not tree_list:
		return

	var target_node = get_tree().get_root().get_node_or_null(node_path)
	if not target_node:
		return

	var mesh_instance = tree_list.find_mesh_instance_child(target_node)
	if not mesh_instance:
		return

	if is_highlight:
		tree_list.highlight_part(mesh_instance)
		tree_list.highlighted_parts[mesh_instance] = null
	else:
		tree_list.clear_highlight(mesh_instance)
		tree_list.highlighted_parts.erase(mesh_instance)
	tree_list.update_tree_item_color(target_node, is_highlight)


func send_spatial_calibration_preview(position: Vector3, data: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_receive_spatial_calibration_preview", position, data)


@rpc("authority", "call_local", "reliable")
func _receive_spatial_calibration_preview(position: Vector3, data: Dictionary) -> void:
	if spatial_calibration_preview_marker == null or not is_instance_valid(spatial_calibration_preview_marker):
		spatial_calibration_preview_marker = _create_simple_annotation_marker(position, data)
		spatial_calibration_preview_marker.name = "SpatialCalibrationPreviewMarker"
		spatial_calibration_preview_marker.add_to_group("spatial_calibration_preview_marker")

	var main_scene := get_tree().current_scene
	if main_scene != null and spatial_calibration_preview_marker.get_parent() == null:
		main_scene.add_child(spatial_calibration_preview_marker)

	spatial_calibration_preview_marker.global_position = position
	spatial_calibration_preview_marker.visible = true


func clear_spatial_calibration_preview() -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_clear_spatial_calibration_preview")


@rpc("authority", "call_local", "reliable")
func _clear_spatial_calibration_preview() -> void:
	if spatial_calibration_preview_marker != null and is_instance_valid(spatial_calibration_preview_marker):
		spatial_calibration_preview_marker.queue_free()
	spatial_calibration_preview_marker = null

	for candidate in get_tree().get_nodes_in_group("spatial_calibration_preview_marker"):
		var marker_node := candidate as Node
		if marker_node != null and is_instance_valid(marker_node):
			marker_node.queue_free()


func send_remote_annotation(position: Vector3, data: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_receive_remote_annotation", position, data)


@rpc("authority", "call_local", "reliable")
func _receive_remote_annotation(position: Vector3, data: Dictionary) -> void:
	remote_annotation_received.emit(position, data)
	_create_annotation_marker(position, data)


func _create_annotation_marker(position: Vector3, data: Dictionary) -> void:
	var marker: Node3D = _create_simple_annotation_marker(position, data)
	var main_scene := get_tree().current_scene
	if main_scene == null:
		return

	main_scene.add_child(marker)
	marker.global_position = position


func _create_simple_annotation_marker(position: Vector3, data: Dictionary) -> Node3D:
	var marker: Node3D = Node3D.new()
	marker.name = "RemoteAnnotationMarker"
	marker.global_position = position
	marker.add_to_group("remote_annotation_marker")

	var marker_size := float(data.get("size", 0.05))
	var color := _read_payload_color(data, Color.RED)

	var mesh_instance := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = marker_size
	sphere.height = marker_size * 2.0
	mesh_instance.mesh = sphere
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.material_override = _make_marker_material(color, 2.0, false)
	marker.add_child(mesh_instance)

	var outer_mesh := MeshInstance3D.new()
	var outer_sphere := SphereMesh.new()
	outer_sphere.radius = marker_size * 1.5
	outer_sphere.height = marker_size * 3.0
	outer_mesh.mesh = outer_sphere
	outer_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outer_mesh.material_override = _make_marker_material(Color(color.r, color.g, color.b, 0.3), 1.0, true)
	marker.add_child(outer_mesh)

	_add_pulse_animation(marker, mesh_instance)

	var lifetime := float(data.get("lifetime", 0.0))
	if lifetime > 0.0:
		get_tree().create_timer(lifetime).timeout.connect(func():
			if is_instance_valid(marker):
				marker.queue_free()
		)

	return marker


func _read_payload_color(data: Dictionary, fallback: Color) -> Color:
	if not data.has("color"):
		return fallback

	var value = data["color"]
	if value is Color:
		return value
	if value is Dictionary:
		var color_data := value as Dictionary
		return Color(
			float(color_data.get("r", fallback.r)),
			float(color_data.get("g", fallback.g)),
			float(color_data.get("b", fallback.b)),
			float(color_data.get("a", fallback.a))
		)
	return fallback


func _make_marker_material(color: Color, emission_energy: float, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = emission_energy
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _add_pulse_animation(marker: Node3D, mesh_instance: MeshInstance3D) -> void:
	if not is_instance_valid(marker) or not is_instance_valid(mesh_instance):
		return

	var tween := create_tween()
	tween.set_loops()
	tween.bind_node(marker)
	tween.tween_property(mesh_instance, "scale", Vector3(1.3, 1.3, 1.3), 0.6).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tween.tween_property(mesh_instance, "scale", Vector3.ONE, 0.6).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)


func send_remote_annotations_batch(annotations: Array) -> void:
	for annotation in annotations:
		if annotation is Dictionary:
			send_remote_annotation(annotation.get("position", Vector3.ZERO), annotation.get("data", {}))
		elif annotation is Vector3:
			send_remote_annotation(annotation)


func clear_all_remote_annotations() -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_clear_remote_annotations")
		rpc_id(peer_id, "_clear_spatial_calibration_preview")


@rpc("authority", "call_local", "reliable")
func _clear_remote_annotations() -> void:
	for candidate in get_tree().get_nodes_in_group("remote_annotation_marker"):
		var marker_node := candidate as Node
		if marker_node != null and is_instance_valid(marker_node):
			marker_node.queue_free()
	_clear_spatial_calibration_preview()
