extends Node3D

const RuntimeProfileScript = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const SERVER_PEER_ID: int = 1
const POSE_SEND_INTERVAL: float = 1.0 / 30.0
const REMOTE_INTERPOLATION_DELAY: float = 0.1
const MAX_QUEUED_POSE_SAMPLES: int = 12
const MAX_SHARED_POSE_DISTANCE: float = 1000.0
const TEST_MODE_ARG: String = "--testmode"
const GROUND_VR_ARG: String = "--ground-vr"
const XR_CLIENT_ARG: String = "--xr-client"
const TEST_TRIGGER_KEY := KEY_J
const TEST_GRIP_KEY := KEY_K
const PC_LEFT_HAND_OFFSET := Vector3(-0.28, -0.22, -0.38)
const PC_RIGHT_HAND_OFFSET := Vector3(0.28, -0.22, -0.38)
const ROLE_UNKNOWN: String = "unknown"
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"
const PC_GROUND_ROLE_COLOR := Color(0.16, 0.78, 1.0, 1.0)
const GROUND_VR_ROLE_COLOR := Color(0.22, 0.95, 0.55, 1.0)
const SKY_ROLE_COLOR := Color(1.0, 0.62, 0.18, 1.0)

const LOCAL_XR_NODE_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D"),
	NodePath("XROrigin3D/XRCamera3D"),
	NodePath("XROrigin3D/LeftHand"),
	NodePath("XROrigin3D/RightHand"),
	NodePath("XROrigin3D/PlayerBody"),
]

const TEST_MODE_HIDDEN_LOCAL_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D/XRCamera3D/Head"),
	NodePath("XROrigin3D/LeftHand"),
	NodePath("XROrigin3D/PlayerBody"),
]

const LOCAL_HAND_MESH_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D/LeftHand/LeftHand/Hand_L/Armature/Skeleton3D/mesh_Hand_L"),
	NodePath("XROrigin3D/RightHand/RightHand/Hand_R/Armature/Skeleton3D/mesh_Hand_R"),
]

const NETWORK_POSE_PAIRS: Array = [
	[NodePath("XROrigin3D/XRCamera3D"), NodePath("NetworkHead")],
	[NodePath("XROrigin3D/LeftHand"), NodePath("NetworkLeftHand")],
	[NodePath("XROrigin3D/RightHand"), NodePath("NetworkRightHand")],
]

const NETWORK_AVATAR_ROOTS: Array[NodePath] = [
	NodePath("NetworkHead"),
	NodePath("NetworkLeftHand"),
	NodePath("NetworkRightHand"),
	NodePath("NetworkTorso"),
]

const NETWORK_AVATAR_MESHES: Array[NodePath] = [
	NodePath("NetworkHead/HeadMesh"),
	NodePath("NetworkHead/FacingIndicator"),
	NodePath("NetworkLeftHand/HandMesh"),
	NodePath("NetworkRightHand/HandMesh"),
	NodePath("NetworkTorso/TorsoMesh"),
]

@onready var xr_camera: XRCamera3D = get_node_or_null("XROrigin3D/XRCamera3D") as XRCamera3D

var _runtime_profile
var _shared_space_origin: Node3D
var _pose_send_seconds: float = 0.0
var _local_pose_sequence: int = 0
var _last_received_pose_sequence: int = -1
var _remote_pose_samples: Array[Dictionary] = []
var _replica_ready_peer_ids: Dictionary = {}
var _has_received_network_pose: bool = false
var _last_network_pose_received_usec: int = 0
var _test_trigger_pressed: bool = false
var _test_grip_pressed: bool = false
var _session_role: String = ROLE_UNKNOWN

func _enter_tree() -> void:
	set_multiplayer_authority(_get_peer_id_from_name(), true)
	# Parent _enter_tree runs before the XR children enter the SceneTree. This
	# protects direct/non-spawner instantiation paths from registering remote XR
	# movement providers globally, matching prepare_for_network_spawn().
	if not _is_local_authority():
		_remove_remote_xr_branch()

func _ready() -> void:
	set_multiplayer_authority(_get_peer_id_from_name(), true)
	_runtime_profile = RuntimeProfileScript.current()
	_connect_role_registry()
	_refresh_session_role()
	_apply_role_appearance()
	_configure_local_xr_nodes(_is_local_authority())
	_sync_network_pose_from_local_source()

	if _is_local_authority() and _uses_xr_presentation() and xr_camera != null:
		xr_camera.make_current()
	if _has_active_multiplayer_peer() and not multiplayer.is_server():
		call_deferred("_notify_server_replica_ready")
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _exit_tree() -> void:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler != null \
			and network_handler.has_signal("peer_role_changed") \
			and network_handler.peer_role_changed.is_connected(_on_peer_role_changed):
		network_handler.peer_role_changed.disconnect(_on_peer_role_changed)

