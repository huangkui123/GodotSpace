extends SceneTree

const StateManagerScript := preload(
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_state_manager.gd"
)
const DockManagerScript := preload(
	"res://Assets/ARSpace/Scripts/SpatialWindows/window_dock_manager.gd"
)
const SlotScene := preload(
	"res://Assets/ARSpace/Scenes/SpatialWindows/WindowDockSlot3D.tscn"
)
const CONNECT_TIMEOUT_FRAMES: int = 300
const SYNC_TIMEOUT_FRAMES: int = 240
const SERVER_PEER_ID: int = 1
const STATE_FLOATING: int = 1
const STATE_DRAGGING: int = 2
const STATE_SNAPPED: int = 4

var _failures: Array[String] = []
var _peers: Array[ENetMultiplayerPeer] = []


class MockPeerAuthority extends Node:
	var local_role: String = "pc_ground"
	var allowed_remote_peers: Dictionary = {}

	func can_peer_control_shared_windows(peer_id: int) -> bool:
		if multiplayer.is_server():
			return peer_id == SERVER_PEER_ID \
				or bool(allowed_remote_peers.get(peer_id, false))
		return peer_id == multiplayer.get_unique_id() \
			and local_role in ["pc_ground", "ground_vr", "sky"]

	func get_local_assigned_role() -> String:
		return local_role


