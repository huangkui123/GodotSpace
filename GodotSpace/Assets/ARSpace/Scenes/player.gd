extends Node3D

const SERVER_PEER_ID: int = 1
const POSE_SEND_INTERVAL: float = 1.0 / 60.0
const TEST_MODE_ARG: String = "--testmode"
const TEST_TRIGGER_KEY := KEY_J
const TEST_GRIP_KEY := KEY_K

const LOCAL_XR_NODE_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D"),
	NodePath("XROrigin3D/XRCamera3D"),
	NodePath("XROrigin3D/LeftHand"),
	NodePath("XROrigin3D/RightHand"),
	NodePath("XROrigin3D/PlayerBody"),
]

const LOCAL_SELF_HIDDEN_VISUAL_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D/XRCamera3D/Head"),
]

const TEST_MODE_HIDDEN_LOCAL_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D/XRCamera3D/Head"),
	NodePath("XROrigin3D/LeftHand"),
	NodePath("XROrigin3D/PlayerBody"),
]

const NETWORK_POSE_PAIRS = [
	[NodePath("XROrigin3D/XRCamera3D"), NodePath("NetworkHead")],
	[NodePath("XROrigin3D/LeftHand"), NodePath("NetworkLeftHand")],
	[NodePath("XROrigin3D/RightHand"), NodePath("NetworkRightHand")],
]

const REMOTE_VISUAL_PAIRS = [
	[NodePath("XROrigin3D/XRCamera3D/Head"), NodePath("NetworkHead"), "RemoteHead"],
	[NodePath("XROrigin3D/LeftHand/LeftHand/Hand_L"), NodePath("NetworkLeftHand"), "RemoteLeftHand"],
	[NodePath("XROrigin3D/RightHand/RightHand/Hand_R"), NodePath("NetworkRightHand"), "RemoteRightHand"],
]

@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D

var _remote_visuals_reparented: bool = false
var _pose_send_seconds: float = 0.0
var _has_received_network_pose: bool = false
var _test_trigger_pressed: bool = false
var _test_grip_pressed: bool = false
var _test_trigger_changed: bool = false
var _test_grip_changed: bool = false

func _enter_tree() -> void:
	var peer_id := _get_peer_id_from_name()
	set_multiplayer_authority(peer_id, true)
	call_deferred("_refresh_authority_configuration")

func _ready() -> void:
	var peer_id := _get_peer_id_from_name()
	set_multiplayer_authority(peer_id, true)
	_configure_local_xr_nodes(_is_local_authority())
	_sync_network_pose_from_xr()

	if _is_local_authority() and not multiplayer.is_server() and not _is_test_mode():
		xr_camera.make_current()

func _process(delta: float) -> void:
	if not _is_local_authority():
		return

	_sync_network_pose_from_xr()
	_pose_send_seconds += delta
	if _pose_send_seconds >= POSE_SEND_INTERVAL:
		_pose_send_seconds = 0.0
		_send_pose_to_server()

	var button_data := {}
	var has_button_pressed := false

	var xr_interface := XRServer.primary_interface
	if xr_interface:
		var left_controller := XRServer.get_tracker("left_hand")
		if left_controller:
			var left_buttons := {}
			var trigger = left_controller.get_input("trigger")
			var grip = left_controller.get_input("grip")
			var primary = left_controller.get_input("primary")
			var secondary = left_controller.get_input("secondary")

			if trigger != null and trigger > 0:
				left_buttons["trigger"] = trigger
				has_button_pressed = true
			if grip != null and grip > 0:
				left_buttons["grip"] = grip
				has_button_pressed = true
			if primary != null and primary:
				left_buttons["primary"] = primary
				has_button_pressed = true
			if secondary != null and secondary:
				left_buttons["secondary"] = secondary
				has_button_pressed = true

			if not left_buttons.is_empty():
				button_data["left_hand"] = left_buttons

		var right_controller := XRServer.get_tracker("right_hand")
		if right_controller:
			var right_buttons := {}
			var trigger = right_controller.get_input("trigger")
			var grip = right_controller.get_input("grip")
			var primary = right_controller.get_input("primary")
			var secondary = right_controller.get_input("secondary")

			if trigger != null and trigger > 0:
				right_buttons["trigger"] = trigger
				rpc_id(1, "trigger_pressed")
				has_button_pressed = true
			if grip != null and grip > 0:
				right_buttons["grip"] = grip
				has_button_pressed = true
			if primary != null and primary:
				right_buttons["primary"] = primary
				has_button_pressed = true
			if secondary != null and secondary:
				right_buttons["secondary"] = secondary
				has_button_pressed = true

			if not right_buttons.is_empty():
				button_data["right_hand"] = right_buttons

	if _is_test_mode():
		var test_right_buttons := _get_test_mode_right_button_data()
		if not test_right_buttons.is_empty():
			var existing_right_buttons: Dictionary = button_data.get("right_hand", {})
			for key in test_right_buttons.keys():
				existing_right_buttons[key] = test_right_buttons[key]
			button_data["right_hand"] = existing_right_buttons
			has_button_pressed = true

	if has_button_pressed and multiplayer.multiplayer_peer:
		var pkt := var_to_bytes(button_data)
		multiplayer.multiplayer_peer.put_packet(pkt)

