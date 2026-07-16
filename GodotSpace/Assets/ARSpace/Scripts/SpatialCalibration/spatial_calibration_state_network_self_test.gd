extends SceneTree

const CalibrationStateScript = preload("res://Assets/ARSpace/Scripts/SpatialCalibration/spatial_calibration_state.gd")

const CONNECT_TIMEOUT_FRAMES: int = 300
const STATE_TIMEOUT_FRAMES: int = 300

var _failures: Array[String] = []
var _peers: Array[ENetMultiplayerPeer] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var server_peer := ENetMultiplayerPeer.new()
	var port := _start_loopback_server(server_peer)
	if port == 0:
		_finish()
		return
	var server_context := _create_branch("CalibrationServer", server_peer)
	var server_state := _add_state(server_context["branch"] as Node)
	var server_origin := server_context["origin"] as Node3D
	var absolute_origin := Transform3D(Basis(Vector3.UP, 0.48), Vector3(1.5, 0.1, -2.0))
	_expect(
		bool(server_state.call("commit_calibration", absolute_origin, {"rms_error_m": 0.015}, "network_test")),
		"Server must commit an absolute calibration before clients join."
	)
	_expect(bool(server_state.call("set_preview", Vector3(0.1, 1.2, -0.6), {"depth_m": 1.8})), "Server preview must be accepted.")
	_expect(bool(server_state.call("confirm_point", Vector3(0.1, 1.2, -0.6), {"depth_m": 1.8})), "Server point must be accepted.")
	_expect(int(server_state.call("get_revision")) == 3, "Initial Server state must have three mutations.")

	var first_client_peer := ENetMultiplayerPeer.new()
	_expect(first_client_peer.create_client("127.0.0.1", port, 3) == OK, "First client should start connecting.")
	var first_context := _create_branch("CalibrationClientOne", first_client_peer)
	var first_state := _add_state(first_context["branch"] as Node)
	var first_origin := first_context["origin"] as Node3D
	_expect(await _wait_for_connection(first_client_peer), "First client must connect.")
	_expect(await _wait_for_revision(first_state, 3), "Late client must receive a reliable full snapshot.")
	_expect(first_origin.global_transform.is_equal_approx(absolute_origin), "Client snapshot must apply the absolute SharedSpaceOrigin.")
	var first_snapshot: Dictionary = first_state.call("get_state")
	_expect((first_snapshot["confirmed_points"] as Array).size() == 1, "Late snapshot must include confirmed points.")
	_expect(
		not bool(first_state.call("set_preview", Vector3.ZERO, {})),
		"Client must refuse all calibration writes."
	)
	await process_frame
	_expect(int(server_state.call("get_revision")) == 3, "Rejected client write must not mutate Server state.")

	first_client_peer.close()
	_expect(await _wait_for_revision(first_state, 0), "Disconnected client must clear its local calibration replica.")
	_expect(first_origin.global_transform.is_equal_approx(Transform3D.IDENTITY), "Disconnected client must restore a safe identity origin.")
	_expect(int(server_state.call("get_revision")) == 3, "One client disconnect must preserve Server calibration.")
	_expect(bool(server_state.call("begin_recalibration", "network_retry")), "Server must begin an explicit recalibration.")
	var replacement_origin := Transform3D(Basis(Vector3.UP, -0.27), Vector3(-1.0, 0.0, 0.75))
	_expect(
		bool(server_state.call("commit_calibration", replacement_origin, {"rms_error_m": 0.01}, "network_retry")),
		"Server must replace, not accumulate, the calibrated origin."
	)
	_expect(int(server_state.call("get_revision")) == 5, "Recalibration must advance the monotonic revision.")
	_expect(server_origin.global_transform.is_equal_approx(replacement_origin), "Server scene must apply replacement origin.")

	var second_client_peer := ENetMultiplayerPeer.new()
	_expect(second_client_peer.create_client("127.0.0.1", port, 3) == OK, "Replacement client should start connecting.")
	var second_context := _create_branch("CalibrationClientTwo", second_client_peer)
	var second_state := _add_state(second_context["branch"] as Node)
	var second_origin := second_context["origin"] as Node3D
	_expect(await _wait_for_connection(second_client_peer), "Replacement client must connect.")
	_expect(await _wait_for_revision(second_state, 5), "Replacement client must receive state changed while offline.")
	_expect(second_origin.global_transform.is_equal_approx(replacement_origin), "Reconnect snapshot must carry the latest absolute origin.")
	var second_snapshot: Dictionary = second_state.call("get_state")
	_expect(str(second_snapshot["status"]) == "calibrated", "Reconnect snapshot must preserve calibrated status.")
	_expect((second_snapshot["confirmed_points"] as Array).is_empty(), "Recalibration must not resurrect stale points.")

	server_peer.close()
	_expect(await _wait_for_revision(second_state, 0), "Server shutdown must clear connected client calibration.")
	_expect(second_origin.global_transform.is_equal_approx(Transform3D.IDENTITY), "Server shutdown must restore client identity origin.")
	server_state.call("_on_session_closed")
	_expect(int(server_state.call("get_revision")) == 0, "Explicit Server session close must clear authoritative state.")
	_expect(server_origin.global_transform.is_equal_approx(Transform3D.IDENTITY), "Explicit Server close must reset scene origin.")
	_finish()


func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43540, 43560):
		if peer.create_server(port, 2, 3) == OK:
			return port
	_expect(false, "Spatial calibration network test should bind a loopback port.")
	return 0


func _create_branch(branch_name: String, peer: ENetMultiplayerPeer) -> Dictionary:
	var api := SceneMultiplayer.new()
	api.multiplayer_peer = peer
	var branch := Node3D.new()
	branch.name = branch_name
	root.add_child(branch)
	set_multiplayer(api, branch.get_path())
	_peers.append(peer)
	var origin := Node3D.new()
	origin.name = "SharedSpaceOrigin"
	origin.add_to_group("shared_space_origin")
	branch.add_child(origin)
	return {"branch": branch, "origin": origin}


func _add_state(branch: Node) -> Node:
	var state: Node = CalibrationStateScript.new()
	state.name = "SpatialCalibrationState"
	state.set("shared_space_origin_path", NodePath("../SharedSpaceOrigin"))
	state.set("peer_authority_path", NodePath("../MissingNetworkHandler"))
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


func _wait_for_revision(state: Node, expected_revision: int) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if int(state.call("get_revision")) == expected_revision:
			return true
		await process_frame
	return false


func _finish() -> void:
	for peer in _peers:
		peer.close()
	if _failures.is_empty():
		print("Spatial calibration state network self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
