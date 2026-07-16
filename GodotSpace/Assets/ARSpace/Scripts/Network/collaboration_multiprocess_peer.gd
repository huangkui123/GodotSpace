extends Node

const PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const SPAWNER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/Network/multiplayer_spawner.gd")
const ANNOTATION_MANAGER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_manager.gd")
const ROLE_ARG: String = "--collab-process-role="
const PORT_ARG: String = "--collab-process-port="
const SCENARIO_ARG: String = "--collab-process-scenario="
const CONTROL_DIR_ARG: String = "--collab-control-dir="
const DEFAULT_PORT: int = 43280
const STAGE_TIMEOUT_MSEC: int = 12000
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_ASTRONAUT: String = "astronaut"
const FIRST_ANNOTATION_TEXT: String = "Ground VR initial annotation"
const SECOND_ANNOTATION_TEXT: String = "Ground VR reconnected annotation"
const FORGED_ASTRONAUT_ANNOTATION_TEXT: String = "Astronaut forged annotation"

var _role: String = ""
var _scenario: String = "baseline"
var _port: int = DEFAULT_PORT
var _control_dir: String = ""
var _world: Node3D
var _peer: ENetMultiplayerPeer
var _annotation_manager: Node
var _failures: Array[String] = []


func _ready() -> void:
	_disable_unrelated_services()
	_role = _get_user_arg(ROLE_ARG).to_lower()
	var scenario_value := _get_user_arg(SCENARIO_ARG).to_lower()
	if not scenario_value.is_empty():
		_scenario = scenario_value
	var port_text := _get_user_arg(PORT_ARG)
	if port_text.is_valid_int():
		_port = int(port_text)
	_control_dir = _get_user_arg(CONTROL_DIR_ARG)
	call_deferred("_run")


func _disable_unrelated_services() -> void:
	# This harness owns the multiplayer peer directly and only exercises player
	# replication. Disable audio/LLM processing so offline reconnect intervals do
	# not make unrelated autoloads sample an intentionally detached peer.
	for service_path in [NodePath("/root/VoiceChat"), NodePath("/root/LLMAssistantService")]:
		var service := get_node_or_null(service_path)
		if service != null:
			service.process_mode = Node.PROCESS_MODE_DISABLED


func _run() -> void:
	match _scenario:
		"baseline":
			await _run_baseline_scenario()
		"astronaut_first":
			await _run_astronaut_first_scenario()
		"ground_contention":
			await _run_ground_contention_scenario()
		_:
			_failures.append("Unknown collaboration process scenario: %s" % _scenario)
	await _finish()


func _run_baseline_scenario() -> void:
	match _role:
		"server":
			await _run_server()
		"ground_client", "first_client":
			await _run_ground_client()
		"astronaut_client", "late_client":
			await _run_astronaut_client()
		_:
			_failures.append("Unknown collaboration process role: %s" % _role)


func _run_astronaut_first_scenario() -> void:
	match _role:
		"server":
			await _run_order_server()
		"astronaut_client":
			await _run_order_astronaut_client()
		"ground_client":
			await _run_order_ground_client()
		_:
			_failures.append("Unknown astronaut-first process role: %s" % _role)


func _run_ground_contention_scenario() -> void:
	match _role:
		"server":
			await _run_contention_server()
		"ground_client":
			await _run_contention_first_ground()
		"competing_ground_client":
			await _run_contention_second_ground()
		_:
			_failures.append("Unknown Ground contention process role: %s" % _role)


func _start_scenario_server() -> bool:
	_peer = ENetMultiplayerPeer.new()
	_check(_peer.create_server(_port, 2, 3) == OK, "server should bind port %d" % _port)
	if not _failures.is_empty():
		return false
	multiplayer.multiplayer_peer = _peer
	_world = _create_world("ServerWorld")
	_check(_write_control_marker("server.ready"), "server should publish its ready marker")
	return true