func _physics_process(_delta: float) -> void:
	if not _is_local_authority():
		return
	_sync_network_pose_from_xr()

func _get_peer_id_from_name() -> int:
	var peer_id := name.to_int()
	if peer_id <= 0:
		return 1
	return peer_id

func _is_local_authority() -> bool:
	if multiplayer.has_multiplayer_peer():
		return is_multiplayer_authority()
	return _get_peer_id_from_name() == 1

func _is_test_mode() -> bool:
	var args := []
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args.has(TEST_MODE_ARG)

func _configure_local_xr_nodes(is_local_authority: bool) -> void:
	var xr_origin := get_node_or_null("XROrigin3D") as XROrigin3D
	var camera := get_node_or_null("XROrigin3D/XRCamera3D") as Camera3D
	var player_body := get_node_or_null("XROrigin3D/PlayerBody")
	var should_own_xr_camera := is_local_authority and not _is_test_mode()

	if xr_origin != null:
		xr_origin.current = should_own_xr_camera
		xr_origin.visible = is_local_authority

	if camera != null:
		camera.current = should_own_xr_camera

	var process_mode_for_nodes := Node.PROCESS_MODE_INHERIT if is_local_authority else Node.PROCESS_MODE_DISABLED
	for node_path in LOCAL_XR_NODE_PATHS:
		var local_node := get_node_or_null(node_path)
		if local_node != null:
			local_node.process_mode = process_mode_for_nodes

	for node_path in LOCAL_SELF_HIDDEN_VISUAL_PATHS:
		var self_visual := get_node_or_null(node_path) as Node3D
		if self_visual != null:
			self_visual.visible = not is_local_authority

	if not is_local_authority:
		_reparent_remote_visuals_to_network_anchors()
		_remove_remote_xr_branch()
	elif _is_test_mode():
		_configure_test_mode_local_visuals()
	_set_network_visuals_visible(not is_local_authority and _has_received_network_pose)

	if player_body != null:
		var player_body_enabled := is_local_authority and not _is_test_mode()
		player_body.set("enabled", player_body_enabled)
		if player_body is CollisionObject3D:
			var collision_body := player_body as CollisionObject3D
			collision_body.collision_layer = 524288 if player_body_enabled else 0
			collision_body.collision_mask = 1023 if player_body_enabled else 0

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

func _refresh_authority_configuration() -> void:
	var peer_id := _get_peer_id_from_name()
	set_multiplayer_authority(peer_id, true)
	_configure_local_xr_nodes(_is_local_authority())
	_sync_network_pose_from_xr()

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

	var right_pointer := get_node_or_null("XROrigin3D/RightHand/FunctionPointer") as Node3D
	if right_pointer != null:
		right_pointer.visible = true
		right_pointer.set("enabled", true)
		right_pointer.set("show_laser", 1)

	var left_pointer := get_node_or_null("XROrigin3D/LeftHand/FunctionPointer") as Node3D
	if left_pointer != null:
		left_pointer.set("enabled", false)
		left_pointer.visible = false

func _get_test_mode_right_button_data() -> Dictionary:
	var right_buttons := {}
	if _test_trigger_pressed or _test_trigger_changed:
		right_buttons["trigger"] = 1.0 if _test_trigger_pressed else 0.0
		right_buttons["trigger_click"] = _test_trigger_pressed
	if _test_grip_pressed or _test_grip_changed:
		right_buttons["grip"] = 1.0 if _test_grip_pressed else 0.0
		right_buttons["grip_click"] = _test_grip_pressed
	_test_trigger_changed = false
	_test_grip_changed = false
	return right_buttons

func _set_test_trigger_pressed(pressed: bool) -> void:
	if _test_trigger_pressed == pressed:
		return

	_test_trigger_pressed = pressed
	_test_trigger_changed = true
	var right_controller := get_node_or_null("XROrigin3D/RightHand") as XRController3D
	if right_controller != null:
		right_controller.emit_signal("button_pressed" if pressed else "button_released", "trigger_click")
	_update_test_hand_pose()

