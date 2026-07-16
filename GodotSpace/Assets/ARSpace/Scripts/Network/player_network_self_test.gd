extends Node

const PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const SPAWNER_SCRIPT: Script = preload("res://Assets/ARSpace/Scripts/Network/multiplayer_spawner.gd")
const PoseState = preload("res://Assets/ARSpace/Characters/Astronaut/avatar_pose_state.gd")
const CONNECT_TIMEOUT_FRAMES: int = 300
const REPLICATION_TIMEOUT_FRAMES: int = 180

var _failures: Array[String] = []
var _branches: Array[Node] = []
var _apis: Array[SceneMultiplayer] = []
var _peers: Array[ENetMultiplayerPeer] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var server_peer := ENetMultiplayerPeer.new()
	var port := _start_loopback_server(server_peer)
	if port <= 0:
		_finish()
		return

	var server_api := SceneMultiplayer.new()
	server_api.multiplayer_peer = server_peer
	var server_branch := _create_branch("ServerBranch", server_api)

	var first_client_peer := ENetMultiplayerPeer.new()
	_check(first_client_peer.create_client("127.0.0.1", port) == OK, "first client should begin connecting")
	var first_client_api := SceneMultiplayer.new()
	first_client_api.multiplayer_peer = first_client_peer
	var first_client_branch := _create_branch("FirstClientBranch", first_client_api)
	_check(await _wait_for_connection(first_client_peer), "first client should connect")

	_add_spawner(first_client_branch)
	_add_spawner(server_branch)
	var first_client_id := first_client_peer.get_unique_id()
	var initial_ids: Array[String] = ["1", str(first_client_id)]
	_check(await _wait_for_players(server_branch, initial_ids), "server should contain peer 1 and first client")
	_check(await _wait_for_players(first_client_branch, initial_ids), "first client should receive existing players")

	var second_client_peer := ENetMultiplayerPeer.new()
	_check(second_client_peer.create_client("127.0.0.1", port) == OK, "late client should begin connecting")
	var second_client_api := SceneMultiplayer.new()
	second_client_api.multiplayer_peer = second_client_peer
	var second_client_branch := _create_branch("SecondClientBranch", second_client_api)
	_add_spawner(second_client_branch)
	_check(await _wait_for_connection(second_client_peer), "late client should connect")
	var second_client_id := second_client_peer.get_unique_id()
	var all_ids: Array[String] = ["1", str(first_client_id), str(second_client_id)]
	_check(await _wait_for_players(server_branch, all_ids), "server should add late client")
	_check(await _wait_for_players(first_client_branch, all_ids), "first client should receive late client")
	_check(await _wait_for_players(second_client_branch, all_ids), "late client should receive the full player snapshot")

	await _check_server_pose_broadcast(server_branch, first_client_branch)
	await _check_client_pose_relay(first_client_branch, server_branch, first_client_id)
	await _check_stale_pose_rejected(first_client_branch, server_branch, first_client_id)
	await _check_spoofed_pose_rejected(second_client_branch, server_branch, first_client_id)

	first_client_peer.close()
	_check(
		await _wait_for_player_removed(server_branch, str(first_client_id)),
		"server should remove a disconnected client"
	)
	_check(
		await _wait_for_player_removed(second_client_branch, str(first_client_id)),
		"remaining client should receive disconnected-player cleanup"
	)

	var reconnect_peer := ENetMultiplayerPeer.new()
	_check(reconnect_peer.create_client("127.0.0.1", port) == OK, "replacement client should begin reconnecting")
	var reconnect_api := SceneMultiplayer.new()
	reconnect_api.multiplayer_peer = reconnect_peer
	var reconnect_branch := _create_branch("ReconnectClientBranch", reconnect_api)
	_add_spawner(reconnect_branch)
	_check(await _wait_for_connection(reconnect_peer), "replacement client should reconnect")
	var reconnect_id := reconnect_peer.get_unique_id()
	var reconnect_ids: Array[String] = ["1", str(second_client_id), str(reconnect_id)]
	_check(await _wait_for_players(server_branch, reconnect_ids), "server should add the reconnected peer once")
	_check(await _wait_for_players(second_client_branch, reconnect_ids), "existing client should add the reconnected peer once")
	_check(await _wait_for_players(reconnect_branch, reconnect_ids), "reconnected client should receive the current player snapshot")
	_check(reconnect_branch.get_node_or_null(str(first_client_id)) == null, "reconnected client must not restore the stale peer id")
	_check(_count_player_nodes(server_branch) == 3, "server must contain exactly three unique player nodes after reconnect")
	_check(_count_player_nodes(reconnect_branch) == 3, "reconnected client must contain exactly three unique player nodes")

	_finish()

