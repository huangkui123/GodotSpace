extends SceneTree

const NetworkHandlerScript = preload("res://Assets/ARSpace/Scripts/Network/network_handler.gd")
const CollaborationStateScript = preload("res://Assets/ARSpace/Scripts/Network/collaboration_state.gd")
const Schema = preload("res://Assets/ARSpace/Scripts/Network/collaboration_state_schema.gd")
const SpatialWindowRegistryScript = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_registry.gd")
const SpatialWindowState = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_state.gd")

const CONNECT_TIMEOUT_FRAMES: int = 300
const STATE_TIMEOUT_FRAMES: int = 300
const GROUND_TOKEN_ENV: String = "GODOTSPACE_GROUND_VR_TOKEN"

var _failures: Array[String] = []
var _peers: Array[ENetMultiplayerPeer] = []
var _previous_ground_token: String = ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_previous_ground_token = OS.get_environment(GROUND_TOKEN_ENV)
	OS.unset_environment(GROUND_TOKEN_ENV)
	var server_peer := ENetMultiplayerPeer.new()
	var port := _start_loopback_server(server_peer)
	if port <= 0:
		_finish()
		return
	var server_branch := _create_branch("CollaborationServer", server_peer)
	var server_handler := _add_network_handler(server_branch)
	var server_state := _add_collaboration_state(server_branch)
	var server_windows := _add_spatial_window_registry(server_branch)
	var initial_window_transform := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.2, -1.5))
	var initial_window_size := Vector2(1.0, 0.65)
	var primary_window_id := "phase1_acceptance_window"
	var primary_window_descriptor := {
		"window_id": primary_window_id,
		"window_type": "work_list",
		"instance_policy": SpatialWindowState.POLICY_UNIQUE,
		"content_key": "task-1",
		"shared_transform": initial_window_transform,
		"size_m": initial_window_size,
	}
	_expect(bool(server_windows.call("register_window", primary_window_descriptor)), "Server should register the initial spatial window.")
	_expect(int(server_windows.call("get_revision")) == 1, "Initial spatial-window registration should advance revision once.")

	var ground_peer := ENetMultiplayerPeer.new()
	_expect(ground_peer.create_client("127.0.0.1", port, 3) == OK, "Ground client should start connecting.")
	var ground_branch := _create_branch("CollaborationGround", ground_peer)
	_expect(await _wait_for_connection(ground_peer), "Ground client should connect.")
	var ground_handler := _add_network_handler(ground_branch)
	var ground_state := _add_collaboration_state(ground_branch)
	var ground_windows := _add_spatial_window_registry(ground_branch)
	var ground_id := ground_peer.get_unique_id()
	ground_handler.rpc_id(1, "_server_request_session_role", Schema.ROLE_GROUND_VR, "")
	_expect(await _wait_for_role(server_handler, ground_id, Schema.ROLE_GROUND_VR), "Server should register the Ground VR role.")
	_expect(await _wait_for_role(ground_handler, ground_id, Schema.ROLE_GROUND_VR), "Ground client should receive its authoritative role.")
	_expect(await _wait_for_window_revision(ground_windows, 1), "Ground client should receive the initial spatial-window snapshot.")
	_expect(
		bool(ground_windows.call("request_operation", primary_window_id, "acquire_lease", {"timeout_msec": 10000})),
		"Ground client should request a bounded manipulation lease."
	)
	_expect(await _wait_for_window_revision(server_windows, 2), "Server should grant the Ground manipulation lease.")
	_expect(await _wait_for_window_revision(ground_windows, 2), "Ground client should receive the granted manipulation lease.")
	var ground_window_state := ground_windows.call("get_window_state", primary_window_id) as Dictionary
	var ground_lease_token := str(ground_window_state.get("lease_token", ""))
	_expect(int(ground_window_state.get("lease_peer_id", 0)) == ground_id, "Ground client should own the manipulation lease.")
	_expect(not ground_lease_token.is_empty(), "Ground manipulation lease should carry an opaque token.")
	var server_preview_count := {"count": 0}
	server_windows.connect("window_preview_changed", func(received_window_id: String, _transform: Transform3D, _sequence: int) -> void:
		if received_window_id == primary_window_id:
			server_preview_count["count"] = int(server_preview_count["count"]) + 1
	)
	var preview_transform := Transform3D(Basis(Vector3.UP, 0.25), Vector3(0.5, 1.1, -1.25))
	var preview_queued := false
	for sequence in range(1, 21):
		preview_queued = bool(ground_windows.call("request_operation", primary_window_id, "transform_preview", {
			"shared_transform": preview_transform,
			"stream_sequence": sequence,
			"lease_token": ground_lease_token,
		})) or preview_queued
		await process_frame
	_expect(preview_queued, "Ground client should queue an unreliable drag preview.")
	_expect(await _wait_for_counter(server_preview_count, "count", 1), "Server should receive at least one Ground drag preview.")
	_expect(int(server_windows.call("get_revision")) == 2, "Drag previews must not advance durable spatial-window revision.")
	_expect(
		(server_windows.call("get_window_state", primary_window_id) as Dictionary).get("shared_transform") == initial_window_transform,
		"Drag previews must not replace the durable spatial-window transform."
	)

	ground_state.request_change(
		Schema.DOMAIN_ACTIVE_WINDOWS,
		Schema.OP_UPSERT,
		{
			"id": "task_window",
			"window_type": "task_panel",
			"visible": true,
			"closed": false,
		}
	)
	_expect(await _wait_for_revision(server_state, 1), "Server should accept the Ground VR window mutation.")
	_expect(await _wait_for_revision(ground_state, 1), "Ground client should receive the reliable state snapshot.")
	_expect(_has_paired_window(server_state, "task_window"), "Server window state must keep active/transform domains paired.")
	_expect(_has_paired_window(ground_state, "task_window"), "Client window snapshot must keep active/transform domains paired.")

	var retry_results: Array[Dictionary] = []
	ground_state.request_completed.connect(func(result: Dictionary) -> void:
		if str(result.get("domain", "")) == Schema.DOMAIN_STROKES:
			retry_results.append(result)
	)
	var stroke_payload := {
		"shared_points": PackedVector3Array([Vector3.ZERO, Vector3(0.0, 0.0, -1.0)]),
		"color": Color(0.2, 0.8, 1.0, 1.0),
		"width": 0.02,
		"confirmed": true,
	}
	var stroke_sequence: int = ground_state.request_change(Schema.DOMAIN_STROKES, Schema.OP_UPSERT, stroke_payload)
	_expect(ground_state.retry_request(stroke_sequence), "A connected client should be able to retry its exact request.")
	_expect(await _wait_for_revision(server_state, 2), "Server should accept one stroke mutation.")
	_expect(await _wait_for_results(retry_results, 2), "The original request and retry should both receive results.")
	_expect(retry_results[0] == retry_results[1], "An exact retry must receive the identical cached result.")
	_expect((server_state.get_domain_state(Schema.DOMAIN_STROKES) as Dictionary).size() == 1, "An exact retry must not create a duplicate stroke.")
	_expect(server_state.get_session_revision() == 2, "An exact retry must not increment the Server revision twice.")

	var astronaut_peer := ENetMultiplayerPeer.new()
	_expect(astronaut_peer.create_client("127.0.0.1", port, 3) == OK, "Astronaut client should start connecting.")
	var astronaut_branch := _create_branch("CollaborationAstronaut", astronaut_peer)
	_expect(await _wait_for_connection(astronaut_peer), "Astronaut client should connect.")
	var astronaut_handler := _add_network_handler(astronaut_branch)
	var astronaut_state := _add_collaboration_state(astronaut_branch)
	var astronaut_windows := _add_spatial_window_registry(astronaut_branch)
	var astronaut_id := astronaut_peer.get_unique_id()
	astronaut_handler.rpc_id(1, "_server_request_session_role", Schema.ROLE_GROUND_VR, "")
	_expect(await _wait_for_role(server_handler, astronaut_id, Schema.ROLE_ASTRONAUT), "Server should downgrade a competing Ground claimant to Astronaut.")
	_expect(await _wait_for_role(astronaut_handler, astronaut_id, Schema.ROLE_ASTRONAUT), "Competing Ground claimant should receive its authoritative Astronaut role.")
	_expect(await _wait_for_revision(astronaut_state, 2), "A late-joining Astronaut must receive the full current snapshot.")
	_expect(_has_paired_window(astronaut_state, "task_window"), "Late snapshot must include paired window domains.")
	_expect((astronaut_state.get_domain_state(Schema.DOMAIN_STROKES) as Dictionary).size() == 1, "Late snapshot must include confirmed strokes.")
	_expect(await _wait_for_window_revision(astronaut_windows, 2), "Competing Ground claimant should receive the current spatial-window snapshot.")
	var window_revision_before_rejection := int(server_windows.call("get_revision"))
	var window_state_before_rejection := server_windows.call("get_window_state", primary_window_id) as Dictionary
	var competing_ground_window_results: Array[Dictionary] = []
	astronaut_windows.connect("operation_completed", func(result: Dictionary) -> void:
		if str(result.get("operation", "")) == "acquire_lease":
			competing_ground_window_results.append(result)
	)
	_expect(
		bool(astronaut_windows.call("request_operation", primary_window_id, "acquire_lease", {"timeout_msec": 10000})),
		"Competing Ground claimant may queue a lease request for Server validation."
	)
	var competing_result_received := await _wait_for_results(competing_ground_window_results, 1)
	_expect(competing_result_received, "Competing Ground claimant should receive an authoritative lease result.")
	if competing_result_received:
		_expect(not bool(competing_ground_window_results[0].get("accepted", true)), "Downgraded Astronaut must not acquire a spatial-window lease.")
		_expect(str(competing_ground_window_results[0].get("error", "")) == "role_not_allowed", "Downgraded Astronaut lease rejection should report role_not_allowed.")
	_expect(int(server_windows.call("get_revision")) == window_revision_before_rejection, "Rejected competing Ground mutation must not advance spatial-window revision.")
	_expect(server_windows.call("get_window_state", primary_window_id) == window_state_before_rejection, "Rejected competing Ground mutation must not alter spatial-window state.")

	var astronaut_results: Array[Dictionary] = []
	astronaut_state.request_completed.connect(func(result: Dictionary) -> void: astronaut_results.append(result))
	astronaut_state.request_change(
		Schema.DOMAIN_MENU,
		Schema.OP_SET,
		{"mode": "work", "active_tab": "forged", "page_id": ""}
	)
	_expect(await _wait_for_results(astronaut_results, 1), "Astronaut ground-only request should receive a rejection result.")
	_expect(not bool(astronaut_results[0].get("accepted", true)) and str(astronaut_results[0].get("error", "")) == "role_not_allowed", "Server must reject an Astronaut menu mutation.")
	_expect(server_state.get_session_revision() == 2, "A rejected mutation must not increment revision.")

	astronaut_state.request_change(
		Schema.DOMAIN_MODELS,
		Schema.OP_UPSERT,
		{"model_id": "microscope", "shared_transform": Transform3D.IDENTITY}
	)
	_expect(await _wait_for_revision(server_state, 3), "Astronaut should place a whitelisted model.")
	_expect(await _wait_for_revision(ground_state, 3), "Existing Ground client should receive the Astronaut model snapshot.")
	_expect((server_state.get_domain_state(Schema.DOMAIN_MODELS) as Dictionary).size() == 1, "Server must allocate exactly one model instance.")

	var durable_window_before_disconnect := server_windows.call("get_window_state", primary_window_id) as Dictionary
	ground_peer.close()
	_expect(await _wait_for_role(server_handler, ground_id, "unknown"), "Disconnect must clear the Server role registry entry.")
	_expect(await _wait_for_revision(ground_state, 0), "Disconnected client must clear its local replica.")
	_expect(server_state.get_session_revision() == 3, "A client disconnect must preserve confirmed Server state.")
	_expect(await _wait_for_window_revision(server_windows, 3), "Ground disconnect during drag should release its spatial-window lease.")
	_expect(await _wait_for_window_revision(astronaut_windows, 3), "Lease release should replicate to the remaining client.")
	_expect(await _wait_for_window_revision(ground_windows, 0), "Disconnected Ground should clear its local spatial-window replica.")
	var window_after_disconnect := server_windows.call("get_window_state", primary_window_id) as Dictionary
	_expect(int(window_after_disconnect.get("lease_peer_id", -1)) == 0, "Ground disconnect should clear spatial-window lease ownership.")
	_expect(str(window_after_disconnect.get("lease_token", "not-cleared")) == "", "Ground disconnect should clear the spatial-window lease token.")
	_expect(int(window_after_disconnect.get("lease_expires_msec", -1)) == 0, "Ground disconnect should clear the spatial-window lease expiry.")
	_expect(window_after_disconnect.get("shared_transform") == durable_window_before_disconnect.get("shared_transform"), "Interrupted drag preview must not become the durable transform.")
	_expect(window_after_disconnect.get("size_m") == durable_window_before_disconnect.get("size_m"), "Interrupted drag preview must not change durable window size.")
	_expect((ground_windows.call("get_windows_snapshot") as Dictionary).is_empty(), "Disconnected Ground should retain no spatial-window records.")
	ground_handler.queue_free()
	await process_frame
	server_state.request_change(
		Schema.DOMAIN_TASK,
		Schema.OP_SET,
		{"task_id": 2, "step": 4, "event_revision": 1, "playback": "playing"}
	)
	_expect(await _wait_for_revision(server_state, 4), "Server should keep mutating the session while one client is disconnected.")
	var offline_window_id := "offline_window"
	_expect(bool(server_windows.call("register_window", {
		"window_id": offline_window_id,
		"window_type": "image",
		"instance_policy": SpatialWindowState.POLICY_UNIQUE,
		"content_key": "earth",
		"shared_transform": Transform3D(Basis.IDENTITY, Vector3(-0.8, 1.0, -1.0)),
		"size_m": Vector2(1.2, 0.75),
	})), "Server should register a second spatial window while Ground is offline.")
	_expect(await _wait_for_window_revision(astronaut_windows, 4), "Remaining client should receive the offline spatial-window mutation.")

	var replacement_peer := ENetMultiplayerPeer.new()
	_expect(replacement_peer.create_client("127.0.0.1", port, 3) == OK, "Ground reconnect should start connecting.")
	_peers.append(replacement_peer)
	ground_branch.multiplayer.multiplayer_peer = replacement_peer
	_expect(await _wait_for_connection(replacement_peer), "Ground client should reconnect.")
	ground_handler = _add_network_handler(ground_branch)
	var replacement_id := replacement_peer.get_unique_id()
	ground_handler.rpc_id(1, "_server_request_session_role", Schema.ROLE_GROUND_VR, "")
	_expect(await _wait_for_role(server_handler, replacement_id, Schema.ROLE_GROUND_VR), "Reconnected peer should reacquire Ground VR.")
	_expect(await _wait_for_role(ground_handler, replacement_id, Schema.ROLE_GROUND_VR), "Reconnected client should receive its new role.")
	_expect(await _wait_for_revision(ground_state, 4), "Reconnected client must receive a fresh full snapshot.")
	_expect(int((ground_state.get_domain_state(Schema.DOMAIN_TASK) as Dictionary).get("task_id", 0)) == 2, "Reconnect snapshot must include state changed while offline.")
	_expect(await _wait_for_window_revision(ground_windows, 4), "Reconnected Ground must receive the latest spatial-window revision.")
	_expect(
		ground_windows.call("get_windows_snapshot") == server_windows.call("get_windows_snapshot"),
		"Reconnected Ground must receive the complete authoritative spatial-window snapshot."
	)
	_expect((ground_windows.call("get_windows_snapshot") as Dictionary).size() == 2, "Reconnect snapshot should contain both authoritative spatial windows.")
	_expect(not (ground_windows.call("get_window_state", offline_window_id) as Dictionary).is_empty(), "Reconnect snapshot should include the window registered while Ground was offline.")
	_expect(int((ground_windows.call("get_window_state", primary_window_id) as Dictionary).get("lease_peer_id", -1)) == 0, "Reconnect snapshot must not restore the disconnected peer lease.")

	var reconnect_sequence: int = ground_state.request_change(
		Schema.DOMAIN_MEDIA,
		Schema.OP_UPSERT,
		{
			"id": "procedure_video",
			"media_id": "procedure_2",
			"media_type": "video",
			"playback": "playing",
			"position_ms": 1250,
		}
	)
	_expect(reconnect_sequence == 1, "A new client connection must restart its local request sequence.")
	_expect(await _wait_for_revision(server_state, 5), "Server must accept sequence one after the old peer cache was cleaned.")
	_expect((server_state.get_domain_state(Schema.DOMAIN_MEDIA) as Dictionary).size() == 1, "Reconnect mutation must create one media record.")

	server_peer.close()
	_expect(await _wait_for_revision(ground_state, 0), "Server shutdown must clear the Ground client replica.")
	_expect(await _wait_for_revision(astronaut_state, 0), "Server shutdown must clear the Astronaut client replica.")
	_expect(ground_state.get_state() == Schema.make_default_state(), "Ground cleanup must restore the full default schema.")
	_expect(astronaut_state.get_state() == Schema.make_default_state(), "Astronaut cleanup must restore the full default schema.")
	_expect(await _wait_for_window_revision(ground_windows, 0), "Server shutdown must clear the Ground spatial-window replica.")
	_expect(await _wait_for_window_revision(astronaut_windows, 0), "Server shutdown must clear the Astronaut spatial-window replica.")
	_expect((ground_windows.call("get_windows_snapshot") as Dictionary).is_empty(), "Ground should retain no spatial-window records after Server shutdown.")
	_expect((astronaut_windows.call("get_windows_snapshot") as Dictionary).is_empty(), "Astronaut should retain no spatial-window records after Server shutdown.")
	_expect((ground_windows.call("get_active_windows") as Array).is_empty(), "Ground should retain no active spatial windows after Server shutdown.")
	_expect((astronaut_windows.call("get_active_windows") as Array).is_empty(), "Astronaut should retain no active spatial windows after Server shutdown.")
	_finish()