func _process(delta: float) -> void:
	if _is_local_authority():
		_sync_network_pose_from_local_source()
		_pose_send_seconds += delta
		if _pose_send_seconds >= POSE_SEND_INTERVAL:
			_pose_send_seconds = fmod(_pose_send_seconds, POSE_SEND_INTERVAL)
			_send_local_pose()
		return

	_update_remote_pose()

func _input(event: InputEvent) -> void:
	if not _is_local_authority() or not _is_test_mode() or not (event is InputEventKey):
		return

	var key_event := event as InputEventKey
	if key_event.echo:
		return

	if key_event.physical_keycode == TEST_TRIGGER_KEY:
		_set_test_trigger_pressed(key_event.pressed)
		get_viewport().set_input_as_handled()
	elif key_event.physical_keycode == TEST_GRIP_KEY:
		_set_test_grip_pressed(key_event.pressed)
		get_viewport().set_input_as_handled()

func _get_peer_id_from_name() -> int:
	var peer_id := name.to_int()
	return peer_id if peer_id > 0 else SERVER_PEER_ID

func set_session_role(assigned_role: String) -> void:
	var normalized_role := _normalize_session_role(assigned_role)
	if _session_role == normalized_role:
		return
	_session_role = normalized_role
	if is_inside_tree():
		_apply_role_appearance()

func get_session_role() -> String:
	return _resolved_session_role()

func _connect_role_registry() -> void:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler == null or not network_handler.has_signal("peer_role_changed"):
		return
	if not network_handler.peer_role_changed.is_connected(_on_peer_role_changed):
		network_handler.peer_role_changed.connect(_on_peer_role_changed)

func _refresh_session_role() -> void:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler == null or not network_handler.has_method("get_peer_role"):
		return
	var registered_role := str(network_handler.call("get_peer_role", _get_peer_id_from_name()))
	if registered_role != ROLE_UNKNOWN:
		_session_role = _normalize_session_role(registered_role)

func _on_peer_role_changed(peer_id: int, assigned_role: String) -> void:
	if peer_id != _get_peer_id_from_name():
		return
	set_session_role(assigned_role)

func _normalize_session_role(assigned_role: String) -> String:
	var normalized_role := assigned_role.strip_edges().to_lower()
	return normalized_role if normalized_role in [ROLE_PC_GROUND, ROLE_GROUND_VR, ROLE_SKY] else ROLE_UNKNOWN

func _resolved_session_role() -> String:
	if _session_role != ROLE_UNKNOWN:
		return _session_role
	return ROLE_PC_GROUND if _get_peer_id_from_name() == SERVER_PEER_ID else ROLE_SKY

func _is_local_authority() -> bool:
	if _has_active_multiplayer_peer():
		return is_multiplayer_authority()
	return _get_peer_id_from_name() == SERVER_PEER_ID

func _has_active_multiplayer_peer() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED

func _is_test_mode() -> bool:
	return _has_command_line_argument(TEST_MODE_ARG)

func _uses_xr_presentation() -> bool:
	var profile = _runtime_profile
	if profile == null:
		profile = RuntimeProfileScript.current()
	if profile != null and profile.is_valid():
		return profile.uses_xr()
	if _is_test_mode():
		return false
	if _has_command_line_argument(GROUND_VR_ARG):
		return true
	if OS.get_name() == "Android" or _has_command_line_argument(XR_CLIENT_ARG):
		return true
	if _has_active_multiplayer_peer():
		return not multiplayer.is_server()
	return false

func _is_pc_ground_server() -> bool:
	return _has_active_multiplayer_peer() and multiplayer.is_server() and not _uses_xr_presentation()

func _has_command_line_argument(argument: String) -> bool:
	return OS.get_cmdline_args().has(argument) or OS.get_cmdline_user_args().has(argument)


func prepare_for_network_spawn(is_local_replica: bool) -> void:
	# MultiplayerSpawner calls this before the player enters the SceneTree.
	# Removing the unused XR branch at this point prevents XRToolsPlayerBody
	# from caching movement providers owned by remote replicas. Those providers
	# would otherwise be freed shortly afterwards and leave stale references in
	# the local PlayerBody.
	if not is_local_replica:
		_remove_remote_xr_branch()


