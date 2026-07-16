extends SceneTree

const NetworkHandlerScript = preload("res://Assets/ARSpace/Scripts/Network/network_handler.gd")
const CollaborationStateScript = preload("res://Assets/ARSpace/Scripts/Network/collaboration_state.gd")
const Schema = preload("res://Assets/ARSpace/Scripts/Network/collaboration_state_schema.gd")

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

	var ground_peer := ENetMultiplayerPeer.new()
	_expect(ground_peer.create_client("127.0.0.1", port, 3) == OK, "Ground client should start connecting.")
	var ground_branch := _create_branch("CollaborationGround", ground_peer)
	_expect(await _wait_for_connection(ground_peer), "Ground client should connect.")
	var ground_handler := _add_network_handler(ground_branch)
	var ground_state := _add_collaboration_state(ground_branch)
	var ground_id := ground_peer.get_unique_id()
	ground_handler.rpc_id(1, "_server_request_session_role", Schema.ROLE_GROUND_VR, "")
	_expect(await _wait_for_role(server_handler, ground_id, Schema.ROLE_GROUND_VR), "Server should register the Ground VR role.")
	_expect(await _wait_for_role(ground_handler, ground_id, Schema.ROLE_GROUND_VR), "Ground client should receive its authoritative role.")

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
	var astronaut_id := astronaut_peer.get_unique_id()
	astronaut_handler.rpc_id(1, "_server_request_session_role", Schema.ROLE_ASTRONAUT, "")
	_expect(await _wait_for_role(server_handler, astronaut_id, Schema.ROLE_ASTRONAUT), "Server should register the Astronaut role.")
	_expect(await _wait_for_role(astronaut_handler, astronaut_id, Schema.ROLE_ASTRONAUT), "Astronaut client should receive its role snapshot.")
	_expect(await _wait_for_revision(astronaut_state, 2), "A late-joining Astronaut must receive the full current snapshot.")
	_expect(_has_paired_window(astronaut_state, "task_window"), "Late snapshot must include paired window domains.")
	_expect((astronaut_state.get_domain_state(Schema.DOMAIN_STROKES) as Dictionary).size() == 1, "Late snapshot must include confirmed strokes.")

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

	ground_peer.close()
	_expect(await _wait_for_role(server_handler, ground_id, "unknown"), "Disconnect must clear the Server role registry entry.")
	_expect(await _wait_for_revision(ground_state, 0), "Disconnected client must clear its local replica.")
	_expect(server_state.get_session_revision() == 3, "A client disconnect must preserve confirmed Server state.")
	ground_handler.queue_free()
	await process_frame
	server_state.request_change(
		Schema.DOMAIN_TASK,
		Schema.OP_SET,
		{"task_id": 2, "step": 4, "event_revision": 1, "playback": "playing"}
	)
	_expect(await _wait_for_revision(server_state, 4), "Server should keep mutating the session while one client is disconnected.")

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