class MockWindowController extends Node:
	var window_id: StringName
	var category: StringName = &"panel"
	var size_m: Vector2 = Vector2(0.9, 0.6)
	var shared_transform: Transform3D = Transform3D.IDENTITY
	var visible: bool = true
	var state: int = STATE_FLOATING
	var slot_id: StringName = &""
	var last_operator_peer_id: int = 0
	var applied_record_count: int = 0
	var preview_count: int = 0

	func get_window_id() -> StringName:
		return window_id

	func get_window_config() -> Dictionary:
		return {
			"window_id": str(window_id),
			"scope": 1,
			"category": str(category),
			"size_m": size_m,
			"base_scale": Vector3.ONE,
		}

	func get_shared_transform() -> Transform3D:
		return shared_transform

	func get_current_slot_id() -> StringName:
		return slot_id

	func get_state() -> int:
		return state

	func is_window_open() -> bool:
		return visible

	func apply_authoritative_record(record: Dictionary) -> void:
		visible = bool(record.get("visible", false))
		state = int(record.get("state", 0))
		slot_id = StringName(str(record.get("slot_id", "")))
		shared_transform = record.get("transform", Transform3D.IDENTITY) as Transform3D
		last_operator_peer_id = int(record.get("operator_peer_id", 0))
		applied_record_count += 1

	func apply_authoritative_drag_preview(
		value: Transform3D,
		operator_peer_id: int
	) -> void:
		shared_transform = value
		last_operator_peer_id = operator_peer_id
		preview_count += 1


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
	var server_nodes := _build_branch(server_branch, "pc_ground")
	var server_authority := server_nodes.authority as MockPeerAuthority
	var server_manager := server_nodes.manager as Node
	var server_a := server_nodes.window_a as MockWindowController

	var ground_peer := ENetMultiplayerPeer.new()
	_check(
		ground_peer.create_client("127.0.0.1", port) == OK,
		"Ground VR client should begin connecting"
	)
	var ground_api := SceneMultiplayer.new()
	ground_api.multiplayer_peer = ground_peer
	var ground_branch := _create_branch("GroundBranch", ground_api)
	var ground_nodes := _build_branch(ground_branch, "ground_vr")
	var ground_manager := ground_nodes.manager as Node
	_check(await _wait_for_connection(ground_peer), "Ground VR client should connect")
	var ground_id := ground_api.get_unique_id()
	server_authority.allowed_remote_peers[ground_id] = true
	_check(
		await _wait_for_window_count(ground_manager, 2),
		"Ground VR should receive the initial shared-window snapshot"
	)

	var first_transform := Transform3D(
		Basis.IDENTITY,
		Vector3(0.25, 1.2, -1.5)
	)
	_check(
		bool(ground_manager.request_settled_state(&"window_a", first_transform, &"")),
		"registered Ground VR should submit a shared transform"
	)
	_check(
		await _wait_for_transform(server_manager, &"window_a", first_transform),
		"Server should apply the authenticated Ground VR transform"
	)

	var token := int(ground_manager.request_begin_drag(&"window_a", first_transform))
	_check(token > 0, "Ground VR should allocate a client drag token")
	_check(
		await _wait_for_state(server_manager, &"window_a", STATE_DRAGGING),
		"Server should grant the Ground VR drag lock"
	)
	var preview_transform := Transform3D(
		Basis.IDENTITY,
		Vector3(0.45, 1.25, -1.6)
	)
	_check(
		bool(ground_manager.request_drag_preview(
			&"window_a",
			token,
			1,
			preview_transform
		)),
		"Ground VR should send an unreliable ordered preview"
	)
	_check(
		await _wait_for_controller_transform(server_a, preview_transform),
		"Server production manager should apply the drag preview to its controller"
	)
	_check(
		bool(ground_manager.request_finish_drag(
			&"window_a",
			token,
			2,
			preview_transform,
			&"slot_a"
		)),
		"Ground VR should reliably finish on slot_a"
	)
	_check(
		await _wait_for_slot(server_manager, &"window_a", &"slot_a"),
		"Server should authoritatively occupy slot_a"
	)
	_check(
		await _wait_for_slot(ground_manager, &"window_a", &"slot_a"),
		"Ground VR should converge on the authoritative slot"
	)

	var sky_peer := ENetMultiplayerPeer.new()
	_check(
		sky_peer.create_client("127.0.0.1", port) == OK,
		"late Sky client should begin connecting"
	)
	var sky_api := SceneMultiplayer.new()
	sky_api.multiplayer_peer = sky_peer
	var sky_branch := _create_branch("SkyBranch", sky_api)
	var sky_nodes := _build_branch(sky_branch, "sky")
	var sky_manager := sky_nodes.manager as Node
	_check(await _wait_for_connection(sky_peer), "late Sky client should connect")
	var sky_id := sky_api.get_unique_id()
	server_authority.allowed_remote_peers[sky_id] = true
	_check(
		await _wait_for_slot(sky_manager, &"window_a", &"slot_a"),
		"late Sky snapshot should restore slot_a occupancy"
	)

	var revision_before_race := int(server_manager.get_state_revision())
	var sky_b_transform := Transform3D(
		Basis.IDENTITY,
		Vector3(0.7, 1.2, -1.5)
	)
	_check(
		bool(sky_manager.request_settled_state(
			&"window_b",
			sky_b_transform,
			&"slot_a"
		)),
		"Sky slot-race request should reach Server validation"
	)
	await _wait_frames(20)
	_check(
		int(server_manager.get_state_revision()) == revision_before_race,
		"losing the occupied-slot race must not advance revision"
	)
	_check(
		(server_manager.get_window_state(&"window_b") as Dictionary).get(
			"slot_id",
			""
		) == "",
		"losing slot race must leave window_b floating"
	)
	_check(
		bool(sky_manager.request_settled_state(
			&"window_b",
			sky_b_transform,
			&"slot_b"
		)),
		"Sky should control a different empty slot"
	)
	_check(
		await _wait_for_slot(server_manager, &"window_b", &"slot_b"),
		"Server should accept registered Sky operations"
	)
	_check(
		await _wait_for_slot(ground_manager, &"window_b", &"slot_b"),
		"Ground VR should receive Sky's authoritative slot result"
	)

	var invalid_revision := int(server_manager.get_state_revision())
	var invalid_transform := Transform3D.IDENTITY
	invalid_transform.origin = Vector3(NAN, 1.0, 0.0)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_settled_window",
		100,
		&"window_a",
		invalid_transform,
		&""
	)
	await _wait_frames(12)
	_check(
		int(server_manager.get_state_revision()) == invalid_revision,
		"Server should reject a non-finite transform without changing revision"
	)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_settled_window",
		100,
		&"window_a",
		first_transform,
		&""
	)
	await _wait_frames(12)
	_check(
		int(server_manager.get_state_revision()) == invalid_revision,
		"Server should reject a replayed request sequence"
	)

	server_authority.allowed_remote_peers[ground_id] = false
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_settled_window",
		101,
		&"window_a",
		first_transform,
		&""
	)
	await _wait_frames(12)
	_check(
		int(server_manager.get_state_revision()) == invalid_revision,
		"Server should reject a sender whose registered role lost permission"
	)
	server_authority.allowed_remote_peers[ground_id] = true
	var recovery_transform := Transform3D(
		Basis.IDENTITY,
		Vector3(-0.25, 1.2, -1.4)
	)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_settled_window",
		102,
		&"window_a",
		recovery_transform,
		&""
	)
	_check(
		await _wait_for_transform(server_manager, &"window_a", recovery_transform),
		"valid traffic after malicious requests should still succeed"
	)

	var sky_token := int(sky_manager.request_begin_drag(
		&"window_b",
		sky_b_transform
	))
	_check(sky_token > 0, "Sky should begin an authoritative drag")
	_check(
		await _wait_for_state(server_manager, &"window_b", STATE_DRAGGING),
		"Server should record Sky's drag lock"
	)
	sky_peer.close()
	await _wait_frames(20)
	_check(
		await _wait_for_state(server_manager, &"window_b", STATE_FLOATING),
		"disconnect during drag should settle the window as FLOATING"
	)
	_check(
		str(server_manager.get_window_state(&"window_b").get("slot_id", "")).is_empty(),
		"disconnect settlement should release temporary slot ownership"
	)

	var server_mutation := Transform3D(
		Basis.IDENTITY,
		Vector3(-0.6, 1.0, -1.2)
	)
	_check(
		bool(server_manager.request_settled_state(
			&"window_a",
			server_mutation,
			&""
		)),
		"PC Ground Server should control shared windows locally"
	)
	_check(
		await _wait_for_transform(ground_manager, &"window_a", server_mutation),
		"connected Ground VR should receive PC Ground's update"
	)

	var old_ground_id := ground_id
	ground_peer.close()
	await _wait_frames(15)
	server_authority.allowed_remote_peers.erase(old_ground_id)
	_check(
		bool(server_manager.request_settled_state(
			&"window_a",
			Transform3D(Basis.IDENTITY, Vector3(-0.8, 1.1, -1.1)),
			&""
		)),
		"Server should mutate authoritative state while Ground VR is offline"
	)
	var reconnect_peer := ENetMultiplayerPeer.new()
	_check(
		reconnect_peer.create_client("127.0.0.1", port) == OK,
		"Ground VR branch should begin reconnecting"
	)
	_peers.append(reconnect_peer)
	ground_api.multiplayer_peer = reconnect_peer
	_check(await _wait_for_connection(reconnect_peer), "Ground VR branch should reconnect")
	var new_ground_id := ground_api.get_unique_id()
	server_authority.allowed_remote_peers[new_ground_id] = true
	_check(
		await _wait_for_transform(
			ground_manager,
			&"window_a",
			Transform3D(Basis.IDENTITY, Vector3(-0.8, 1.1, -1.1))
		),
		"reconnected Ground VR should replace stale state from a full snapshot"
	)
	_check(
		old_ground_id == new_ground_id or not server_authority.allowed_remote_peers.has(old_ground_id),
		"reconnect may allocate a new peer ID without affecting snapshot recovery"
	)

	await _finish()