func _configure_local_xr_nodes(is_local_authority: bool) -> void:
	var xr_origin := get_node_or_null("XROrigin3D") as XROrigin3D
	var camera := get_node_or_null("XROrigin3D/XRCamera3D") as Camera3D
	var player_body := get_node_or_null("XROrigin3D/PlayerBody")
	var local_xr_enabled := is_local_authority and (_uses_xr_presentation() or _is_test_mode())

	if xr_origin != null:
		xr_origin.current = is_local_authority and _uses_xr_presentation()
		xr_origin.visible = local_xr_enabled
	if camera != null:
		camera.current = is_local_authority and _uses_xr_presentation()
	var local_head_visual := get_node_or_null("XROrigin3D/XRCamera3D/Head") as Node3D
	if local_head_visual != null:
		local_head_visual.visible = not is_local_authority

	var local_process_mode := Node.PROCESS_MODE_INHERIT if local_xr_enabled else Node.PROCESS_MODE_DISABLED
	for node_path in LOCAL_XR_NODE_PATHS:
		var local_node := get_node_or_null(node_path)
		if local_node != null:
			local_node.process_mode = local_process_mode

	# Both Sky MR and Ground VR use the authored stick movement providers.
	# Remote replicas and desktop/test players must never consume XR input.
	var local_xr_locomotion_enabled: bool = is_local_authority and _uses_xr_presentation()
	for movement_path in [
		NodePath("XROrigin3D/LeftHand/MovementTurn"),
		NodePath("XROrigin3D/RightHand/MovementDirect"),
	]:
		var movement := get_node_or_null(movement_path)
		if movement != null:
			movement.set("enabled", local_xr_locomotion_enabled)

	if player_body != null:
		var player_body_enabled := is_local_authority and _uses_xr_presentation()
		player_body.set("enabled", player_body_enabled)
		if player_body is CollisionObject3D:
			var collision_body := player_body as CollisionObject3D
			# Keep XR locomotion active, but make the local avatar a ghost for
			# movement physics. Annotation rays use their own layer-24 proxies.
			collision_body.collision_layer = 0
			collision_body.collision_mask = 0

	_configure_hand_pointers(local_xr_enabled)
	_set_network_avatar_visible(false)
	if not is_local_authority:
		# This is a fallback for players instantiated outside MultiplayerSpawner.
		# Detach synchronously so later local players cannot discover this
		# replica's XR movement providers through the global group.
		_remove_remote_xr_branch()
	elif _is_test_mode():
		_configure_test_mode_local_visuals()
	if is_local_authority:
		_set_local_hand_meshes_visible(false)


func _set_local_hand_meshes_visible(is_visible: bool) -> void:
	for node_path in LOCAL_HAND_MESH_PATHS:
		var hand_mesh := get_node_or_null(node_path) as MeshInstance3D
		if hand_mesh != null:
			hand_mesh.visible = is_visible


func _configure_hand_pointers(right_pointer_enabled: bool) -> void:
	var left_pointer := get_node_or_null("XROrigin3D/LeftHand/FunctionPointer") as Node3D
	if left_pointer != null:
		left_pointer.set("enabled", false)
		left_pointer.set("show_laser", 0)
		left_pointer.visible = false
		left_pointer.process_mode = Node.PROCESS_MODE_DISABLED

	var right_pointer := get_node_or_null("XROrigin3D/RightHand/FunctionPointer") as Node3D
	if right_pointer != null:
		right_pointer.process_mode = (
			Node.PROCESS_MODE_INHERIT
			if right_pointer_enabled
			else Node.PROCESS_MODE_DISABLED
		)
		right_pointer.set("show_laser", 1 if right_pointer_enabled else 0)
		right_pointer.set("laser_length", 1)
		right_pointer.set("show_target", true)
		if right_pointer.has_method("set_interaction_requested"):
			right_pointer.call("set_interaction_requested", right_pointer_enabled)
		else:
			right_pointer.set("enabled", right_pointer_enabled)
			right_pointer.visible = right_pointer_enabled


func _configure_test_mode_local_visuals() -> void:
	for node_path in TEST_MODE_HIDDEN_LOCAL_PATHS:
		var node := get_node_or_null(node_path) as Node3D
		if node != null:
			node.visible = false

	var right_hand := get_node_or_null("XROrigin3D/RightHand") as Node3D
	if right_hand != null:
		right_hand.visible = true

	var right_hand_visual := get_node_or_null("XROrigin3D/RightHand/RightHand") as Node3D
	if right_hand_visual != null:
		right_hand_visual.visible = true

	_configure_hand_pointers(true)