func _run_order_server() -> void:
	if not _start_scenario_server():
		return
	_check(await _wait_for_player_count(2), "astronaut-first server should observe the Astronaut before Ground VR")
	_check(await _wait_for_role_count(2), "astronaut-first server should receive the first role assignment")
	_check(_count_role(ROLE_ASTRONAUT) == 1, "first non-server peer should remain Astronaut")
	_check(_count_role(ROLE_GROUND_VR) == 0, "Ground VR slot must stay empty before the Ground peer joins")
	_check(await _wait_for_player_count(3), "astronaut-first server should later observe Ground VR")
	_check(
		await _wait_for_role_distribution(1, 1, 1),
		"astronaut-first server should register the resolved PC/Ground/Astronaut roles"
	)
	_check(_count_role(ROLE_PC_GROUND) == 1, "astronaut-first session should keep one PC Ground")
	_check(_count_role(ROLE_GROUND_VR) == 1, "astronaut-first session should assign one Ground VR")
	_check(_count_role(ROLE_ASTRONAUT) == 1, "astronaut-first session should keep one Astronaut")
	_check(await _wait_for_player_roles(), "astronaut-first player replicas should match authoritative roles")
	_check(await _wait_for_remote_avatars(2), "astronaut-first server should receive both remote poses")
	_check(await _wait_for_control_marker("astronaut_client.done"), "astronaut-first client should finish before Server shutdown")
	_check(await _wait_for_control_marker("ground_client.done"), "late Ground client should finish before Server shutdown")
	_close_server_and_publish_marker()


