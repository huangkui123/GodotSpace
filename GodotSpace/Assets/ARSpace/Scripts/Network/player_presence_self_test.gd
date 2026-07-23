extends Node

const PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const SPAWNER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/Network/multiplayer_spawner.gd")
const VIEWPORT_2D_IN_3D_SCENE: PackedScene = preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
const PoseState = preload("res://Assets/ARSpace/Characters/Astronaut/avatar_pose_state.gd")

var _failures: Array[String] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	_check(SPAWNER_SCRIPT.can_instantiate(), "multiplayer spawner script should instantiate")
	await _check_server_spawns_local_player()
	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	shared_origin.position = Vector3(10.0, 0.0, -4.0)
	shared_origin.rotation.y = deg_to_rad(30.0)
	shared_origin.add_to_group("shared_space_origin")
	get_tree().root.add_child(shared_origin)

	var ground_player := PLAYER_SCENE.instantiate()
	ground_player.name = "1"
	get_tree().root.add_child(ground_player)
	await get_tree().process_frame
	_check_player_scene_contract(ground_player)
	await _check_pointer_viewport_round_trip(ground_player)
	var ground_label := ground_player.get_node_or_null("NetworkHead/PresenceLabel") as Label3D
	_check(ground_label != null and ground_label.text.contains("地面端 PC"), "peer 1 should use PC Ground label")

	var ground_vr_player := PLAYER_SCENE.instantiate()
	ground_vr_player.name = "6"
	ground_vr_player.call("set_session_role", "ground_vr")
	get_tree().root.add_child(ground_vr_player)
	_check(
		ground_vr_player.get_node_or_null("XROrigin3D") == null,
		"directly instantiated remote players must strip XR before child _enter_tree"
	)
	await get_tree().process_frame
	var ground_vr_label := ground_vr_player.get_node_or_null("NetworkHead/PresenceLabel") as Label3D
	_check(ground_vr_label != null and ground_vr_label.text.contains("地面端 VR"), "assigned Ground VR should use Ground VR label")
	var ground_vr_mesh := ground_vr_player.get_node_or_null("NetworkHead/HeadMesh") as MeshInstance3D
	var ground_vr_material: StandardMaterial3D = null
	if ground_vr_mesh != null:
		ground_vr_material = ground_vr_mesh.material_override as StandardMaterial3D
	_check(
		ground_vr_material != null and ground_vr_material.albedo_color.is_equal_approx(Color(0.22, 0.95, 0.55, 1.0)),
		"assigned Ground VR should use the Ground VR color"
	)

	var astronaut_player := PLAYER_SCENE.instantiate()
	astronaut_player.name = "7"
	get_tree().root.add_child(astronaut_player)
	await get_tree().process_frame
	var astronaut_label := astronaut_player.get_node_or_null("NetworkHead/PresenceLabel") as Label3D
	_check(astronaut_label != null and astronaut_label.text.contains("航天端 7"), "remote peer should use astronaut label")

	var head := Transform3D(Basis.IDENTITY, Vector3(1.0, 1.7, -2.0))
	var left_hand := Transform3D(Basis.IDENTITY, Vector3(0.7, 1.3, -2.2))
	var right_hand := Transform3D(Basis.IDENTITY, Vector3(1.3, 1.3, -2.2))
	_check(bool(astronaut_player.call("_is_valid_pose_transform", head)), "finite unit pose should be accepted")
	var invalid_pose := Transform3D(Basis.IDENTITY, Vector3(2000.0, 0.0, 0.0))
	_check(not bool(astronaut_player.call("_is_valid_pose_transform", invalid_pose)), "out-of-range pose should be rejected")
	var mirrored_pose := Transform3D(Basis(Vector3.LEFT, Vector3.UP, Vector3.BACK), Vector3.ZERO)
	_check(not bool(astronaut_player.call("_is_valid_pose_transform", mirrored_pose)), "mirrored pose bases should be rejected")
	var sheared_pose := Transform3D(Basis(Vector3.RIGHT, Vector3(0.2, 1.0, 0.0), Vector3.BACK), Vector3.ZERO)
	_check(not bool(astronaut_player.call("_is_valid_pose_transform", sheared_pose)), "sheared pose bases should be rejected")
	ground_player.set("_replica_ready_peer_ids", {7: true})
	ground_player.call("_on_peer_disconnected", 7)
	_check(not (ground_player.get("_replica_ready_peer_ids") as Dictionary).has(7), "disconnect should clear replica-ready state")
	_check(bool(astronaut_player.call("_accept_remote_pose", 4, head, left_hand, right_hand)), "new pose sequence should be accepted")
	_check(not bool(astronaut_player.call("_accept_remote_pose", 4, head, left_hand, right_hand)), "duplicate pose sequence should be rejected")
	var invalid_pose_state := PoseState.make_default()
	invalid_pose_state["right_trigger_q"] = 256
	_check(
		not bool(astronaut_player.call("_accept_remote_pose", 5, head, left_hand, right_hand, invalid_pose_state)),
		"out-of-range gesture state should be rejected before advancing the pose sequence"
	)
	var tracked_pose_state := PoseState.from_actions(
		PoseState.TRACKING_HEAD | PoseState.TRACKING_RIGHT_HAND,
		PoseState.INPUT_MODE_RIGHT_HAND,
		0.0,
		0.0,
		0.8,
		0.5,
		PoseState.GESTURE_RIGHT_TRIGGER_CLICK
	)
	_check(
		bool(astronaut_player.call("_accept_remote_pose", 5, head, left_hand, right_hand, tracked_pose_state)),
		"bounded tracking and gesture state should extend the existing unreliable pose packet"
	)
	_check(
		astronaut_player.get("_last_applied_pose_state") == tracked_pose_state,
		"accepted pose state should be available to the remote avatar"
	)
	var network_head := astronaut_player.get_node_or_null("NetworkHead") as Node3D
	_check(network_head != null and network_head.visible, "accepted pose should reveal remote avatar")
	var expected_global_head := shared_origin.global_transform * head.origin
	_check(network_head != null and network_head.global_position.is_equal_approx(expected_global_head), "shared-space pose should respect a transformed SharedSpaceOrigin")

	ground_player.queue_free()
	ground_vr_player.queue_free()
	astronaut_player.queue_free()
	shared_origin.queue_free()
	await get_tree().process_frame

	if _failures.is_empty():
		print("PLAYER_PRESENCE_SELF_TEST PASS")
		get_tree().quit(0)
		return

	for failure in _failures:
		push_error("PLAYER_PRESENCE_SELF_TEST: %s" % failure)
	get_tree().quit(1)