func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43160, 43180):
		if peer.create_server(port, 2) == OK:
			return port
	_check(false, "loopback ENet server should bind an available test port")
	return 0

func _create_branch(branch_name: String, api: SceneMultiplayer) -> Node3D:
	var branch := Node3D.new()
	branch.name = branch_name
	get_tree().root.add_child(branch)
	get_tree().set_multiplayer(api, branch.get_path())
	_branches.append(branch)
	_apis.append(api)
	var peer := api.multiplayer_peer as ENetMultiplayerPeer
	if peer != null:
		_peers.append(peer)
	return branch

func _add_spawner(branch: Node) -> void:
	var spawner := SPAWNER_SCRIPT.new() as MultiplayerSpawner
	spawner.name = "MultiplayerSpawner"
	spawner.spawn_path = NodePath("..")
	spawner.network_player = PLAYER_SCENE
	branch.add_child(spawner)

func _wait_for_connection(peer: ENetMultiplayerPeer) -> bool:
	for _frame in range(CONNECT_TIMEOUT_FRAMES):
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await get_tree().process_frame
	return false

func _wait_for_players(branch: Node, player_ids: Array[String]) -> bool:
	for _frame in range(REPLICATION_TIMEOUT_FRAMES):
		var has_all_players := true
		for player_id in player_ids:
			if branch.get_node_or_null(player_id) == null:
				has_all_players = false
				break
		if has_all_players:
			return true
		await get_tree().process_frame
	return false

func _wait_for_player_removed(branch: Node, player_id: String) -> bool:
	for _frame in range(REPLICATION_TIMEOUT_FRAMES):
		if branch.get_node_or_null(player_id) == null:
			return true
		await get_tree().process_frame
	return false

func _count_player_nodes(branch: Node) -> int:
	var count := 0
	for child in branch.get_children():
		if str(child.name).is_valid_int():
			count += 1
	return count

func _check_server_pose_broadcast(server_branch: Node, client_branch: Node) -> void:
	var server_player := server_branch.get_node_or_null("1")
	var client_view := client_branch.get_node_or_null("1")
	_check(server_player != null and client_view != null, "server player should exist on both peers")
	if server_player == null or client_view == null:
		return

	var head := Transform3D(Basis.IDENTITY, Vector3(-1.0, 1.7, 2.0))
	var left_hand := Transform3D(Basis.IDENTITY, Vector3(-1.25, 1.3, 1.8))
	var right_hand := Transform3D(Basis.IDENTITY, Vector3(-0.75, 1.3, 1.8))
	server_player.set_process(false)
	server_player.call("_broadcast_pose_to_clients", 1000001, head, left_hand, right_hand)
	_check(await _wait_for_head_position(client_view, head.origin), "client should display the server pose")
	var network_head := client_view.get_node_or_null("NetworkHead") as Node3D
	_check(network_head != null and network_head.global_position.is_equal_approx(head.origin), "server pose should retain shared-space position")

