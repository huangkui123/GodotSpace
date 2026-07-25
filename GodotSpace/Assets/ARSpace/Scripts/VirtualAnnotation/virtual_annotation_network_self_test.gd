extends SceneTree

const ManagerScript := preload("res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_manager.gd")
const CONNECT_TIMEOUT_FRAMES: int = 300
const SYNC_TIMEOUT_FRAMES: int = 180
const SERVER_PEER_ID: int = 1

var _failures: Array[String] = []
var _peers: Array[ENetMultiplayerPeer] = []


class MockPeerAuthority extends Node:
	var local_role: String = "sky"
	var annotating_peers: Dictionary = {}

	func get_local_assigned_role() -> String:
		return local_role

	func can_peer_annotate(peer_id: int) -> bool:
		return bool(annotating_peers.get(peer_id, false))


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var server_peer := ENetMultiplayerPeer.new()
	var port := _start_loopback_server(server_peer)
	if port <= 0:
		await _finish()
		return
	var server_api := SceneMultiplayer.new()
	server_api.multiplayer_peer = server_peer
	var server_branch := _create_branch("ServerBranch", server_api)
	var server_authority := _add_peer_authority(server_branch, "pc_ground")
	var server_manager = _add_annotation_manager(server_branch)

	var first_client_peer := ENetMultiplayerPeer.new()
	_check(first_client_peer.create_client("127.0.0.1", port) == OK, "first client should begin connecting")
	var first_client_api := SceneMultiplayer.new()
	first_client_api.multiplayer_peer = first_client_peer
	var first_client_branch := _create_branch("FirstClientBranch", first_client_api)
	_add_peer_authority(first_client_branch, "ground_vr")
	# Production enters ARSpace while ENet is still connecting, so the manager
	# must retain a pending snapshot request until connected_to_server.
	var first_client_manager = _add_annotation_manager(first_client_branch)
	_check(await _wait_for_connection(first_client_peer), "first client should connect")
	await process_frame
	var first_client_id := first_client_api.get_unique_id()
	server_authority.annotating_peers[first_client_id] = true

	var first_id: int = int(server_manager.create_annotation(_make_draft("首个标注", Vector3(1.0, 2.0, 3.0))))
	_check(first_id == 1, "server should allocate the first annotation id")
	_check(await _wait_for_count(first_client_manager, 1), "client should receive a reliable annotation upsert")
	_check(str(first_client_manager.get_annotation(first_id).get("text", "")) == "首个标注", "client should preserve annotation text")

	_check(server_manager.update_annotation_text(first_id, "更新说明"), "server should update annotation text")
	_check(await _wait_for_text(first_client_manager, first_id, "更新说明"), "client should receive the updated text")
	_check(server_manager.delete_annotation(first_id), "server should delete an annotation")
	_check(await _wait_for_count(first_client_manager, 0), "client should receive annotation deletion")

	var ground_request_result: int = int(first_client_manager.create_annotation(_make_draft("Ground VR 标注", Vector3(1.5, 0.5, -2.0))))
	_check(ground_request_result == 0, "Ground VR create should be queued for Server authority")
	_check(await _wait_for_count(server_manager, 1), "Server should accept a registered Ground VR create")
	var ground_annotation_id := _find_annotation_by_text(server_manager, "Ground VR 标注")
	_check(ground_annotation_id > 0, "Server should allocate the Ground VR annotation id")
	_check(
		int(server_manager.get_annotation(ground_annotation_id).get("creator_peer_id", -1)) == first_client_id,
		"Server should record the authenticated Ground VR creator"
	)
	_check(first_client_manager.update_annotation_text(ground_annotation_id, "Ground VR 更新"), "Ground VR should submit a text update")
	_check(await _wait_for_text(server_manager, ground_annotation_id, "Ground VR 更新"), "Server should apply the Ground VR update")
	_check(first_client_manager.delete_annotation(ground_annotation_id), "Ground VR should submit a delete")
	_check(await _wait_for_count(server_manager, 0), "Server should apply the Ground VR delete")

	var keep_a: int = int(server_manager.create_annotation(_make_draft("保留 A", Vector3(2.0, 0.0, 0.0))))
	var remove_id: int = int(server_manager.create_annotation(_make_draft("待删除", Vector3(3.0, 0.0, 0.0))))
	var keep_b: int = int(server_manager.create_annotation(_make_draft("保留 B", Vector3(4.0, 0.0, 0.0))))
	server_manager.delete_annotation(remove_id)
	_check(await _wait_for_count(first_client_manager, 2), "first client should retain exactly two annotations")

	var late_client_peer := ENetMultiplayerPeer.new()
	_check(late_client_peer.create_client("127.0.0.1", port) == OK, "late client should begin connecting")
	var late_client_api := SceneMultiplayer.new()
	late_client_api.multiplayer_peer = late_client_peer
	var late_client_branch := _create_branch("LateClientBranch", late_client_api)
	_add_peer_authority(late_client_branch, "sky")
	var late_client_manager = _add_annotation_manager(late_client_branch)
	_check(await _wait_for_connection(late_client_peer), "late client should connect")
	_check(await _wait_for_count(late_client_manager, 2), "late client should receive the authoritative snapshot")
	_check(not late_client_manager.get_annotation(keep_a).is_empty(), "late snapshot should contain keep A")
	_check(not late_client_manager.get_annotation(keep_b).is_empty(), "late snapshot should contain keep B")
	_check(late_client_manager.get_annotation(remove_id).is_empty(), "late snapshot should omit the deleted annotation")
	_check(late_client_manager.create_annotation(_make_draft("Sky local bypass", Vector3.ZERO)) == -1, "Sky should be denied before sending an annotation request")
	late_client_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_create_annotation",
		1,
		_make_draft("Sky forged request", Vector3.ZERO)
	)
	await _wait_frames(10)
	_check(_find_annotation_by_text(server_manager, "Sky forged request") == -1, "Server should reject a forged Sky create request")

	var invalid_ground_draft := _make_draft("Invalid Ground request", Vector3.ZERO)
	invalid_ground_draft["shared_position"] = Vector3(NAN, 0.0, 0.0)
	first_client_manager.rpc_id(SERVER_PEER_ID, "_server_create_annotation", 50, invalid_ground_draft)
	await _wait_frames(10)
	_check(_find_annotation_by_text(server_manager, "Invalid Ground request") == -1, "Server should reject non-finite Ground VR data")
	first_client_manager.rpc_id(SERVER_PEER_ID, "_server_create_annotation", 50, _make_draft("Replayed Ground request", Vector3.ZERO))
	await _wait_frames(10)
	_check(_find_annotation_by_text(server_manager, "Replayed Ground request") == -1, "Server should reject a replayed Ground VR sequence")
	var unsafe_ground_draft := _make_draft("Unsafe Ground request", Vector3.ZERO)
	unsafe_ground_draft["target_path"] = "../Outside"
	first_client_manager.rpc_id(SERVER_PEER_ID, "_server_create_annotation", 51, unsafe_ground_draft)
	await _wait_frames(10)
	_check(_find_annotation_by_text(server_manager, "Unsafe Ground request") == -1, "Server should reject an unsafe Ground VR target path")
	var previous_keep_b_text := str(server_manager.get_annotation(keep_b).get("text", ""))
	first_client_manager.rpc_id(SERVER_PEER_ID, "_server_update_annotation_text", 52, keep_b, "x".repeat(81))
	await _wait_frames(10)
	_check(str(server_manager.get_annotation(keep_b).get("text", "")) == previous_keep_b_text, "Server should reject overlong Ground VR text")

	# Disconnect the first client, mutate the authoritative state, then reconnect
	# the existing scene branch. The new snapshot must replace its stale state.
	first_client_peer.close()
	await _wait_frames(10)
	_check(server_manager.delete_annotation(keep_a), "server should mutate state while a client is offline")
	var keep_c: int = int(server_manager.create_annotation(_make_draft("保留 C", Vector3(5.0, 0.0, 0.0))))
	_check(await _wait_for_members(late_client_manager, [keep_b, keep_c], [keep_a, remove_id]), "connected client should receive offline-period CRUD")

	var reconnect_peer := ENetMultiplayerPeer.new()
	_check(reconnect_peer.create_client("127.0.0.1", port) == OK, "disconnected client should begin reconnecting")
	_peers.append(reconnect_peer)
	first_client_api.multiplayer_peer = reconnect_peer
	_check(await _wait_for_connection(reconnect_peer), "disconnected client should reconnect")
	server_authority.annotating_peers[first_client_api.get_unique_id()] = true
	_check(
		await _wait_for_members(first_client_manager, [keep_b, keep_c], [keep_a, remove_id]),
		"reconnected client should replace stale annotations from a full snapshot"
	)

	var repeated_snapshot_events: Array[int] = []
	late_client_manager.snapshot_applied.connect(func(revision: int, _count: int) -> void:
		repeated_snapshot_events.append(revision)
	)
	late_client_manager.request_annotation_snapshot()
	await _wait_frames(10)
	_check(late_client_manager.get_annotation_count() == 2, "repeated snapshots should be idempotent")
	_check(repeated_snapshot_events.is_empty(), "an identical snapshot must not emit duplicate UI side effects")
	_check(first_client_manager.clear_annotations(), "Ground VR should submit clear-all to the Server")
	_check(await _wait_for_count(server_manager, 0), "Server should apply Ground VR clear-all")
	_check(await _wait_for_count(first_client_manager, 0), "first client should receive clear-all")
	_check(await _wait_for_count(late_client_manager, 0), "late client should receive clear-all")

	await _finish()