func _run_order_astronaut_client() -> void:
	_check(await _connect_client("AstronautFirstWorld"), "astronaut-first client should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_local_role(ROLE_ASTRONAUT), "first client should be assigned Astronaut")
	_check(await _wait_for_player_count(2), "first Astronaut should initially see PC Ground")
	_check(_write_control_marker("first_client.ready"), "first Astronaut should publish its role-ready marker")
	_check(await _wait_for_player_count(3), "first Astronaut should later observe Ground VR")
	_check(await _wait_for_role_count(3), "first Astronaut should receive the complete role snapshot")
	_check(await _wait_for_player_roles(), "first Astronaut replicas should match authoritative roles")
	_check(await _wait_for_remote_avatars(2), "first Astronaut should receive both Ground poses")
	_check(_write_control_marker("astronaut_client.done"), "first Astronaut should publish its completion marker")
	_check(await _wait_for_server_shutdown(), "first Astronaut should observe Server transport shutdown")


func _run_order_ground_client() -> void:
	_check(await _connect_client("LateGroundWorld"), "late Ground VR should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_local_role(ROLE_GROUND_VR), "late Ground should acquire the available Ground VR slot")
	_check(await _wait_for_player_count(3), "late Ground should receive all existing players")
	_check(await _wait_for_role_count(3), "late Ground should receive all session roles")
	_check(await _wait_for_player_roles(), "late Ground replicas should match authoritative roles")
	_check(await _wait_for_remote_avatars(2), "late Ground should receive PC Ground and Astronaut poses")
	_check(_write_control_marker("ground_client.done"), "late Ground should publish its completion marker")
	_check(await _wait_for_server_shutdown(), "late Ground should observe Server transport shutdown")


func _run_contention_server() -> void:
	if not _start_scenario_server():
		return
	_check(await _wait_for_player_count(3), "contention server should observe both Ground claimants")
	_check(
		await _wait_for_role_distribution(1, 1, 1),
		"contention server should resolve exactly one Ground claimant and one downgraded Astronaut"
	)
	_check(_count_role(ROLE_PC_GROUND) == 1, "contention session should keep one PC Ground")
	_check(_count_role(ROLE_GROUND_VR) == 1, "contention session must grant exactly one Ground VR slot")
	_check(_count_role(ROLE_ASTRONAUT) == 1, "second Ground claimant must be downgraded to Astronaut")
	_check(await _wait_for_player_roles(), "contention player replicas should match authoritative roles")
	_check(await _wait_for_remote_avatars(2), "contention server should receive both remote poses")
	_check(await _wait_for_control_marker("ground_client.done"), "first Ground claimant should finish before Server shutdown")
	_check(await _wait_for_control_marker("competing_ground_client.done"), "competing Ground claimant should finish before Server shutdown")
	_check(int(_annotation_manager.call("get_annotation_count")) == 0, "downgraded claimant must not forge a Ground-only annotation")
	_close_server_and_publish_marker()


func _run_contention_first_ground() -> void:
	_check(await _connect_client("FirstGroundWorld"), "first Ground claimant should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_local_role(ROLE_GROUND_VR), "first Ground claimant should receive the Ground VR slot")
	_check(_write_control_marker("first_client.ready"), "first Ground claimant should publish its role-ready marker")
	_check(await _wait_for_player_count(3), "first Ground claimant should observe its competitor")
	_check(await _wait_for_role_count(3), "first Ground claimant should receive resolved roles")
	var network_handler := _get_network_handler()
	_check(network_handler != null and bool(network_handler.call("can_peer_annotate", multiplayer.get_unique_id())), "assigned Ground claimant should keep Ground-only permission")
	_check(_write_control_marker("ground_client.done"), "first Ground claimant should publish its completion marker")
	_check(await _wait_for_server_shutdown(), "first Ground claimant should observe Server transport shutdown")


func _run_contention_second_ground() -> void:
	_check(await _connect_client("CompetingGroundWorld"), "second Ground claimant should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_local_role(ROLE_ASTRONAUT), "second Ground claimant should be downgraded to Astronaut")
	_check(await _wait_for_player_count(3), "downgraded claimant should still receive all players")
	_check(await _wait_for_role_count(3), "downgraded claimant should receive resolved roles")
	var network_handler := _get_network_handler()
	_check(network_handler != null and not bool(network_handler.call("can_peer_annotate", multiplayer.get_unique_id())), "downgraded claimant must lose Ground-only permission")
	_check(
		int(_annotation_manager.call("create_annotation", _make_draft("Downgraded local forge", Vector3.ZERO))) == -1,
		"downgraded claimant should be denied before a local Ground-only request"
	)
	_annotation_manager.rpc_id(1, "_server_create_annotation", 1, _make_draft("Downgraded RPC forge", Vector3.ZERO))
	await _wait_frames(30)
	_check(int(_annotation_manager.call("get_annotation_count")) == 0, "Server should reject downgraded claimant RPCs")
	_check(_write_control_marker("competing_ground_client.done"), "competing Ground claimant should publish its completion marker")
	_check(await _wait_for_server_shutdown(), "competing Ground claimant should observe Server transport shutdown")


func _run_server() -> void:
	_peer = ENetMultiplayerPeer.new()
	_check(_peer.create_server(_port, 2, 3) == OK, "server should bind port %d" % _port)
	if not _failures.is_empty():
		return
	multiplayer.multiplayer_peer = _peer
	_world = _create_world("ServerWorld")
	_check(_write_control_marker("server.ready"), "server should publish its ready marker")
	_check(await _wait_for_player_count(2), "server should observe the Ground VR client")
	var first_ground_peer_id := await _wait_for_ground_vr_peer()
	_check(first_ground_peer_id > 1, "server should authoritatively assign the Ground VR role")
	_check(await _wait_for_annotation_count(1), "server should accept the Ground VR annotation")
	_check(
		_annotation_creator(FIRST_ANNOTATION_TEXT) == first_ground_peer_id,
		"server should record the authenticated Ground VR creator"
	)

	_check(await _wait_for_player_count(3), "server should observe the Astronaut client")
	_check(await _wait_for_role_distribution(1, 1, 1), "server should register all three resolved session roles")
	_check(_count_role(ROLE_PC_GROUND) == 1, "server should keep exactly one PC Ground role")
	_check(_count_role(ROLE_GROUND_VR) == 1, "server should keep exactly one Ground VR role")
	_check(_count_role(ROLE_ASTRONAUT) == 1, "server should keep exactly one Astronaut role")
	_check(await _wait_for_player_roles(), "server player replicas should match the role registry")
	_check(await _wait_for_remote_avatars(2), "server should receive both remote player poses")

	_check(await _wait_for_player_count(2), "server should remove the disconnected Ground VR client")
	_check(await _wait_for_ground_vr_release(), "server should release the Ground VR slot after disconnect")
	_check(int(_annotation_manager.call("get_annotation_count")) == 1, "Ground VR disconnect should retain session annotations")

	_check(await _wait_for_player_count(3), "server should observe the reconnected Ground VR client")
	var reconnected_ground_peer_id := await _wait_for_ground_vr_peer(first_ground_peer_id)
	_check(reconnected_ground_peer_id > 1, "server should reassign the released Ground VR slot")
	_check(await _wait_for_annotation_count(2), "server should accept a post-reconnect Ground VR annotation")
	_check(
		_annotation_creator(SECOND_ANNOTATION_TEXT) == reconnected_ground_peer_id,
		"server should bind the second annotation to the reconnected Ground VR peer"
	)
	_check(_has_unique_annotations(), "server should end with two unique authoritative annotations")
	_check(await _wait_for_player_roles(), "server reconnect replicas should match the role registry")
	_check(await _wait_for_remote_avatars(2), "server should receive reconnected remote poses")
	_check(_has_unique_player_names(), "server should end with unique player instances")
	_check(await _wait_for_control_marker("ground_client.done"), "Ground reconnect assertions should finish before Server shutdown")
	_check(await _wait_for_control_marker("astronaut_client.done"), "Astronaut reconnect assertions should finish before Server shutdown")
	_close_server_and_publish_marker()


func _run_ground_client() -> void:
	_check(await _connect_client("GroundClientWorld"), "Ground VR client should connect")
	if not _failures.is_empty():
		return
	var first_peer_id := _peer.get_unique_id()
	_check(await _wait_for_local_role(ROLE_GROUND_VR), "Ground VR client should receive its Server-assigned role")
	_check(await _wait_for_player_count(2), "Ground VR client should initially see itself and PC Ground")
	_check(await _wait_for_player_roles(), "Ground VR replicas should match the first role snapshot")
	_check(await _wait_for_remote_avatars(1), "Ground VR should receive the PC Ground pose")
	_check(
		int(_annotation_manager.call("create_annotation", _make_draft(FIRST_ANNOTATION_TEXT, Vector3(1.0, 0.5, -2.0)))) == 0,
		"Ground VR create should be queued to Server authority"
	)
	_check(await _wait_for_annotation_count(1), "Ground VR should receive its confirmed annotation")
	_check(_annotation_text_count(FIRST_ANNOTATION_TEXT) == 1, "Ground VR should render its annotation once")
	_check(_write_control_marker("first_client.ready"), "Ground VR should publish the first authoritative annotation checkpoint")

	_check(await _wait_for_player_count(3), "Ground VR client should observe the Astronaut client")
	_check(await _wait_for_role_count(3), "Ground VR should receive the three-role snapshot")
	_check(await _wait_for_player_roles(), "Ground VR should identify PC Ground and Astronaut replicas")
	_check(await _wait_for_remote_avatars(2), "Ground VR should receive PC Ground and Astronaut poses")
	_check(
		await _wait_for_control_marker("astronaut_client.initial_done"),
		"Ground VR should wait for the Astronaut authorization checks before disconnecting"
	)
	var old_peer_id := _peer.get_unique_id()
	_disconnect_and_free_world()
	await get_tree().create_timer(1.0).timeout
	_check(await _connect_client("ReconnectedGroundClientWorld"), "Ground VR client should reconnect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_local_role(ROLE_GROUND_VR), "reconnected client should reclaim the Ground VR role")
	_check(await _wait_for_player_count(3), "reconnected Ground VR should receive the current player snapshot")
	_check(await _wait_for_annotation_count(1), "reconnected Ground VR should receive the annotation snapshot")
	_check(_annotation_text_count(FIRST_ANNOTATION_TEXT) == 1, "reconnect snapshot should contain no duplicate annotation")
	var new_peer_id := _peer.get_unique_id()
	if new_peer_id != old_peer_id:
		_check(_world.get_node_or_null(str(old_peer_id)) == null, "reconnected Ground VR should not retain its stale player id")
	_check(
		int(_annotation_manager.call("create_annotation", _make_draft(SECOND_ANNOTATION_TEXT, Vector3(-1.0, 1.0, -3.0)))) == 0,
		"reconnected Ground VR create should be queued to Server authority"
	)
	_check(await _wait_for_annotation_count(2), "reconnected Ground VR should receive the second annotation")
	_check(_has_unique_annotations(), "reconnected Ground VR should end with two unique annotations")
	_check(await _wait_for_player_roles(), "reconnected Ground VR replicas should match the role registry")
	_check(await _wait_for_remote_avatars(2), "reconnected Ground VR should receive both remote poses")
	_check(_has_unique_player_names(), "reconnected Ground VR should end with unique player instances")
	_check(first_peer_id == old_peer_id, "Ground VR peer identity should remain stable before disconnect")
	_check(_write_control_marker("ground_client.done"), "reconnected Ground VR should publish its completion marker")
	_check(await _wait_for_server_shutdown(), "reconnected Ground VR should observe Server transport shutdown")


func _run_astronaut_client() -> void:
	_check(await _connect_client("AstronautClientWorld"), "Astronaut client should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_local_role(ROLE_ASTRONAUT), "Astronaut client should receive its Server-assigned role")
	_check(await _wait_for_player_count(3), "Astronaut client should receive all existing players")
	_check(await _wait_for_role_count(3), "Astronaut client should receive all session roles")
	_check(await _wait_for_annotation_count(1), "late Astronaut client should receive the annotation snapshot")
	_check(_annotation_text_count(FIRST_ANNOTATION_TEXT) == 1, "late Astronaut snapshot should contain the annotation once")
	_check(
		int(_annotation_manager.call("create_annotation", _make_draft("Astronaut local annotation", Vector3.ZERO))) == -1,
		"Astronaut client should be denied before sending a local annotation request"
	)
	_annotation_manager.rpc_id(
		1,
		"_server_create_annotation",
		1,
		_make_draft(FORGED_ASTRONAUT_ANNOTATION_TEXT, Vector3.ZERO)
	)
	await _wait_frames(20)
	_check(int(_annotation_manager.call("get_annotation_count")) == 1, "Server should reject a forged Astronaut annotation request")
	_check(_annotation_text_count(FORGED_ASTRONAUT_ANNOTATION_TEXT) == 0, "forged Astronaut annotation must not be synchronized")
	_check(await _wait_for_player_roles(), "Astronaut client should identify both Ground replicas")
	_check(await _wait_for_remote_avatars(2), "Astronaut client should receive both Ground poses")
	_check(_write_control_marker("astronaut_client.initial_done"), "Astronaut should publish its authorization checkpoint")

	_check(await _wait_for_player_count(2), "Astronaut client should observe Ground VR cleanup")
	_check(await _wait_for_ground_vr_release(), "Astronaut client should observe the released Ground VR slot")
	_check(int(_annotation_manager.call("get_annotation_count")) == 1, "Astronaut should retain annotations while Ground VR reconnects")

	_check(await _wait_for_player_count(3), "Astronaut client should observe Ground VR reconnection")
	var replacement_ground_peer_id := await _wait_for_ground_vr_peer()
	_check(replacement_ground_peer_id > 1, "Astronaut client should observe the replacement Ground VR role")
	_check(await _wait_for_annotation_count(2), "Astronaut client should receive the post-reconnect annotation")
	_check(_has_unique_annotations(), "Astronaut client should end with two unique synchronized annotations")
	_check(await _wait_for_player_roles(), "Astronaut reconnect replicas should match the role registry")
	_check(await _wait_for_remote_avatars(2), "Astronaut client should receive reconnected Ground VR poses")
	_check(_has_unique_player_names(), "Astronaut client should end with unique player instances")
	_check(_write_control_marker("astronaut_client.done"), "Astronaut should publish its reconnect completion marker")
	_check(await _wait_for_server_shutdown(), "Astronaut should observe Server transport shutdown")


func _connect_client(world_name: String) -> bool:
	_peer = ENetMultiplayerPeer.new()
	if _peer.create_client("127.0.0.1", _port, 3) != OK:
		return false
	multiplayer.multiplayer_peer = _peer
	_world = _create_world(world_name)
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var status := _peer.get_connection_status()
		if status == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if status == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await get_tree().process_frame
	return false


func _create_world(_world_name: String) -> Node3D:
	var world := Node3D.new()
	# MultiplayerSpawner and annotation RPC paths must match exactly across OS
	# processes, regardless of the descriptive local world name.
	world.name = "CollaborationWorld"
	get_tree().root.add_child(world)

	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	shared_origin.add_to_group("shared_space_origin")
	world.add_child(shared_origin)
	var annotation_system := Node3D.new()
	annotation_system.name = "VirtualAnnotations"
	shared_origin.add_child(annotation_system)
	_annotation_manager = ANNOTATION_MANAGER_SCRIPT.new()
	_annotation_manager.name = "Manager"
	_annotation_manager.set("shared_space_origin_path", NodePath("../.."))
	_annotation_manager.set("target_root_path", NodePath("../../.."))
	_annotation_manager.set("peer_authority_path", NodePath("/root/NetworkHandler"))
	_annotation_manager.set("marker_scene", null)
	_annotation_manager.set("warn_on_rejection", false)
	annotation_system.add_child(_annotation_manager)

	var spawner := SPAWNER_SCRIPT.new() as MultiplayerSpawner
	spawner.name = "MultiplayerSpawner"
	spawner.spawn_path = NodePath("..")
	spawner.network_player = PLAYER_SCENE
	world.add_child(spawner)
	return world


func _disconnect_and_free_world() -> void:
	if _world != null and is_instance_valid(_world):
		var parent := _world.get_parent()
		if parent != null:
			parent.remove_child(_world)
		_world.queue_free()
	_world = null
	_annotation_manager = null
	var old_peer := _peer
	_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if old_peer != null:
		old_peer.close()


func _close_server_and_publish_marker() -> void:
	_disconnect_and_free_world()
	_check(_write_control_marker("server.closed"), "Server should publish its shutdown marker")


func _wait_for_player_count(expected_count: int) -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _count_player_nodes() == expected_count:
			return true
		await get_tree().process_frame
	return false


func _count_player_nodes() -> int:
	if _world == null or not is_instance_valid(_world):
		return 0
	var count := 0
	for child in _world.get_children():
		if str(child.name).is_valid_int():
			count += 1
	return count


func _has_unique_player_names() -> bool:
	if _world == null or not is_instance_valid(_world):
		return false
	var names: Dictionary = {}
	for child in _world.get_children():
		var child_name := str(child.name)
		if not child_name.is_valid_int():
			continue
		if names.has(child_name):
			return false
		names[child_name] = true
	return names.size() == 3


func _wait_for_local_role(expected_role: String) -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var network_handler := _get_network_handler()
		if network_handler != null \
				and str(network_handler.call("get_local_assigned_role")) == expected_role:
			return true
		await get_tree().process_frame
	return false


func _wait_for_role_count(expected_count: int) -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var network_handler := _get_network_handler()
		if network_handler != null \
				and (network_handler.call("get_peer_roles") as Dictionary).size() == expected_count:
			return true
		await get_tree().process_frame
	return false


func _wait_for_role_distribution(pc_ground_count: int, ground_vr_count: int, astronaut_count: int) -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _count_role(ROLE_PC_GROUND) == pc_ground_count \
				and _count_role(ROLE_GROUND_VR) == ground_vr_count \
				and _count_role(ROLE_ASTRONAUT) == astronaut_count:
			return true
		await get_tree().process_frame
	return false


func _wait_for_ground_vr_peer(excluded_peer_id: int = 0) -> int:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var network_handler := _get_network_handler()
		if network_handler != null:
			var peer_id := int(network_handler.call("get_ground_vr_peer_id"))
			if peer_id > 1 and peer_id != excluded_peer_id:
				return peer_id
		await get_tree().process_frame
	return 0


func _wait_for_ground_vr_release() -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var network_handler := _get_network_handler()
		if network_handler != null and int(network_handler.call("get_ground_vr_peer_id")) == 0:
			return true
		await get_tree().process_frame
	return false


func _wait_for_player_roles() -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _player_roles_match_registry():
			return true
		await get_tree().process_frame
	return false


func _player_roles_match_registry() -> bool:
	if _world == null or not is_instance_valid(_world):
		return false
	var network_handler := _get_network_handler()
	if network_handler == null:
		return false
	var player_count := 0
	for child in _world.get_children():
		var peer_id_text := str(child.name)
		if not peer_id_text.is_valid_int():
			continue
		player_count += 1
		if not child.has_method("get_session_role"):
			return false
		var expected_role := str(network_handler.call("get_peer_role", int(peer_id_text)))
		if expected_role == "unknown" or str(child.call("get_session_role")) != expected_role:
			return false
	return player_count == _count_player_nodes()


func _wait_for_remote_avatars(expected_count: int) -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _count_visible_remote_avatars() == expected_count:
			return true
		await get_tree().process_frame
	return false


func _count_visible_remote_avatars() -> int:
	if _world == null or not is_instance_valid(_world):
		return 0
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return 0
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return 0
	var local_peer_id := multiplayer.get_unique_id()
	var count := 0
	for child in _world.get_children():
		var peer_id_text := str(child.name)
		if not peer_id_text.is_valid_int() or int(peer_id_text) == local_peer_id:
			continue
		var network_head := child.get_node_or_null("NetworkHead") as Node3D
		if network_head != null and network_head.visible:
			count += 1
	return count


func _wait_for_annotation_count(expected_count: int) -> bool:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _annotation_manager != null \
				and int(_annotation_manager.call("get_annotation_count")) == expected_count:
			return true
		await get_tree().process_frame
	return false


func _make_draft(text: String, position: Vector3) -> Dictionary:
	return {
		"shared_position": position,
		"shared_normal": Vector3.UP,
		"target_path": "",
		"target_local_position": Vector3.ZERO,
		"target_local_normal": Vector3.UP,
		"text": text,
	}


func _annotation_creator(text: String) -> int:
	if _annotation_manager == null:
		return -1
	for value in _annotation_manager.call("get_annotations"):
		var annotation := value as Dictionary
		if str(annotation.get("text", "")) == text:
			return int(annotation.get("creator_peer_id", -1))
	return -1


func _annotation_text_count(text: String) -> int:
	if _annotation_manager == null:
		return 0
	var count := 0
	for value in _annotation_manager.call("get_annotations"):
		var annotation := value as Dictionary
		if str(annotation.get("text", "")) == text:
			count += 1
	return count


func _has_unique_annotations() -> bool:
	if _annotation_manager == null or int(_annotation_manager.call("get_annotation_count")) != 2:
		return false
	var ids: Dictionary = {}
	for value in _annotation_manager.call("get_annotations"):
		var annotation := value as Dictionary
		var annotation_id := int(annotation.get("id", -1))
		if annotation_id <= 0 or ids.has(annotation_id):
			return false
		ids[annotation_id] = true
	return ids.size() == 2 \
		and _annotation_text_count(FIRST_ANNOTATION_TEXT) == 1 \
		and _annotation_text_count(SECOND_ANNOTATION_TEXT) == 1


func _count_role(expected_role: String) -> int:
	var network_handler := _get_network_handler()
	if network_handler == null:
		return 0
	var count := 0
	var roles := network_handler.call("get_peer_roles") as Dictionary
	for assigned_role in roles.values():
		if str(assigned_role) == expected_role:
			count += 1
	return count


func _get_network_handler() -> Node:
	return get_node_or_null("/root/NetworkHandler")


func _wait_frames(frame_count: int) -> void:
	for _frame in range(frame_count):
		await get_tree().process_frame


func _write_control_marker(marker_name: String) -> bool:
	if _control_dir.is_empty():
		return false
	var marker_file := FileAccess.open(_control_dir.path_join(marker_name), FileAccess.WRITE)
	if marker_file == null:
		return false
	marker_file.store_string("ready\n")
	marker_file.close()
	return true


func _wait_for_control_marker(marker_name: String) -> bool:
	if _control_dir.is_empty():
		return false
	var marker_path := _control_dir.path_join(marker_name)
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(marker_path):
			return true
		await get_tree().process_frame
	return false


func _wait_for_server_shutdown() -> bool:
	if not await _wait_for_control_marker("server.closed"):
		return false
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _peer == null or _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return true
		await get_tree().process_frame
	return false


func _get_user_arg(prefix: String) -> String:
	for value in OS.get_cmdline_user_args():
		var arg := str(value)
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	_disconnect_and_free_world()
	await get_tree().process_frame
	if _failures.is_empty():
		print("COLLABORATION_MULTIPROCESS_%s PASS" % _role.to_upper())
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("COLLABORATION_MULTIPROCESS_%s: %s" % [_role.to_upper(), failure])
	get_tree().quit(1)
