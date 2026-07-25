extends SceneTree

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const ManagerScript := preload("res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_drawing_manager.gd")
const RendererScript := preload("res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_stroke_renderer.gd")
const CONNECT_TIMEOUT_FRAMES: int = 300
const SYNC_TIMEOUT_FRAMES: int = 300
const SERVER_PEER_ID: int = 1

var _failures: Array[String] = []
var _peers: Array[ENetMultiplayerPeer] = []


class MockPeerAuthority extends Node:
	var local_role: String = "pc_ground"
	var drawing_peers: Dictionary = {}

	func get_local_assigned_role() -> String:
		return local_role

	func can_peer_draw(peer_id: int) -> bool:
		return bool(drawing_peers.get(peer_id, false))


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	RuntimeProfile.select_session_mode(RuntimeProfile.Preset.PC_GROUND_SERVER, false)
	var server_peer := ENetMultiplayerPeer.new()
	var port := _start_loopback_server(server_peer)
	if port <= 0:
		await _finish()
		return
	var server_api := SceneMultiplayer.new()
	server_api.multiplayer_peer = server_peer
	var server_branch := _create_branch("ServerBranch", server_api)
	var server_authority := _add_peer_authority(server_branch, "pc_ground")
	var server_manager = _add_drawing_manager(server_branch)

	var ground_peer := ENetMultiplayerPeer.new()
	_check(ground_peer.create_client("127.0.0.1", port) == OK, "Ground VR should begin connecting")
	var ground_api := SceneMultiplayer.new()
	ground_api.multiplayer_peer = ground_peer
	var ground_branch := _create_branch("GroundBranch", ground_api)
	_add_peer_authority(ground_branch, "ground_vr")
	var ground_manager = _add_drawing_manager(ground_branch)
	_check(await _wait_for_connection(ground_peer), "Ground VR should connect")
	var ground_id := ground_api.get_unique_id()
	server_authority.drawing_peers[ground_id] = true
	_check(ground_manager.can_local_draw(), "registered Ground VR should draw")

	var sky_peer := ENetMultiplayerPeer.new()
	_check(sky_peer.create_client("127.0.0.1", port) == OK, "Sky should begin connecting")
	var sky_api := SceneMultiplayer.new()
	sky_api.multiplayer_peer = sky_peer
	var sky_branch := _create_branch("SkyBranch", sky_api)
	_add_peer_authority(sky_branch, "sky")
	var sky_manager = _add_drawing_manager(sky_branch)
	_check(await _wait_for_connection(sky_peer), "Sky should connect")
	var sky_id := sky_api.get_unique_id()
	server_authority.drawing_peers[sky_id] = true
	_check(sky_manager.can_local_draw(), "registered Sky should draw")

	var ground_draft := _make_draft(101, 300, Vector3.ZERO, Color.RED)
	var ground_sequences: PackedInt32Array = ground_manager.submit_drafts([ground_draft])
	_check(ground_sequences.size() == 1, "Ground VR submission should allocate a request sequence")
	_check(await _wait_for_count(server_manager, 1), "Server should assemble a chunked Ground VR stroke")
	_check(await _wait_for_count(ground_manager, 1), "Ground VR should receive the authoritative record")
	_check(await _wait_for_count(sky_manager, 1), "Sky should receive the authoritative record")
	var ground_stroke_id := _find_stroke_by_local_shape(server_manager, 300, Color.RED)
	_check(ground_stroke_id > 0, "Server should allocate the Ground VR stroke id")
	_check(
		int(server_manager.get_stroke(ground_stroke_id).get("creator_peer_id", 0)) == ground_id,
		"Server must derive creator from the authenticated sender"
	)

	var sky_a := _make_draft(201, 129, Vector3(0, 1, 0), Color.BLUE)
	var sky_b := _make_draft(202, 10, Vector3(0, 2, 0), Color.GREEN)
	var sky_sequences: PackedInt32Array = sky_manager.submit_drafts([sky_a, sky_b])
	_check(sky_sequences.size() == 2, "Sky batch should create two bounded submissions")
	_check(await _wait_for_count(server_manager, 3), "concurrent Sky submissions should produce unique strokes")
	_check(await _wait_for_count(ground_manager, 3), "Ground VR should receive both Sky strokes")
	_check(await _wait_for_count(sky_manager, 3), "Sky should receive both confirmations")
	var ids: Dictionary = {}
	for stroke_value in server_manager.get_strokes():
		var stroke := stroke_value as Dictionary
		ids[int(stroke.get("stroke_id", 0))] = true
	_check(ids.size() == 3, "Server-assigned stroke ids must be unique")

	var revision_before_wrong_delete := int(server_manager.get_state_revision())
	_check(sky_manager.delete_stroke(ground_stroke_id), "Sky may submit an ownership-checked delete")
	await _wait_frames(12)
	_check(not server_manager.get_stroke(ground_stroke_id).is_empty(), "Sky must not delete a Ground VR stroke")
	_check(
		int(server_manager.get_state_revision()) == revision_before_wrong_delete,
		"rejected ownership delete must not advance revision"
	)
	_check(ground_manager.delete_stroke(ground_stroke_id), "Ground VR should delete its own stroke")
	_check(await _wait_for_count(server_manager, 2), "owner delete should reach Server authority")
	_check(await _wait_for_count(sky_manager, 2), "owner delete should broadcast")

	# An unauthorized but role-shaped client payload must fail at Server
	# permission, proving that role/creator fields in the payload are ignored.
	server_authority.drawing_peers[sky_id] = false
	var unauthorized_revision := int(server_manager.get_state_revision())
	var unauthorized := _make_draft(203, 4, Vector3(0, 3, 0), Color.YELLOW)
	sky_manager.set("_next_client_operation_sequence", 20)
	sky_manager.submit_drafts([unauthorized])
	await _wait_frames(12)
	_check(server_manager.get_stroke_count() == 2, "Server should reject an unauthorized Sky-shaped request")
	_check(
		int(server_manager.get_state_revision()) == unauthorized_revision,
		"unauthorized request must not advance revision"
	)
	_check(sky_manager.request_clear_published(), "unauthorized Sky may send a role-shaped clear request")
	await _wait_frames(12)
	_check(server_manager.get_stroke_count() == 2, "Server should reject an unauthorized synchronized clear")
	_check(
		int(server_manager.get_state_revision()) == unauthorized_revision,
		"unauthorized clear must not advance revision"
	)
	server_authority.drawing_peers[sky_id] = true
	sky_manager.set("_next_client_operation_sequence", 22)

	# Disconnect Sky, mutate authority, then reuse the same scene branch with a
	# fresh ENet peer. Snapshot staging must atomically replace stale content.
	sky_peer.close()
	await _wait_frames(12)
	_check(ground_manager.request_clear_published(), "Ground VR should submit synchronized clear")
	_check(await _wait_for_count(server_manager, 0), "Server should clear all published strokes")
	var replacement := _make_draft(301, 140, Vector3(0, 4, 0), Color.MAGENTA)
	ground_manager.set("_next_client_operation_sequence", 30)
	ground_manager.submit_drafts([replacement])
	_check(await _wait_for_count(server_manager, 1), "Server should accept a post-disconnect stroke")

	var reconnect_peer := ENetMultiplayerPeer.new()
	_check(reconnect_peer.create_client("127.0.0.1", port) == OK, "Sky should begin reconnecting")
	_peers.append(reconnect_peer)
	sky_api.multiplayer_peer = reconnect_peer
	_check(await _wait_for_connection(reconnect_peer), "Sky should reconnect")
	var reconnect_id := sky_api.get_unique_id()
	server_authority.drawing_peers[reconnect_id] = true
	_check(await _wait_for_count(sky_manager, 1), "reconnected Sky should apply the chunked snapshot")
	_check(
		_find_stroke_by_local_shape(sky_manager, 140, Color.MAGENTA) > 0,
		"reconnected snapshot should contain only the replacement stroke"
	)

	var repeated_snapshots: Array[int] = []
	sky_manager.snapshot_applied.connect(func(revision: int, _count: int) -> void:
		repeated_snapshots.append(revision)
	)
	sky_manager.request_snapshot()
	await _wait_frames(12)
	_check(sky_manager.get_stroke_count() == 1, "repeated snapshot should be idempotent")
	_check(repeated_snapshots.is_empty(), "identical snapshot should not duplicate UI side effects")

	# Exercise malformed upload paths directly over real reliable ENet.
	var baseline_count := int(server_manager.get_stroke_count())
	var baseline_revision := int(server_manager.get_state_revision())
	var metadata := {
		"local_id": 401,
		"color": Color.WHITE,
		"width_m": 0.01,
		"completed": true,
	}
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 50, metadata, 2, 1)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_receive_stroke_chunk",
		50,
		0,
		PackedVector3Array([Vector3.ZERO, Vector3(NAN, 0, 0)])
	)
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_finish_stroke_submission", 50)
	await _wait_frames(10)
	_check(server_manager.get_stroke_count() == baseline_count, "Server should reject NaN points")
	_check(int(server_manager.get_state_revision()) == baseline_revision, "NaN upload must not advance revision")

	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 51, metadata, 2, 1)
	var valid_chunk := PackedVector3Array([Vector3.ZERO, Vector3(0.1, 0, 0)])
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_receive_stroke_chunk", 51, 0, valid_chunk)
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_receive_stroke_chunk", 51, 0, valid_chunk)
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_finish_stroke_submission", 51)
	await _wait_frames(10)
	_check(server_manager.get_stroke_count() == baseline_count, "duplicate chunk must not half-publish")

	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 52, metadata, 129, 2)
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_receive_stroke_chunk", 52, 0, _make_points(128, Vector3(1, 0, 0)))
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_finish_stroke_submission", 52)
	await _wait_frames(10)
	_check(server_manager.get_stroke_count() == baseline_count, "missing chunk must not publish")

	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 53, metadata, 2049, 17)
	await _wait_frames(8)
	_check(server_manager.get_stroke_count() == baseline_count, "2049-point declaration must be rejected")
	_check(int(server_manager.get_state_revision()) == baseline_revision, "malformed requests must not alter authority")

	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 54, metadata, 2, 1)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_receive_stroke_chunk",
		54,
		0,
		PackedVector3Array([Vector3.ZERO, Vector3(INF, 0, 0)])
	)
	await _wait_frames(8)
	_check(server_manager.get_stroke_count() == baseline_count, "Server should reject Infinity points")

	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 55, metadata, 2, 1)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_receive_stroke_chunk",
		55,
		0,
		PackedVector3Array([Vector3.ZERO, Vector3(101.0, 0, 0)])
	)
	await _wait_frames(8)
	_check(server_manager.get_stroke_count() == baseline_count, "Server should reject out-of-bounds shared coordinates")

	var invalid_width_metadata := metadata.duplicate(true)
	invalid_width_metadata["width_m"] = 0.2
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_begin_stroke_submission",
		56,
		invalid_width_metadata,
		2,
		1
	)
	await _wait_frames(8)
	_check(server_manager.get_stroke_count() == baseline_count, "Server should reject an invalid metric width")

	var forged_creator_metadata := metadata.duplicate(true)
	forged_creator_metadata["creator_peer_id"] = sky_id
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_begin_stroke_submission",
		57,
		forged_creator_metadata,
		2,
		1
	)
	await _wait_frames(8)
	_check(server_manager.get_stroke_count() == baseline_count, "Client must not inject a creator peer id")

	var out_of_order_points := _make_points(129, Vector3(3, 0, 0))
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 58, metadata, 129, 2)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_receive_stroke_chunk",
		58,
		1,
		out_of_order_points.slice(128, 129)
	)
	ground_manager.rpc_id(
		SERVER_PEER_ID,
		"_server_receive_stroke_chunk",
		58,
		0,
		out_of_order_points.slice(0, 128)
	)
	ground_manager.rpc_id(SERVER_PEER_ID, "_server_finish_stroke_submission", 58)
	_check(await _wait_for_count(server_manager, baseline_count + 1), "complete out-of-order chunks should assemble by index")
	baseline_count += 1
	baseline_revision = int(server_manager.get_state_revision())

	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 59, metadata, 2, 1)
	await _wait_frames(4)
	var timeout_key := "%d:%d" % [ground_id, 59]
	var pending_submissions := server_manager.get("_server_pending_submissions") as Dictionary
	if pending_submissions.has(timeout_key):
		var timed_out := pending_submissions[timeout_key] as Dictionary
		timed_out["created_msec"] = Time.get_ticks_msec() - 10001
		pending_submissions[timeout_key] = timed_out
		server_manager.set("_server_pending_submissions", pending_submissions)
		server_manager.set("_last_cleanup_msec", Time.get_ticks_msec() - 1001)
		server_manager.call("_process", 0.0)
	await _wait_frames(4)
	pending_submissions = server_manager.get("_server_pending_submissions") as Dictionary
	_check(not pending_submissions.has(timeout_key), "timed-out partial upload should be discarded")
	_check(server_manager.get_stroke_count() == baseline_count, "timed-out upload must not half-publish")

	var legal_after_invalid := _make_draft(402, 8, Vector3(4, 0, 0), Color.CYAN)
	ground_manager.set("_next_client_operation_sequence", 60)
	ground_manager.submit_drafts([legal_after_invalid])
	_check(await _wait_for_count(server_manager, baseline_count + 1), "Server should accept a legal request after malformed uploads")
	_check(await _wait_for_count(sky_manager, baseline_count + 1), "legal post-error stroke should still broadcast")
	baseline_count += 1
	baseline_revision = int(server_manager.get_state_revision())

	ground_manager.rpc_id(SERVER_PEER_ID, "_server_begin_stroke_submission", 60, metadata, 2, 1)
	await _wait_frames(8)
	_check(server_manager.get_stroke_count() == baseline_count, "replayed request sequence must not publish")
	_check(int(server_manager.get_state_revision()) == baseline_revision, "request replay must not advance revision")

	var longest_legal := _make_draft(403, 2048, Vector3(5, 0, 0), Color.ORANGE)
	ground_manager.set("_next_client_operation_sequence", 61)
	ground_manager.submit_drafts([longest_legal])
	_check(await _wait_for_count(server_manager, baseline_count + 1), "2048-point boundary stroke should be accepted")
	_check(await _wait_for_count(sky_manager, baseline_count + 1), "2048-point stroke should broadcast intact")
	baseline_count += 1

	var sky_count_before_stale := int(sky_manager.get_stroke_count())
	server_manager.rpc_id(
		reconnect_id,
		"_rpc_clear_strokes",
		int(sky_manager.get_state_revision())
	)
	await _wait_frames(8)
	_check(sky_manager.get_stroke_count() == sky_count_before_stale, "stale revision must not clear client state")

	# Server shutdown must clear stale authoritative state on both clients.
	server_peer.close()
	_check(await _wait_for_count(ground_manager, 0), "Ground VR should clear strokes after Server disconnect")
	_check(await _wait_for_count(sky_manager, 0), "Sky should clear strokes after Server disconnect")
	_check(int(ground_manager.get_state_revision()) == 0, "Ground VR revision should reset after Server disconnect")
	_check(int(sky_manager.get_state_revision()) == 0, "Sky revision should reset after Server disconnect")

	# Validate the collection cap without flooding the real ENet peers with
	# hundreds of records; the network path above already exercises the same
	# authoritative creation function and chunk transport.
	var limit_branch := Node3D.new()
	limit_branch.name = "LimitBranch"
	root.add_child(limit_branch)
	var limit_manager = _add_drawing_manager(limit_branch)
	await process_frame
	while limit_manager.get_stroke_count() < 256:
		var fill_index := int(limit_manager.get_stroke_count())
		var fill_result := int(limit_manager.call(
			"_create_stroke_authoritative",
			_make_draft(1000 + fill_index, 2, Vector3(0, float(fill_index) * 0.01, 0), Color.GRAY),
			ground_id
		))
		if fill_result <= 0:
			break
	_check(limit_manager.get_stroke_count() == 256, "Server should accept the 256th session stroke")
	var overflow_result := int(limit_manager.call(
		"_create_stroke_authoritative",
		_make_draft(9999, 2, Vector3(0, 9, 0), Color.WHITE),
		ground_id
	))
	_check(overflow_result < 0, "Server should reject the 257th session stroke")
	_check(limit_manager.get_stroke_count() == 256, "257th stroke rejection must preserve the bounded collection")
	limit_branch.queue_free()

	await _finish()