func _set_test_grip_pressed(pressed: bool) -> void:
	if _test_grip_pressed == pressed:
		return

	_test_grip_pressed = pressed
	_test_grip_changed = true
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

func _reparent_remote_visuals_to_network_anchors() -> void:
	if _remote_visuals_reparented:
		return

	var all_visuals_ready := true
	for pair in REMOTE_VISUAL_PAIRS:
		var source_path: NodePath = pair[0]
		var target_path: NodePath = pair[1]
		var visual_name: String = pair[2]
		var target := get_node_or_null(target_path) as Node3D
		if target == null:
			all_visuals_ready = false
			continue

		var visual := target.get_node_or_null(visual_name) as Node3D
		if visual == null:
			visual = get_node_or_null(source_path) as Node3D
		if visual == null:
			all_visuals_ready = false
			continue

		if visual.get_parent() != target:
			var local_transform := visual.transform
			_clear_owner_recursive(visual)
			visual.reparent(target, false)
			visual.transform = local_transform
		visual.name = visual_name
		visual.visible = _should_show_remote_visual_pair(pair)
		target.visible = visual.visible

	_remote_visuals_reparented = all_visuals_ready

func _remove_remote_xr_branch() -> void:
	if not _remote_visuals_reparented:
		return

	var xr_origin := get_node_or_null("XROrigin3D")
	if xr_origin != null:
		xr_origin.queue_free()

func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner_recursive(child)

func _sync_network_pose_from_xr() -> void:
	if not _is_local_authority():
		return

	for pair in NETWORK_POSE_PAIRS:
		var source := get_node_or_null(pair[0]) as Node3D
		var target := get_node_or_null(pair[1]) as Node3D
		if source != null and target != null:
			target.global_transform = source.global_transform

func _send_pose_to_server() -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return

	var head := get_node_or_null("NetworkHead") as Node3D
	var left_hand := get_node_or_null("NetworkLeftHand") as Node3D
	var right_hand := get_node_or_null("NetworkRightHand") as Node3D
	if head == null or left_hand == null or right_hand == null:
		return

	rpc_id(
		SERVER_PEER_ID,
		"_server_receive_pose",
		head.global_transform,
		left_hand.global_transform,
		right_hand.global_transform
	)

@rpc("any_peer", "call_remote", "unreliable")
func _server_receive_pose(head_transform: Transform3D, left_hand_transform: Transform3D, right_hand_transform: Transform3D) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != _get_peer_id_from_name():
		return

	_apply_network_pose(head_transform, left_hand_transform, right_hand_transform)

	for peer_id in multiplayer.get_peers():
		if peer_id != sender_id:
			rpc_id(peer_id, "_client_receive_pose", head_transform, left_hand_transform, right_hand_transform)

@rpc("any_peer", "call_remote", "unreliable")
func _client_receive_pose(head_transform: Transform3D, left_hand_transform: Transform3D, right_hand_transform: Transform3D) -> void:
	if multiplayer.is_server() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if _is_local_authority():
		return

	_apply_network_pose(head_transform, left_hand_transform, right_hand_transform)

func _apply_network_pose(head_transform: Transform3D, left_hand_transform: Transform3D, right_hand_transform: Transform3D) -> void:
	var head := get_node_or_null("NetworkHead") as Node3D
	var left_hand := get_node_or_null("NetworkLeftHand") as Node3D
	var right_hand := get_node_or_null("NetworkRightHand") as Node3D

	if head != null:
		head.global_transform = head_transform
	if left_hand != null:
		left_hand.global_transform = left_hand_transform
	if right_hand != null:
		right_hand.global_transform = right_hand_transform

	_has_received_network_pose = true
	if not _is_local_authority():
		_set_network_visuals_visible(true)

func _set_network_visuals_visible(is_visible: bool) -> void:
	for pair in REMOTE_VISUAL_PAIRS:
		var target := get_node_or_null(pair[1]) as Node3D
		if target == null:
			continue
		var pair_visible := is_visible and _should_show_remote_visual_pair(pair)
		target.visible = pair_visible
		for child in target.get_children():
			if child is Node3D:
				var visual := child as Node3D
				visual.visible = pair_visible

func _should_show_remote_visual_pair(pair: Array) -> bool:
	if not _is_test_mode():
		return true
	if _is_local_authority():
		return true

	return str(pair[2]) == "RemoteRightHand"
