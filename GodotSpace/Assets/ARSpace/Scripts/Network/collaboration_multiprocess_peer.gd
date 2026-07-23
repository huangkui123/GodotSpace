extends Node

const PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const SPAWNER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/Network/multiplayer_spawner.gd")
const ANNOTATION_MANAGER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_manager.gd")
const ROLE_ARG: String = "--collab-process-role="
const PORT_ARG: String = "--collab-process-port="
const DEFAULT_PORT: int = 43280
const STAGE_TIMEOUT_MSEC: int = 12000
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"
const FIRST_ANNOTATION_TEXT: String = "Ground VR initial annotation"
const SECOND_ANNOTATION_TEXT: String = "Ground VR reconnected annotation"
const FORGED_SKY_ANNOTATION_TEXT: String = "Sky forged annotation"

var _role: String = ""
var _port: int = DEFAULT_PORT
var _world: Node3D
var _peer: ENetMultiplayerPeer
var _annotation_manager: Node
var _failures: Array[String] = []
var _last_rejected_peer_id: int = 0
var _last_rejection_reason: String = ""
var _candidate_own_player_seen: bool = false


func _ready() -> void:
	_disable_unrelated_services()
	_role = _get_user_arg(ROLE_ARG).to_lower()
	var port_text := _get_user_arg(PORT_ARG)
	if port_text.is_valid_int():
		_port = int(port_text)
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
	match _role:
		"server":
			await _run_server()
		"ground_client", "first_client":
			await _run_ground_client()
		"sky_client", "late_client":
			await _run_sky_client()
		"sky_candidate":
			await _run_sky_candidate()
		_:
			_failures.append("Unknown collaboration process role: %s" % _role)
	await _finish()


func _run_server() -> void:
	_peer = ENetMultiplayerPeer.new()
	_check(_peer.create_server(_port, 3, 3) == OK, "server should bind port %d" % _port)
	if not _failures.is_empty():
		return
	multiplayer.multiplayer_peer = _peer
	var network_handler := _get_network_handler()
	if network_handler != null \
			and not network_handler.peer_role_request_rejected.is_connected(_on_role_request_rejected):
		network_handler.peer_role_request_rejected.connect(_on_role_request_rejected)
	_world = _create_world("ServerWorld")
	_check(await _wait_for_player_count(2), "server should observe the Ground VR client")
	var first_ground_peer_id := await _wait_for_ground_vr_peer()
	_check(first_ground_peer_id > 1, "server should authoritatively assign the Ground VR role")
	_check(await _wait_for_annotation_count(1), "server should accept the Ground VR annotation")
	_check(
		_annotation_creator(FIRST_ANNOTATION_TEXT) == first_ground_peer_id,
		"server should record the authenticated Ground VR creator"
	)

	_check(await _wait_for_player_count(3), "server should observe the Sky client")
	_check(await _wait_for_role_count(3), "server should register all three session roles")
	_check(_count_role(ROLE_PC_GROUND) == 1, "server should keep exactly one PC Ground role")
	_check(_count_role(ROLE_GROUND_VR) == 1, "server should keep exactly one Ground VR role")
	_check(_count_role(ROLE_SKY) == 1, "server should keep exactly one Sky role")
	_check(await _wait_for_player_roles(), "server player replicas should match the role registry")
	_check(await _wait_for_remote_avatars(2), "server should receive both remote player poses")
	var rejected_candidate_id := await _wait_for_sky_candidate_rejection()
	_check(rejected_candidate_id > 1, "server should explicitly reject the second Sky candidate")
	_check(
		rejected_candidate_id <= 1 or _world.get_node_or_null(str(rejected_candidate_id)) == null,
		"rejected Sky candidate must never receive a production Player node"
	)
	_check(_count_player_nodes() == 3, "Sky candidate rejection must keep exactly three admitted players")
	_check(_count_role(ROLE_SKY) == 1, "Sky candidate rejection must keep exactly one Sky role")

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
	await get_tree().create_timer(0.75).timeout


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

	_check(await _wait_for_player_count(3), "Ground VR client should observe the Sky client")
	_check(await _wait_for_role_count(3), "Ground VR should receive the three-role snapshot")
	_check(await _wait_for_player_roles(), "Ground VR should identify PC Ground and Sky replicas")
	_check(await _wait_for_remote_avatars(2), "Ground VR should receive PC Ground and Sky poses")
	# Give the Sky process time to exercise its rejected create before this peer
	# disconnects and releases the single Ground VR slot.
	await get_tree().create_timer(2.0).timeout
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
	await get_tree().create_timer(1.0).timeout