func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43240, 43260):
		if peer.create_server(port, 2, 3) == OK:
			_peers.append(peer)
			return port
	_check(false, "loopback ENet server should bind an available test port")
	return 0


func _create_branch(branch_name: String, api: SceneMultiplayer) -> Node3D:
	var branch := Node3D.new()
	branch.name = branch_name
	root.add_child(branch)
	set_multiplayer(api, branch.get_path())
	var peer := api.multiplayer_peer as ENetMultiplayerPeer
	if peer != null and not _peers.has(peer):
		_peers.append(peer)
	return branch


func _add_peer_authority(branch: Node3D, local_role: String) -> MockPeerAuthority:
	var authority := MockPeerAuthority.new()
	authority.name = "PeerAuthority"
	authority.local_role = local_role
	branch.add_child(authority)
	return authority


func _add_annotation_manager(branch: Node3D) -> Node:
	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	branch.add_child(shared_origin)
	var system := Node3D.new()
	system.name = "VirtualAnnotations"
	shared_origin.add_child(system)
	var manager = ManagerScript.new()
	manager.name = "Manager"
	manager.shared_space_origin_path = NodePath("../..")
	manager.target_root_path = NodePath("../../..")
	manager.peer_authority_path = NodePath("../../../PeerAuthority")
	manager.marker_scene = null
	manager.warn_on_rejection = false
	system.add_child(manager)
	return manager