func _remove_remote_xr_branch() -> void:
	var xr_origin := get_node_or_null("XROrigin3D")
	if xr_origin != null:
		if xr_origin.get_parent() == self:
			remove_child(xr_origin)
		xr_origin.queue_free()

func _set_test_trigger_pressed(pressed: bool) -> void:
	if _test_trigger_pressed == pressed:
		return
	_test_trigger_pressed = pressed
	var right_controller := get_node_or_null("XROrigin3D/RightHand") as XRController3D
	if right_controller != null:
		right_controller.emit_signal("button_pressed" if pressed else "button_released", "trigger_click")
	_update_test_hand_pose()

func _set_test_grip_pressed(pressed: bool) -> void:
	if _test_grip_pressed == pressed:
		return
	_test_grip_pressed = pressed
	var right_controller := get_node_or_null("XROrigin3D/RightHand") as XRController3D
	if right_controller != null:
		right_controller.emit_signal("button_pressed" if pressed else "button_released", "grip_click")
	_update_test_hand_pose()

func _update_test_hand_pose() -> void:
	var right_hand_visual := get_node_or_null("XROrigin3D/RightHand/RightHand")
	if right_hand_visual != null and right_hand_visual.has_method("force_grip_trigger"):
		right_hand_visual.force_grip_trigger(
			1.0 if _test_grip_pressed else 0.0,
			1.0 if _test_trigger_pressed else 0.0
		)

func _sync_network_pose_from_local_source() -> void:
	if not _is_local_authority():
		return
	if _is_pc_ground_server():
		_sync_pc_ground_proxy_pose()
	else:
		for pair in NETWORK_POSE_PAIRS:
			var source := get_node_or_null(pair[0]) as Node3D
			var target := get_node_or_null(pair[1]) as Node3D
			if source != null and target != null:
				target.global_transform = source.global_transform

func _sync_pc_ground_proxy_pose() -> void:
	var spectator_camera := _find_spectator_camera()
	var head := get_node_or_null("NetworkHead") as Node3D
	var left_hand := get_node_or_null("NetworkLeftHand") as Node3D
	var right_hand := get_node_or_null("NetworkRightHand") as Node3D
	if spectator_camera == null or head == null or left_hand == null or right_hand == null:
		return

	var camera_transform := spectator_camera.global_transform
	head.global_transform = camera_transform
	left_hand.global_transform = _transform_with_local_offset(camera_transform, PC_LEFT_HAND_OFFSET)
	right_hand.global_transform = _transform_with_local_offset(camera_transform, PC_RIGHT_HAND_OFFSET)

func _find_spectator_camera() -> Camera3D:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return null
	return current_scene.find_child("SpectatorCamera", true, false) as Camera3D

func _transform_with_local_offset(source: Transform3D, offset: Vector3) -> Transform3D:
	var result := source
	result.origin += source.basis * offset
	return result

func _send_local_pose() -> void:
	if not _has_active_multiplayer_peer():
		return

	var head := get_node_or_null("NetworkHead") as Node3D
	var left_hand := get_node_or_null("NetworkLeftHand") as Node3D
	var right_hand := get_node_or_null("NetworkRightHand") as Node3D
	if head == null or left_hand == null or right_hand == null:
		return

	var head_transform := _global_to_shared(head.global_transform)
	var left_hand_transform := _global_to_shared(left_hand.global_transform)
	var right_hand_transform := _global_to_shared(right_hand.global_transform)
	if not _are_valid_pose_transforms(head_transform, left_hand_transform, right_hand_transform):
		return

	_local_pose_sequence += 1
	if multiplayer.is_server():
		_broadcast_pose_to_clients(_local_pose_sequence, head_transform, left_hand_transform, right_hand_transform)
	else:
		rpc_id(
			SERVER_PEER_ID,
			"_server_receive_pose",
			_local_pose_sequence,
			head_transform,
			left_hand_transform,
			right_hand_transform
		)

