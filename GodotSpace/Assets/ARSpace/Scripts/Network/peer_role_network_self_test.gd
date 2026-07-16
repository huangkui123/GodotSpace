extends SceneTree

const NETWORK_HANDLER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/Network/network_handler.gd")
const TOKEN_ENV: String = "GODOTSPACE_GROUND_VR_TOKEN"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_ASTRONAUT: String = "astronaut"
const CONNECT_TIMEOUT_FRAMES: int = 300
const ROLE_TIMEOUT_FRAMES: int = 180

var _failures: Array[String] = []
var _branches: Array[Node] = []
var _peers: Array[ENetMultiplayerPeer] = []
var _previous_token: String = ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_previous_token = OS.get_environment(TOKEN_ENV)
	OS.unset_environment(TOKEN_ENV)
	var server_peer := ENetMultiplayerPeer.new()
	var port := _start_loopback_server(server_peer)
	if port <= 0:
		_finish()
		return
	var server_branch := _create_branch("RoleServer", server_peer)
	var server_handler := _add_role_handler(server_branch)

	var first_client_peer := ENetMultiplayerPeer.new()
	_expect(first_client_peer.create_client("127.0.0.1", port, 3) == OK, "First role client should start connecting.")
	var first_client_branch := _create_branch("RoleClientOne", first_client_peer)
	_expect(await _wait_for_connection(first_client_peer), "First role client should connect.")
	var first_handler := _add_role_handler(first_client_branch)
	var first_id := first_client_peer.get_unique_id()
	first_handler.rpc_id(1, "_server_request_session_role", ROLE_GROUND_VR, "")
	_expect(
		await _wait_for_role(server_handler, first_id, ROLE_GROUND_VR),
		"Server should assign the first Ground VR request."
	)
	_expect(
		await _wait_for_role(first_handler, first_id, ROLE_GROUND_VR),
		"Ground VR client should receive its authoritative role snapshot."
	)

	var second_client_peer := ENetMultiplayerPeer.new()
	_expect(second_client_peer.create_client("127.0.0.1", port, 3) == OK, "Second role client should start connecting.")
	var second_client_branch := _create_branch("RoleClientTwo", second_client_peer)
	_expect(await _wait_for_connection(second_client_peer), "Second role client should connect.")
	var second_handler := _add_role_handler(second_client_branch)
	var second_id := second_client_peer.get_unique_id()
	second_handler.rpc_id(1, "_server_request_session_role", ROLE_GROUND_VR, "")
	_expect(
		await _wait_for_role(server_handler, second_id, ROLE_ASTRONAUT),
		"Server should keep a competing Ground VR claimant in the Astronaut role."
	)
	_expect(
		await _wait_for_role(second_handler, second_id, ROLE_ASTRONAUT),
		"Rejected Ground VR claimant should receive the Astronaut assignment."
	)
	_expect(bool(server_handler.call("can_peer_annotate", first_id)), "Assigned Ground VR should annotate on the Server.")
	_expect(not bool(server_handler.call("can_peer_annotate", second_id)), "Competing claimant should not annotate on the Server.")

	second_handler.rpc_id(1, "_server_request_session_role", ROLE_GROUND_VR, "")
	for _frame in range(10):
		await process_frame
	_expect(
		str(server_handler.call("get_peer_role", second_id)) == ROLE_ASTRONAUT,
		"A repeated role request must not change the Server assignment."
	)

	first_client_peer.close()
	_expect(
		await _wait_for_role(server_handler, first_id, "unknown"),
		"Disconnecting Ground VR should remove its role registration."
	)

	var replacement_peer := ENetMultiplayerPeer.new()
	_expect(replacement_peer.create_client("127.0.0.1", port, 3) == OK, "Replacement Ground VR should start connecting.")
	var replacement_branch := _create_branch("RoleClientReplacement", replacement_peer)
	_expect(await _wait_for_connection(replacement_peer), "Replacement Ground VR should connect.")
	var replacement_handler := _add_role_handler(replacement_branch)
	var replacement_id := replacement_peer.get_unique_id()
	replacement_handler.rpc_id(1, "_server_request_session_role", ROLE_GROUND_VR, "")
	_expect(
		await _wait_for_role(server_handler, replacement_id, ROLE_GROUND_VR),
		"A replacement peer should receive the released Ground VR slot."
	)
	_expect(
		await _wait_for_role(second_handler, replacement_id, ROLE_GROUND_VR),
		"Existing Astronaut peers should receive the replacement Ground VR role snapshot."
	)
	_finish()


func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43220, 43240):
		if peer.create_server(port, 2, 3) == OK:
			return port
	_expect(false, "Role registry test should bind a loopback port.")
	return 0


func _create_branch(branch_name: String, peer: ENetMultiplayerPeer) -> Node:
	var api := SceneMultiplayer.new()
	api.multiplayer_peer = peer
	var branch := Node.new()
	branch.name = branch_name
	root.add_child(branch)
	set_multiplayer(api, branch.get_path())
	_branches.append(branch)
	_peers.append(peer)
	return branch


func _add_role_handler(branch: Node) -> Node:
	var handler: Node = NETWORK_HANDLER_SCRIPT.new()
	handler.name = "NetworkHandler"
	branch.add_child(handler)
	return handler


func _wait_for_connection(peer: ENetMultiplayerPeer) -> bool:
	for _frame in range(CONNECT_TIMEOUT_FRAMES):
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await process_frame
	return false


func _wait_for_role(handler: Node, peer_id: int, expected_role: String) -> bool:
	for _frame in range(ROLE_TIMEOUT_FRAMES):
		if str(handler.call("get_peer_role", peer_id)) == expected_role:
			return true
		await process_frame
	return false


func _finish() -> void:
	for peer in _peers:
		peer.close()
	if _previous_token.is_empty():
		OS.unset_environment(TOKEN_ENV)
	else:
		OS.set_environment(TOKEN_ENV, _previous_token)
	if _failures.is_empty():
		print("Peer role network self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