func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43360, 43390):
		if peer.create_server(port, 3, 3) == OK:
			_peers.append(peer)
			return port
	_check(false, "loopback ENet Server should bind an available port")
	return 0


func _create_branch(branch_name: String, api: SceneMultiplayer) -> Node3D:
	var branch := Node3D.new()
	branch.name = branch_name
	root.add_child(branch)
	set_multiplayer(api, branch.get_path())
	var branch_peer := api.multiplayer_peer as ENetMultiplayerPeer
	if branch_peer != null and not _peers.has(branch_peer):
		_peers.append(branch_peer)
	return branch


func _add_peer_authority(branch: Node3D, local_role: String) -> MockPeerAuthority:
	var authority := MockPeerAuthority.new()
	authority.name = "PeerAuthority"
	authority.local_role = local_role
	branch.add_child(authority)
	return authority


func _add_drawing_manager(branch: Node3D) -> Node:
	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	branch.add_child(shared_origin)
	var system := Node3D.new()
	system.name = "SpatialDrawingSystem"
	shared_origin.add_child(system)
	var renderer = RendererScript.new()
	renderer.name = "SpatialDrawingRenderer"
	system.add_child(renderer)
	var manager = ManagerScript.new()
	manager.name = "SpatialDrawingManager"
	manager.shared_space_origin_path = NodePath("../..")
	manager.renderer_path = NodePath("../SpatialDrawingRenderer")
	manager.peer_authority_path = NodePath("../../../PeerAuthority")
	manager.warn_on_rejection = false
	system.add_child(manager)
	return manager


