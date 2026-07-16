extends Node

const PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const SPAWNER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/Network/multiplayer_spawner.gd")
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
		input_router.call("set_input_mode", PoseState.INPUT_MODE_LEFT_HAND)
		var left_pointer := player.get_node_or_null("XROrigin3D/LeftHand/FunctionPointer")
		var right_pointer := player.get_node_or_null("XROrigin3D/RightHand/FunctionPointer")
		var left_pickup := player.get_node_or_null("XROrigin3D/LeftHand/LeftHand/FunctionPickup")
		var right_pickup := player.get_node_or_null("XROrigin3D/RightHand/RightHand/FunctionPickup")
		_check(bool(left_pointer.get("enabled")) and not bool(right_pointer.get("enabled")), "left mode should expose only the left UI ray")
		_check(bool(left_pickup.get("enabled")) and not bool(right_pickup.get("enabled")), "left mode should expose only the left grab function")
		input_router.call("set_input_mode", PoseState.INPUT_MODE_HEAD_GAZE)
		var gaze_laser := player.get_node_or_null("XROrigin3D/XRCamera3D/HeadGazeLaser") as Node3D
		_check(not bool(left_pointer.get("enabled")) and not bool(right_pointer.get("enabled")), "gaze mode should disable both hand UI rays")
		_check(not bool(left_pickup.get("enabled")) and not bool(right_pickup.get("enabled")), "gaze mode should disable both hand grab functions")
		_check(gaze_laser != null and gaze_laser.visible, "gaze mode should reveal the head ray")
		input_router.call("set_input_mode", PoseState.INPUT_MODE_RIGHT_HAND)
	_check(
		PoseState.normalize(PoseState.from_actions(7, 2, 0.5, 1.0, 0.25, 0.0, 63)).size() == 7,
		"pose gesture schema should stay fixed-size and bounded"
	)

func _finite_vector(value: Variant) -> bool:
	if not (value is Vector3):
		return false
	var vector := value as Vector3
	return is_finite(vector.x) and is_finite(vector.y) and is_finite(vector.z) and vector.length() < 100.0

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