func _check_server_spawns_local_player() -> void:
	var peer := ENetMultiplayerPeer.new()
	var create_error := peer.create_server(0, 2)
	_check(create_error == OK, "loopback ENet server should start")
	if create_error != OK:
		return

	get_tree().root.multiplayer.multiplayer_peer = peer
	var world := Node3D.new()
	world.name = "SpawnerTestWorld"
	get_tree().root.add_child(world)
	var spawner := SPAWNER_SCRIPT.new() as MultiplayerSpawner
	spawner.name = "MultiplayerSpawner"
	spawner.spawn_path = NodePath("..")
	spawner.network_player = PLAYER_SCENE
	world.add_child(spawner)
	await get_tree().process_frame
	await get_tree().process_frame

	var server_player := world.get_node_or_null("1")
	_check(server_player != null, "server should create peer 1 player when spawner becomes ready")
	spawner.spawn_player(1)
	await get_tree().process_frame
	_check(world.get_node_or_null("1") == server_player, "duplicate peer 1 spawn should be ignored")
	spawner.spawn_player(2)
	await get_tree().process_frame
	var remote_player := world.get_node_or_null("2")
	_check(remote_player != null, "test peer should spawn before disconnect cleanup")
	_check(
		remote_player != null and remote_player.get_node_or_null("XROrigin3D") == null,
		"remote player XR branch must be removed before it enters the SceneTree"
	)
	spawner.remove_player(2)
	_check(world.get_node_or_null("2") == null, "disconnect cleanup should remove the stale player immediately")

	world.queue_free()
	await get_tree().process_frame
	peer.close()
	get_tree().root.multiplayer.multiplayer_peer = null