func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43400, 43420):
		if peer.create_server(port, 2, 3) == OK:
			return port
	_expect(false, "Collaboration state test should bind a loopback port.")
	return 0


func _create_branch(branch_name: String, peer: ENetMultiplayerPeer) -> Node:
	var api := SceneMultiplayer.new()
	api.multiplayer_peer = peer
	var branch := Node.new()
	branch.name = branch_name
	root.add_child(branch)
	set_multiplayer(api, branch.get_path())
	_peers.append(peer)
	return branch


func _add_network_handler(branch: Node) -> Node:
	var handler: Node = NetworkHandlerScript.new()
	handler.name = "NetworkHandler"
	branch.add_child(handler)
	return handler


func _add_collaboration_state(branch: Node) -> Node:
	var state: Node = CollaborationStateScript.new()
	state.name = "CollaborationState"
	state.peer_authority_path = NodePath("../NetworkHandler")
	branch.add_child(state)
	return state


func _add_spatial_window_registry(branch: Node) -> Node:
	var registry: Node = SpatialWindowRegistryScript.new()
	registry.name = "SpatialWindowRegistryService"
	registry.set("peer_authority_path", NodePath("../NetworkHandler"))
	branch.add_child(registry)
	return registry


func _wait_for_connection(peer: ENetMultiplayerPeer) -> bool:
	for _frame in range(CONNECT_TIMEOUT_FRAMES):
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await process_frame
	return false