func _build_branch(branch: Node3D, local_role: String) -> Dictionary:
	var authority := MockPeerAuthority.new()
	authority.name = "PeerAuthority"
	authority.local_role = local_role
	branch.add_child(authority)

	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	branch.add_child(shared_origin)

	var dock_manager: Node3D = DockManagerScript.new()
	dock_manager.name = "WindowDockSlots"
	shared_origin.add_child(dock_manager)
	_add_branch_slot(dock_manager, &"slot_a", Vector3(-0.7, 1.2, -1.8))
	_add_branch_slot(dock_manager, &"slot_b", Vector3(0.7, 1.2, -1.8))
	dock_manager.call("refresh_slots")

	var spatial_windows := Node3D.new()
	spatial_windows.name = "SpatialWindows"
	shared_origin.add_child(spatial_windows)
	var manager: Node = StateManagerScript.new()
	manager.name = "Manager"
	manager.shared_space_origin_path = NodePath("../..")
	manager.dock_manager_path = NodePath("../../WindowDockSlots")
	manager.peer_authority_path = NodePath("../../../PeerAuthority")
	manager.require_remote_interaction_pose = false
	manager.warn_on_rejection = false
	spatial_windows.add_child(manager)

	var window_a := _add_mock_window(manager, &"window_a")
	var window_b := _add_mock_window(manager, &"window_b")
	return {
		"authority": authority,
		"manager": manager,
		"window_a": window_a,
		"window_b": window_b,
	}