func _find_annotation_by_text(manager: Node, text: String) -> int:
	for value in manager.call("get_annotations"):
		var annotation := value as Dictionary
		if str(annotation.get("text", "")) == text:
			return int(annotation.get("id", -1))
	return -1


func _make_draft(text: String, position: Vector3) -> Dictionary:
	return {
		"shared_position": position,
		"shared_normal": Vector3.UP,
		"target_path": "",
		"target_local_position": Vector3.ZERO,
		"target_local_normal": Vector3.UP,
		"text": text,
	}


func _wait_for_connection(peer: ENetMultiplayerPeer) -> bool:
	for _frame in range(CONNECT_TIMEOUT_FRAMES):
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await process_frame
	return false


func _wait_for_count(manager: Node, expected: int) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		if int(manager.call("get_annotation_count")) == expected:
			return true
		await process_frame
	return false


func _wait_for_text(manager: Node, annotation_id: int, expected: String) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		var annotation: Dictionary = manager.call("get_annotation", annotation_id)
		if str(annotation.get("text", "")) == expected:
			return true
		await process_frame
	return false


func _wait_for_members(manager: Node, included_ids: Array, excluded_ids: Array) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		var matches := true
		for annotation_id in included_ids:
			if manager.call("get_annotation", int(annotation_id)).is_empty():
				matches = false
				break
		if matches:
			for annotation_id in excluded_ids:
				if not manager.call("get_annotation", int(annotation_id)).is_empty():
					matches = false
					break
		if matches:
			return true
		await process_frame
	return false


func _wait_frames(frame_count: int) -> void:
	for _frame in range(frame_count):
		await process_frame


func _finish() -> void:
	for peer in _peers:
		peer.close()
	await process_frame
	if _failures.is_empty():
		print("VIRTUAL_ANNOTATION_NETWORK_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("VIRTUAL_ANNOTATION_NETWORK_SELF_TEST: %s" % failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