func _check_client_pose_relay(client_branch: Node, server_branch: Node, client_id: int) -> void:
	var client_player := client_branch.get_node_or_null(str(client_id))
	var server_view := server_branch.get_node_or_null(str(client_id))
	_check(client_player != null and server_view != null, "client player should exist on client and server")
	if client_player == null or server_view == null:
		return

	var head := Transform3D(Basis.IDENTITY, Vector3(2.0, 1.65, -1.0))
	var left_hand := Transform3D(Basis.IDENTITY, Vector3(1.75, 1.25, -1.2))
	var right_hand := Transform3D(Basis.IDENTITY, Vector3(2.25, 1.25, -1.2))
	var pose_state := PoseState.from_actions(
		PoseState.TRACKING_ALL,
		PoseState.INPUT_MODE_LEFT_HAND,
		0.75,
		0.5,
		0.25,
		1.0,
		PoseState.GESTURE_LEFT_TRIGGER_CLICK | PoseState.GESTURE_RIGHT_GRIP_CLICK
	)
	client_player.set_process(false)
	client_player.rpc_id(1, "_server_receive_pose", 1000001, head, left_hand, right_hand, pose_state)
	_check(await _wait_for_head_position(server_view, head.origin), "server should display the client pose")
	var network_head := server_view.get_node_or_null("NetworkHead") as Node3D
	_check(network_head != null and network_head.global_position.is_equal_approx(head.origin), "client pose should retain shared-space position")
	_check(server_view.get("_last_applied_pose_state") == pose_state, "server should validate and retain bounded gesture state")

func _check_stale_pose_rejected(client_branch: Node, server_branch: Node, client_id: int) -> void:
	var client_player := client_branch.get_node_or_null(str(client_id))
	var server_view := server_branch.get_node_or_null(str(client_id))
	if client_player == null or server_view == null:
		_check(false, "stale-pose test requires the client player on both peers")
		return
	var stale_head := Transform3D(Basis.IDENTITY, Vector3(8.0, 1.0, 8.0))
	client_player.rpc_id(1, "_server_receive_pose", 1000000, stale_head, stale_head, stale_head)
	for _frame in range(10):
		await get_tree().process_frame
	var network_head := server_view.get_node_or_null("NetworkHead") as Node3D
	_check(network_head != null and not network_head.global_position.is_equal_approx(stale_head.origin), "server must discard an older pose sequence")

func _check_spoofed_pose_rejected(attacker_branch: Node, server_branch: Node, victim_id: int) -> void:
	var spoofing_replica := attacker_branch.get_node_or_null(str(victim_id))
	var server_view := server_branch.get_node_or_null(str(victim_id))
	if spoofing_replica == null or server_view == null:
		_check(false, "spoofing test requires the victim replica on both peers")
		return
	var spoofed_head := Transform3D(Basis.IDENTITY, Vector3(-9.0, 1.0, -9.0))
	spoofing_replica.rpc_id(1, "_server_receive_pose", 2000000, spoofed_head, spoofed_head, spoofed_head)
	for _frame in range(10):
		await get_tree().process_frame
	var network_head := server_view.get_node_or_null("NetworkHead") as Node3D
	_check(network_head != null and not network_head.global_position.is_equal_approx(spoofed_head.origin), "server must reject a pose sent for another peer's player node")

func _wait_for_head_position(player: Node, expected_position: Vector3) -> bool:
	for _frame in range(REPLICATION_TIMEOUT_FRAMES):
		var network_head := player.get_node_or_null("NetworkHead") as Node3D
		if network_head != null \
			and network_head.visible \
			and network_head.global_position.is_equal_approx(expected_position):
			return true
		await get_tree().process_frame
	return false

func _finish() -> void:
	for peer in _peers:
		peer.close()
	await get_tree().process_frame

	if _failures.is_empty():
		print("PLAYER_NETWORK_SELF_TEST PASS")
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("PLAYER_NETWORK_SELF_TEST: %s" % failure)
	get_tree().quit(1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