func _add_branch_slot(
	dock_manager: Node3D,
	slot_id: StringName,
	position: Vector3
) -> void:
	var slot := SlotScene.instantiate() as Node3D
	slot.name = str(slot_id)
	slot.set("slot_id", slot_id)
	slot.set("accepted_categories", PackedStringArray(["panel"]))
	slot.position = position
	dock_manager.add_child(slot)


func _add_mock_window(
	manager: Node,
	window_id: StringName
) -> MockWindowController:
	var controller := MockWindowController.new()
	controller.name = str(window_id)
	controller.window_id = window_id
	manager.get_parent().add_child(controller)
	_check(bool(manager.register_window(controller)), "manager should register %s" % window_id)
	return controller


func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43320, 43340):
		if peer.create_server(port, 3, 3) == OK:
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


func _wait_for_connection(peer: ENetMultiplayerPeer) -> bool:
	for _frame in range(CONNECT_TIMEOUT_FRAMES):
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await process_frame
	return false


func _wait_for_window_count(manager: Node, expected: int) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		if (manager.get_window_states() as Array).size() == expected:
			return true
		await process_frame
	return false


func _wait_for_state(
	manager: Node,
	window_id: StringName,
	expected: int
) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		var record := manager.get_window_state(window_id) as Dictionary
		if int(record.get("state", -1)) == expected:
			return true
		await process_frame
	return false


func _wait_for_slot(
	manager: Node,
	window_id: StringName,
	expected: StringName
) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		var record := manager.get_window_state(window_id) as Dictionary
		if StringName(str(record.get("slot_id", ""))) == expected \
			and int(record.get("state", -1)) == STATE_SNAPPED:
			return true
		await process_frame
	return false


func _wait_for_transform(
	manager: Node,
	window_id: StringName,
	expected: Transform3D
) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		var record := manager.get_window_state(window_id) as Dictionary
		var value = record.get("transform", null)
		if value is Transform3D and (value as Transform3D).is_equal_approx(expected):
			return true
		await process_frame
	return false


func _wait_for_controller_transform(
	controller: MockWindowController,
	expected: Transform3D
) -> bool:
	for _frame in range(SYNC_TIMEOUT_FRAMES):
		if controller.shared_transform.is_equal_approx(expected):
			return true
		await process_frame
	return false


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame


func _finish() -> void:
	for peer in _peers:
		if peer != null:
			peer.close()
	await _wait_frames(8)
	for child in root.get_children():
		if child is Node3D:
			child.queue_free()
	await _wait_frames(4)
	if _failures.is_empty():
		print("SPATIAL_WINDOW_NETWORK_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("SPATIAL_WINDOW_NETWORK_SELF_TEST: %s" % failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