func _check_player_scene_contract(player: Node) -> void:
	for path in [
		"NetworkHead/HeadMesh",
		"NetworkHead/FacingIndicator",
		"NetworkHead/PresenceLabel",
		"NetworkLeftHand/HandMesh",
		"NetworkRightHand/HandMesh",
		"NetworkTorso/TorsoMesh",
	]:
		_check(player.get_node_or_null(path) != null, "missing player presence node: %s" % path)
	var avatar := player.get_node_or_null("AstronautAvatar")
	_check(avatar != null, "player should contain the unified astronaut avatar")
	if avatar != null:
		_check(bool(avatar.call("is_model_ready")), "astronaut avatar should bind all required skeleton bones")
		var debug := avatar.call("get_debug_state") as Dictionary
		_check(int(debug.get("bone_count", 0)) == 33, "astronaut FBX should retain the audited 33-bone skeleton")
		var skeleton := _find_skeleton(avatar)
		if skeleton != null:
			var spine_index := skeleton.find_bone("Spine2TMP")
			var spine_pose := skeleton.get_bone_global_pose(spine_index)
			_check(
				_is_orthonormal_basis(spine_pose.basis),
				"astronaut torso override must not inherit FBX unit-conversion scale"
			)
			var rest_bounds := _get_skeleton_rest_bounds(skeleton)
			_check(
				rest_bounds.size.y >= 1.6 and rest_bounds.size.y <= 2.1,
				"astronaut imported rest height should stay in human-scale meters"
			)
		var imported_model := avatar.get_node_or_null("ImportedModel")
		if imported_model != null:
			for disabled_mesh_name in ["DETAIL", "PANT", "STRIP"]:
				var disabled_mesh := imported_model.find_child(disabled_mesh_name, true, false) as MeshInstance3D
				_check(
					disabled_mesh != null and not disabled_mesh.visible,
					"astronaut should match Unity prefab disabled mesh: %s" % disabled_mesh_name
				)
			for enabled_mesh_name in ["Basemesh", "TORSO", "HELMET_GLASS", "HELMET", "GLOVES"]:
				var enabled_mesh := imported_model.find_child(enabled_mesh_name, true, false) as MeshInstance3D
				_check(
					enabled_mesh != null and enabled_mesh.get_surface_override_material(0) != null,
					"astronaut should bind the Unity material contract: %s" % enabled_mesh_name
				)
		var left_solution := avatar.call(
			"solve_two_bone_positions",
			Vector3(-0.2, 1.5, 0.0),
			Vector3(-0.55, 1.15, -0.2),
			0.32,
			0.30,
			true
		) as Dictionary
		var right_solution := avatar.call(
			"solve_two_bone_positions",
			Vector3(0.2, 1.5, 0.0),
			Vector3(0.55, 1.15, -0.2),
			0.32,
			0.30,
			false
		) as Dictionary
		_check(_finite_vector(left_solution.get("elbow")), "left arm solver should remain finite")
		_check(_finite_vector(right_solution.get("elbow")), "right arm solver should remain finite")
		_check(float(left_solution.get("reach_ratio", 2.0)) <= 0.985, "left arm reach should remain bounded")
		_check(float(right_solution.get("reach_ratio", 2.0)) <= 0.985, "right arm reach should remain bounded")
	var input_router := player.get_node_or_null("XROrigin3D/XRInputRouter")
	_check(input_router != null, "local XR branch should expose one unified input router")
	if input_router != null:
		_check(
			int(input_router.call("resolve_mode_for_tracking", PoseState.INPUT_MODE_RIGHT_HAND, PoseState.TRACKING_HEAD)) \
				== PoseState.INPUT_MODE_HEAD_GAZE,
			"controller tracking loss should fall back to head gaze"
		)
		input_router.call("set_test_input", 0.0, 0.0, false)
		input_router.call("set_input_mode", PoseState.INPUT_MODE_RIGHT_HAND)
		_check(
			int(input_router.call("get_input_mode")) == PoseState.INPUT_MODE_HEAD_GAZE,
			"untracked preferred hand should temporarily use gaze"
		)
		input_router.call("set_test_input", 0.0, 0.0, true)
		input_router.call("_process", 0.0)
		_check(
			int(input_router.call("get_input_mode")) == PoseState.INPUT_MODE_RIGHT_HAND,
			"preferred hand pointer should recover when startup tracking becomes available"
		)
		input_router.call("set_input_mode", PoseState.INPUT_MODE_LEFT_HAND)
		var left_pointer := player.get_node_or_null("XROrigin3D/LeftHand/FunctionPointer")
		var right_pointer := player.get_node_or_null("XROrigin3D/RightHand/FunctionPointer")
		var left_pickup := player.get_node_or_null("XROrigin3D/LeftHand/LeftHand/FunctionPickup")
		var right_pickup := player.get_node_or_null("XROrigin3D/RightHand/RightHand/FunctionPickup")
		_check(bool(left_pointer.get("enabled")) and not bool(right_pointer.get("enabled")), "left mode should expose only the left UI ray")
		_check(bool(left_pickup.get("enabled")) and not bool(right_pickup.get("enabled")), "left mode should expose only the left grab function")
		input_router.call("set_input_mode", PoseState.INPUT_MODE_HEAD_GAZE)
		var gaze_pointer := player.get_node_or_null("XROrigin3D/XRCamera3D/HeadGazePointer") as Node3D
		_check(not bool(left_pointer.get("enabled")) and not bool(right_pointer.get("enabled")), "gaze mode should disable both hand UI rays")
		_check(not bool(left_pickup.get("enabled")) and not bool(right_pickup.get("enabled")), "gaze mode should disable both hand grab functions")
		_check(
			gaze_pointer != null \
				and gaze_pointer.visible \
				and bool(gaze_pointer.get("enabled")) \
				and not bool(gaze_pointer.get("follow_active_controller")),
			"gaze mode should expose a camera-anchored interactive pointer"
		)
		input_router.call("set_input_mode", PoseState.INPUT_MODE_RIGHT_HAND)
		input_router.call("set_test_input", 0.8, 0.0, true)
		input_router.call("_process", 0.0)
		_check(
			bool(input_router.get("_pointer_select_pressed")),
			"analog PICO trigger should synthesize pointer press above threshold"
		)
		input_router.call("set_test_input", 0.2, 0.0, true)
		input_router.call("_process", 0.0)
		_check(
			not bool(input_router.get("_pointer_select_pressed")),
			"analog PICO trigger should release pointer below hysteresis threshold"
		)
	_check(
		PoseState.normalize(PoseState.from_actions(7, 2, 0.5, 1.0, 0.25, 0.0, 63)).size() == 7,
		"pose gesture schema should stay fixed-size and bounded"
	)