func _make_draft(
	local_id: int,
	point_count: int,
	offset: Vector3,
	color: Color
) -> Dictionary:
	return {
		"local_id": local_id,
		"points": _make_points(point_count, offset),
		"color": color,
		"width_m": 0.01,
		"completed": true,
	}


func _make_points(point_count: int, offset: Vector3) -> PackedVector3Array:
	var points := PackedVector3Array()
	for index in range(point_count):
		points.append(offset + Vector3(float(index) * 0.002, sin(float(index) * 0.05) * 0.01, 0.0))
	return points


func _find_stroke_by_local_shape(manager: Node, point_count: int, color: Color) -> int:
	for stroke_value in manager.call("get_strokes"):
		var stroke := stroke_value as Dictionary
		var points := stroke.get("points", PackedVector3Array()) as PackedVector3Array
		if points.size() == point_count and (stroke.get("color", Color.BLACK) as Color).is_equal_approx(color):
			return int(stroke.get("stroke_id", 0))
	return -1


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
		if int(manager.call("get_stroke_count")) == expected:
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
	RuntimeProfile.clear_session_override()
	if _failures.is_empty():
		print("SPATIAL_DRAWING_NETWORK_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("SPATIAL_DRAWING_NETWORK_SELF_TEST: %s" % failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