func _broadcast_pose_to_clients(
	sequence: int,
	head_transform: Transform3D,
	left_hand_transform: Transform3D,
	right_hand_transform: Transform3D,
	excluded_peer_id: int = 0
) -> void:
	for peer_id_value in multiplayer.get_peers():
		var peer_id := int(peer_id_value)
		if peer_id == excluded_peer_id:
			continue
		if not _replica_ready_peer_ids.has(peer_id):
			continue
		rpc_id(
			peer_id,
			"_client_receive_pose",
			sequence,
			head_transform,
			left_hand_transform,
			right_hand_transform
		)

func _notify_server_replica_ready() -> void:
	if not _has_active_multiplayer_peer() or multiplayer.is_server():
		return
	rpc_id(SERVER_PEER_ID, "_server_mark_replica_ready")

@rpc("any_peer", "call_remote", "reliable")
func _server_mark_replica_ready() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	_replica_ready_peer_ids[sender_id] = true


func _on_peer_disconnected(peer_id: int) -> void:
	_replica_ready_peer_ids.erase(peer_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_receive_pose(
	sequence: int,
	head_transform: Transform3D,
	left_hand_transform: Transform3D,
	right_hand_transform: Transform3D
) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != _get_peer_id_from_name():
		return
	if not _accept_remote_pose(sequence, head_transform, left_hand_transform, right_hand_transform):
		return

	_broadcast_pose_to_clients(sequence, head_transform, left_hand_transform, right_hand_transform, sender_id)

@rpc("any_peer", "call_remote", "unreliable")
func _client_receive_pose(
	sequence: int,
	head_transform: Transform3D,
	left_hand_transform: Transform3D,
	right_hand_transform: Transform3D
) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if _is_local_authority():
		return
	_accept_remote_pose(sequence, head_transform, left_hand_transform, right_hand_transform)

func _accept_remote_pose(
	sequence: int,
	head_transform: Transform3D,
	left_hand_transform: Transform3D,
	right_hand_transform: Transform3D
) -> bool:
	if sequence <= _last_received_pose_sequence:
		return false
	if not _are_valid_pose_transforms(head_transform, left_hand_transform, right_hand_transform):
		return false

	_last_received_pose_sequence = sequence
	var received_at := Time.get_ticks_usec() / 1000000.0
	if not _remote_pose_samples.is_empty():
		received_at = maxf(received_at, float(_remote_pose_samples[-1]["received_at"]) + 0.000001)
	_remote_pose_samples.append({
		"received_at": received_at,
		"head": head_transform,
		"left_hand": left_hand_transform,
		"right_hand": right_hand_transform,
	})
	while _remote_pose_samples.size() > MAX_QUEUED_POSE_SAMPLES:
		_remote_pose_samples.pop_front()

	_has_received_network_pose = true
	_last_network_pose_received_usec = Time.get_ticks_usec()
	_set_network_avatar_visible(true)
	if _remote_pose_samples.size() == 1:
		_apply_network_pose_shared(head_transform, left_hand_transform, right_hand_transform)
	return true


func get_network_viewpoint() -> Node3D:
	return get_node_or_null("NetworkHead") as Node3D


func has_received_network_pose() -> bool:
	return _has_received_network_pose


func get_last_network_pose_received_msec() -> int:
	return _last_network_pose_received_usec / 1000

func _update_remote_pose() -> void:
	if not _has_received_network_pose or _remote_pose_samples.is_empty():
		return

	var playback_time := Time.get_ticks_usec() / 1000000.0 - REMOTE_INTERPOLATION_DELAY
	while _remote_pose_samples.size() >= 2 and float(_remote_pose_samples[1]["received_at"]) <= playback_time:
		_remote_pose_samples.pop_front()

	var first := _remote_pose_samples[0]
	if _remote_pose_samples.size() == 1:
		if float(first["received_at"]) <= playback_time:
			_apply_network_pose_shared(first["head"], first["left_hand"], first["right_hand"])
		return

	var second := _remote_pose_samples[1]
	var first_time := float(first["received_at"])
	var second_time := float(second["received_at"])
	var weight := clampf(inverse_lerp(first_time, second_time, playback_time), 0.0, 1.0)
	_apply_network_pose_shared(
		(first["head"] as Transform3D).interpolate_with(second["head"], weight),
		(first["left_hand"] as Transform3D).interpolate_with(second["left_hand"], weight),
		(first["right_hand"] as Transform3D).interpolate_with(second["right_hand"], weight)
	)

func _apply_network_pose_shared(
	head_transform: Transform3D,
	left_hand_transform: Transform3D,
	right_hand_transform: Transform3D
) -> void:
	var head := get_node_or_null("NetworkHead") as Node3D
	var left_hand := get_node_or_null("NetworkLeftHand") as Node3D
	var right_hand := get_node_or_null("NetworkRightHand") as Node3D
	if head != null:
		head.global_transform = _shared_to_global(head_transform)
	if left_hand != null:
		left_hand.global_transform = _shared_to_global(left_hand_transform)
	if right_hand != null:
		right_hand.global_transform = _shared_to_global(right_hand_transform)
	_update_torso_pose(head_transform)

func _update_torso_pose(head_transform: Transform3D) -> void:
	var torso := get_node_or_null("NetworkTorso") as Node3D
	if torso == null:
		return

	var forward := -head_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var yaw := atan2(-forward.x, -forward.z)
	var torso_transform := Transform3D(Basis(Vector3.UP, yaw), head_transform.origin + Vector3(0.0, -0.46, 0.0))
	torso.global_transform = _shared_to_global(torso_transform)

func _are_valid_pose_transforms(head: Transform3D, left_hand: Transform3D, right_hand: Transform3D) -> bool:
	return _is_valid_pose_transform(head) and _is_valid_pose_transform(left_hand) and _is_valid_pose_transform(right_hand)

func _is_valid_pose_transform(value: Transform3D) -> bool:
	if not _is_finite_vector3(value.origin) or value.origin.length() > MAX_SHARED_POSE_DISTANCE:
		return false
	var axes: Array[Vector3] = [value.basis.x, value.basis.y, value.basis.z]
	for axis_value in axes:
		var axis: Vector3 = axis_value
		if not _is_finite_vector3(axis):
			return false
		var axis_length: float = axis.length()
		if axis_length < 0.9 or axis_length > 1.1:
			return false
	if absf(axes[0].dot(axes[1])) > 0.05 \
			or absf(axes[0].dot(axes[2])) > 0.05 \
			or absf(axes[1].dot(axes[2])) > 0.05:
		return false
	var determinant := value.basis.determinant()
	return is_finite(determinant) and determinant >= 0.8 and determinant <= 1.2

func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _global_to_shared(value: Transform3D) -> Transform3D:
	var shared_origin := _get_shared_space_origin()
	return shared_origin.global_transform.affine_inverse() * value if shared_origin != null else value

func _shared_to_global(value: Transform3D) -> Transform3D:
	var shared_origin := _get_shared_space_origin()
	return shared_origin.global_transform * value if shared_origin != null else value

func _get_shared_space_origin() -> Node3D:
	if is_instance_valid(_shared_space_origin):
		return _shared_space_origin

	var grouped_origin := get_tree().get_first_node_in_group("shared_space_origin") as Node3D
	if grouped_origin != null:
		_shared_space_origin = grouped_origin
		return _shared_space_origin

	var current_scene := get_tree().current_scene
	if current_scene != null:
		var named_origin := current_scene.find_child("SharedSpaceOrigin", true, false) as Node3D
		if named_origin != null:
			_shared_space_origin = named_origin
			return _shared_space_origin

	_shared_space_origin = get_parent() as Node3D
	return _shared_space_origin

func _set_network_avatar_visible(is_visible: bool) -> void:
	for node_path in NETWORK_AVATAR_ROOTS:
		var avatar_root := get_node_or_null(node_path) as Node3D
		if avatar_root != null:
			avatar_root.visible = is_visible

func _apply_role_appearance() -> void:
	var assigned_role := _resolved_session_role()
	var role_color := SKY_ROLE_COLOR
	if assigned_role == ROLE_PC_GROUND:
		role_color = PC_GROUND_ROLE_COLOR
	elif assigned_role == ROLE_GROUND_VR:
		role_color = GROUND_VR_ROLE_COLOR
	for node_path in NETWORK_AVATAR_MESHES:
		var mesh_instance := get_node_or_null(node_path) as MeshInstance3D
		if mesh_instance == null:
			continue
		var material := StandardMaterial3D.new()
		material.albedo_color = role_color
		material.metallic = 0.15
		material.roughness = 0.35
		material.emission_enabled = true
		material.emission = role_color * 0.18
		mesh_instance.material_override = material

	var label := get_node_or_null("NetworkHead/PresenceLabel") as Label3D
	if label != null:
		match assigned_role:
			ROLE_PC_GROUND:
				label.text = "地面端 PC · 在线"
			ROLE_GROUND_VR:
				label.text = "地面端 VR · 在线"
			_:
				label.text = "天上端 %d · 在线" % _get_peer_id_from_name()
		label.modulate = role_color.lightened(0.25)