func _check_pointer_viewport_round_trip(player: Node) -> void:
	var xr_origin := player.get_node_or_null("XROrigin3D") as Node3D
	var xr_camera := player.get_node_or_null("XROrigin3D/XRCamera3D") as XRCamera3D
	var right_controller := player.get_node_or_null("XROrigin3D/RightHand") as XRController3D
	var right_pointer := player.get_node_or_null("XROrigin3D/RightHand/FunctionPointer") as Node3D
	var gaze_pointer := player.get_node_or_null("XROrigin3D/XRCamera3D/HeadGazePointer") as Node3D
	var input_router := player.get_node_or_null("XROrigin3D/XRInputRouter")
	if xr_origin == null \
			or xr_camera == null \
			or right_controller == null \
			or right_pointer == null \
			or gaze_pointer == null \
			or input_router == null:
		_check(false, "pointer integration test requires the local XR input branch")
		return

	get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	xr_origin.process_mode = Node.PROCESS_MODE_INHERIT
	xr_camera.process_mode = Node.PROCESS_MODE_INHERIT
	xr_origin.visible = true
	right_controller.transform = Transform3D.IDENTITY
	input_router.call("set_test_input", 0.0, 0.0, true)
	input_router.call("set_input_mode", PoseState.INPUT_MODE_RIGHT_HAND)

	var button := Button.new()
	button.name = "PointerTestButton"
	button.text = "Pointer test"
	button.size = Vector2(300.0, 200.0)
	var button_scene := PackedScene.new()
	_check(button_scene.pack(button) == OK, "pointer test button scene should pack")
	button.free()

	var viewport_window := VIEWPORT_2D_IN_3D_SCENE.instantiate() as Node3D
	viewport_window.name = "PointerViewport"
	viewport_window.set("screen_size", Vector2(1.2, 0.8))
	viewport_window.set("viewport_size", Vector2(300.0, 200.0))
	viewport_window.set("scene", button_scene)
	var adapter_marker := Node.new()
	adapter_marker.name = "SpatialWindowAdapter"
	viewport_window.add_child(adapter_marker)
	get_tree().root.add_child(viewport_window)
	await get_tree().process_frame

	var ray_origin := right_pointer.global_transform.origin
	var ray_forward := -right_pointer.global_transform.basis.z.normalized()
	viewport_window.global_transform = Transform3D(
		right_pointer.global_transform.basis.orthonormalized(),
		ray_origin + ray_forward * 1.5
	)
	var event_counts := {"pressed": 0, "gui": 0, "pointer": 0}
	var viewport_button := viewport_window.call("get_scene_instance") as Button
	if viewport_button != null:
		viewport_button.pressed.connect(func() -> void: event_counts["pressed"] += 1)
		viewport_button.gui_input.connect(func(_event: InputEvent) -> void: event_counts["gui"] += 1)
	if right_pointer.has_signal("pointing_event"):
		right_pointer.connect("pointing_event", func(_event: Variant) -> void: event_counts["pointer"] += 1)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var ray_cast := right_pointer.get_node_or_null("RayCast") as RayCast3D
	if ray_cast != null:
		ray_cast.force_raycast_update()
	_check(
		ray_cast != null and ray_cast.is_colliding(),
		"right XR pointer should hit the 2D-in-3D viewport collision body"
	)

	input_router.call("set_test_input", 0.8, 0.0, true)
	input_router.call("_process", 0.0)
	var selection_after_press := bool(input_router.get("_pointer_select_pressed"))
	var pointer_enabled_after_press := bool(right_pointer.get("enabled"))
	var mode_after_press := int(input_router.call("get_input_mode"))
	await get_tree().process_frame
	input_router.call("set_test_input", 0.2, 0.0, true)
	input_router.call("_process", 0.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(
		int(event_counts["pressed"]) == 1,
		"PICO analog trigger should click a real SubViewport Button exactly once (pressed=%d gui=%d pointer=%d selected=%s enabled=%s mode=%d collision=%s)" \
			% [
				int(event_counts["pressed"]),
				int(event_counts["gui"]),
				int(event_counts["pointer"]),
				selection_after_press,
				pointer_enabled_after_press,
				mode_after_press,
				ray_cast.is_colliding() if ray_cast != null else false,
			]
	)

	input_router.call("set_input_mode", PoseState.INPUT_MODE_HEAD_GAZE)
	var gaze_origin := gaze_pointer.global_transform.origin
	var gaze_forward := -gaze_pointer.global_transform.basis.z.normalized()
	viewport_window.global_transform = Transform3D(
		gaze_pointer.global_transform.basis.orthonormalized(),
		gaze_origin + gaze_forward * 1.5
	)
	await get_tree().physics_frame
	var gaze_ray_cast := gaze_pointer.get_node_or_null("RayCast") as RayCast3D
	if gaze_ray_cast != null:
		gaze_ray_cast.force_raycast_update()
	_check(
		gaze_ray_cast != null and gaze_ray_cast.is_colliding(),
		"head-gaze pointer should hit the 2D-in-3D viewport collision body"
	)
	input_router.call("set_test_input", 0.8, 0.0, true)
	input_router.call("_process", 0.0)
	await get_tree().process_frame
	input_router.call("set_test_input", 0.2, 0.0, true)
	input_router.call("_process", 0.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(
		int(event_counts["pressed"]) == 2,
		"PICO trigger should click the same SubViewport Button once through the head-gaze pointer"
	)

	viewport_window.queue_free()
	await get_tree().process_frame
	get_tree().root.multiplayer.multiplayer_peer = null

func _finite_vector(value: Variant) -> bool:
	if not (value is Vector3):
		return false
	var vector := value as Vector3
	return is_finite(vector.x) and is_finite(vector.y) and is_finite(vector.z) and vector.length() < 100.0

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null

func _is_orthonormal_basis(basis: Basis) -> bool:
	var scale := basis.get_scale()
	return is_equal_approx(scale.x, 1.0) \
		and is_equal_approx(scale.y, 1.0) \
		and is_equal_approx(scale.z, 1.0) \
		and is_equal_approx(absf(basis.determinant()), 1.0)

func _get_skeleton_rest_bounds(skeleton: Skeleton3D) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for bone_index in skeleton.get_bone_count():
		var world_position := skeleton.global_transform * skeleton.get_bone_global_rest(bone_index).origin
		minimum = minimum.min(world_position)
		maximum = maximum.max(world_position)
	return AABB(minimum, maximum - minimum)

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