func _wait_for_role(handler: Node, peer_id: int, expected_role: String) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if str(handler.call("get_peer_role", peer_id)) == expected_role:
			return true
		await process_frame
	return false


func _wait_for_revision(state: Node, expected_revision: int) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if int(state.call("get_session_revision")) == expected_revision:
			return true
		await process_frame
	return false


func _wait_for_window_revision(registry: Node, expected_revision: int) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if int(registry.call("get_revision")) == expected_revision:
			return true
		await process_frame
	return false


func _wait_for_counter(container: Dictionary, key: String, expected_count: int) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if int(container.get(key, 0)) >= expected_count:
			return true
		await process_frame
	return false


func _wait_for_results(results: Array[Dictionary], expected_count: int) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if results.size() >= expected_count:
			return true
		await process_frame
	return false


func _has_paired_window(state: Node, entity_id: String) -> bool:
	var snapshot: Dictionary = state.call("get_state")
	return (snapshot[Schema.DOMAIN_ACTIVE_WINDOWS] as Dictionary).has(entity_id) \
		and (snapshot[Schema.DOMAIN_WINDOW_TRANSFORMS] as Dictionary).has(entity_id)


func _finish() -> void:
	for peer in _peers:
		peer.close()
	if _previous_ground_token.is_empty():
		OS.unset_environment(GROUND_TOKEN_ENV)
	else:
		OS.set_environment(GROUND_TOKEN_ENV, _previous_ground_token)
	if _failures.is_empty():
		print("Collaboration state network self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