func _run_sky_client() -> void:
	_check(await _connect_client("SkyClientWorld"), "Sky client should connect")
	if not _failures.is_empty():
		return
	_check(await _wait_for_local_role(ROLE_SKY), "Sky client should receive its Server-assigned role")
	_check(await _wait_for_player_count(3), "Sky client should receive all existing players")
	_check(await _wait_for_role_count(3), "Sky client should receive all session roles")
	_check(await _wait_for_annotation_count(1), "late Sky client should receive the annotation snapshot")
	_check(_annotation_text_count(FIRST_ANNOTATION_TEXT) == 1, "late Sky snapshot should contain the annotation once")
	_check(
		int(_annotation_manager.call("create_annotation", _make_draft("Sky local annotation", Vector3.ZERO))) == -1,
		"Sky client should be denied before sending a local annotation request"
	)
	_annotation_manager.rpc_id(
		1,
		"_server_create_annotation",
		1,
		_make_draft(FORGED_SKY_ANNOTATION_TEXT, Vector3.ZERO)
	)
	await _wait_frames(20)
	_check(int(_annotation_manager.call("get_annotation_count")) == 1, "Server should reject a forged Sky annotation request")
	_check(_annotation_text_count(FORGED_SKY_ANNOTATION_TEXT) == 0, "forged Sky annotation must not be synchronized")
	_check(await _wait_for_player_roles(), "Sky client should identify both Ground replicas")
	_check(await _wait_for_remote_avatars(2), "Sky client should receive both Ground poses")

	_check(await _wait_for_player_count(2), "Sky client should observe Ground VR cleanup")
	_check(await _wait_for_ground_vr_release(), "Sky client should observe the released Ground VR slot")
	_check(int(_annotation_manager.call("get_annotation_count")) == 1, "Sky should retain annotations while Ground VR reconnects")

	_check(await _wait_for_player_count(3), "Sky client should observe Ground VR reconnection")
	var replacement_ground_peer_id := await _wait_for_ground_vr_peer()
	_check(replacement_ground_peer_id > 1, "Sky client should observe the replacement Ground VR role")
	_check(await _wait_for_annotation_count(2), "Sky client should receive the post-reconnect annotation")
	_check(_has_unique_annotations(), "Sky client should end with two unique synchronized annotations")
	_check(await _wait_for_player_roles(), "Sky reconnect replicas should match the role registry")
	_check(await _wait_for_remote_avatars(2), "Sky client should receive reconnected Ground VR poses")
	_check(_has_unique_player_names(), "Sky client should end with unique player instances")
	await get_tree().create_timer(0.75).timeout


func _run_sky_candidate() -> void:
	var network_handler := _get_network_handler()
	if network_handler != null \
			and not network_handler.peer_role_request_rejected.is_connected(_on_role_request_rejected):
		network_handler.peer_role_request_rejected.connect(_on_role_request_rejected)
	_check(await _connect_client("SkyCandidateWorld"), "second Sky candidate should connect for admission")
	if not _failures.is_empty():
		return
	var candidate_peer_id := _peer.get_unique_id()
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _world != null and _world.get_node_or_null(str(candidate_peer_id)) != null:
			_candidate_own_player_seen = true
		if _last_rejected_peer_id == candidate_peer_id \
				and _last_rejection_reason == "sky_slot_occupied" \
				and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			break
		await get_tree().process_frame
	_check(
		_last_rejected_peer_id == candidate_peer_id and _last_rejection_reason == "sky_slot_occupied",
		"second Sky candidate should receive sky_slot_occupied"
	)
	_check(
		_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED,
		"second Sky candidate should be disconnected after rejection"
	)
	_check(not _candidate_own_player_seen, "second Sky candidate must never see its own Player node")


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


func _wait_for_sky_candidate_rejection() -> int:
	var deadline := Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _last_rejected_peer_id > 1 and _last_rejection_reason == "sky_slot_occupied":
			return _last_rejected_peer_id
		await get_tree().process_frame
	return 0


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


func _on_role_request_rejected(peer_id: int, _requested_role: String, reason: String) -> void:
	_last_rejected_peer_id = peer_id
	_last_rejection_reason = reason


func _wait_frames(frame_count: int) -> void:
	for _frame in range(frame_count):
		await get_tree().process_frame


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
