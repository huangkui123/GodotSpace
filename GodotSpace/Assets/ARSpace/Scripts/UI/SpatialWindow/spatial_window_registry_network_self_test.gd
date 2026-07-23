extends SceneTree

const RegistryScript = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_registry.gd")
const State = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_state.gd")

const CONNECT_TIMEOUT_FRAMES: int = 300
const STATE_TIMEOUT_FRAMES: int = 300

class FakeAuthority:
	extends Node

	signal peer_role_changed(peer_id: int, role: String)
	signal network_role_selected(is_server_role: bool)
	signal session_closed()

	var roles: Dictionary = {}

	func get_peer_role(peer_id: int) -> String:
		return str(roles.get(peer_id, ""))


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
	var server_context := _create_branch("WindowServer", server_peer)
	var server_registry := server_context["registry"] as Node
	var server_authority := server_context["authority"] as FakeAuthority
	var descriptor := {
		"window_type": "work_list",
		"instance_policy": State.POLICY_UNIQUE,
		"content_key": "task-1",
		"shared_transform": Transform3D(Basis.IDENTITY, Vector3(0.0, 1.2, -1.5)),
		"size_m": Vector2(1.0, 0.65),
	}
	_expect(bool(server_registry.call("register_window", descriptor)), "Server should register the initial unique window.")
	_expect(int(server_registry.call("get_revision")) == 1, "Initial registration should advance the revision.")
	var window_id := _find_window_id(server_registry, "work_list")
	_expect(not window_id.is_empty(), "The Server should allocate a stable unique window ID.")

	var ground_peer := ENetMultiplayerPeer.new()
	_expect(ground_peer.create_client("127.0.0.1", port, 4, 3) == OK, "Ground VR client should start connecting.")
	var ground_context := _create_branch("WindowGroundClient", ground_peer)
	var ground_registry := ground_context["registry"] as Node
	var ground_authority := ground_context["authority"] as FakeAuthority
	_expect(await _wait_for_connection(ground_peer), "Ground VR client should connect through real ENet.")
	var ground_peer_id := ground_peer.get_unique_id()
	server_authority.roles[ground_peer_id] = State.ROLE_GROUND_VR
	ground_authority.roles[ground_peer_id] = State.ROLE_GROUND_VR
	_expect(await _wait_for_revision(ground_registry, 1), "Late Ground VR should receive the reliable full snapshot.")
	_expect(not (ground_registry.call("get_window_state", window_id) as Dictionary).is_empty(), "Late snapshot should contain the open window.")
	var unregistered_open_result := {"received": false, "accepted": true}
	ground_registry.connect("operation_completed", func(result: Dictionary) -> void:
		if str(result.get("operation", "")) == "open" and str(result.get("window_id", "")) != window_id:
			unregistered_open_result["received"] = true
			unregistered_open_result["accepted"] = bool(result.get("accepted", true))
	)
	var unregistered_descriptor := descriptor.duplicate(true)
	unregistered_descriptor["window_type"] = "unregistered_remote_type"
	_expect(bool(ground_registry.call("request_operation", "", "open", unregistered_descriptor)), "Ground VR may submit an open request for Server validation.")
	_expect(await _wait_for_flag(unregistered_open_result, "received"), "Ground VR should receive the unregistered open result.")
	_expect(not bool(unregistered_open_result["accepted"]), "Only Server-registered window identities may be opened remotely.")
	_expect((server_registry.call("get_windows_snapshot") as Dictionary).size() == 1, "Rejected remote creation must not consume the bounded window catalog.")

	var invalid_timeout_result := {"received": false, "accepted": true}
	ground_registry.connect("operation_completed", func(result: Dictionary) -> void:
		if str(result.get("operation", "")) == "acquire_lease" and str(result.get("error", "")) == "invalid_lease_timeout":
			invalid_timeout_result["received"] = true
			invalid_timeout_result["accepted"] = bool(result.get("accepted", true))
	)
	_expect(bool(ground_registry.call("request_operation", window_id, "acquire_lease", {"timeout_msec": 2000.0})), "Non-integer lease timeout may be queued for strict Server validation.")
	_expect(await _wait_for_flag(invalid_timeout_result, "received"), "Ground VR should receive the invalid lease timeout result.")
	_expect(not bool(invalid_timeout_result["accepted"]) and int(server_registry.call("get_revision")) == 1, "Lease timeout must be a strict integer and rejection must not mutate state.")

	_expect(
		bool(ground_registry.call("request_operation", window_id, "acquire_lease", {"timeout_msec": 10000})),
		"Ground VR should submit a manipulation lease request."
	)
	_expect(await _wait_for_revision(server_registry, 2), "Server should grant Ground VR a bounded lease.")
	_expect(await _wait_for_revision(ground_registry, 2), "Lease state should replicate reliably.")
	var leased_state := ground_registry.call("get_window_state", window_id) as Dictionary
	var lease_token := str(leased_state.get("lease_token", ""))
	_expect(int(leased_state.get("lease_peer_id", 0)) == ground_peer_id, "Lease ownership should identify the Ground VR peer.")
	_expect(not lease_token.is_empty(), "Granted lease should include an opaque token.")
	_expect(not bool(server_registry.call("request_operation", window_id, "close", {})), "PC Server must not close a window while another peer owns its manipulation lease.")
	_expect(not bool(server_registry.call("register_window", descriptor)), "Reopening must not replace a window while another peer owns its manipulation lease.")
	_expect(int(server_registry.call("get_revision")) == 2, "Rejected cross-peer operations must not advance durable state.")

	var preview_counter := {"count": 0}
	var ground_preview_counter := {"count": 0}
	server_registry.connect("window_preview_changed", func(received_id: String, _transform: Transform3D, _sequence: int) -> void:
		if received_id == window_id:
			preview_counter["count"] = int(preview_counter["count"]) + 1
	)
	ground_registry.connect("window_preview_changed", func(received_id: String, _transform: Transform3D, _sequence: int) -> void:
		if received_id == window_id:
			ground_preview_counter["count"] = int(ground_preview_counter["count"]) + 1
	)
	var preview_transform := Transform3D(Basis(Vector3.UP, 0.2), Vector3(0.4, 1.1, -1.4))
	var preview_queued := false
	for sequence in range(1, 21):
		preview_queued = bool(ground_registry.call("request_operation", window_id, "transform_preview", {
			"shared_transform": preview_transform,
			"stream_sequence": sequence,
			"lease_token": lease_token,
		})) or preview_queued
		if await _wait_for_counters(preview_counter, 1, ground_preview_counter, 1, 15):
			break
	_expect(preview_queued, "Ground VR should send an optional unreliable drag preview.")
	_expect(int(preview_counter["count"]) >= 1, "Server should receive an ordered drag preview despite optional packet loss.")
	_expect(int(ground_preview_counter["count"]) >= 1, "Ground VR should receive a Server-sequenced preview broadcast despite optional packet loss.")
	_expect(int(server_registry.call("get_revision")) == 2, "Preview traffic must not alter durable revision state.")

	var final_transform := Transform3D(Basis(Vector3.UP, -0.35), Vector3(0.6, 1.0, -1.2))
	_expect(
		bool(ground_registry.call("request_operation", window_id, "transform_commit", {
			"shared_transform": final_transform,
			"size_m": Vector2(1.1, 0.7),
			"lease_token": lease_token,
			"release_lease": true,
		})),
		"Ground VR should send a reliable final transform."
	)
	_expect(await _wait_for_revision(server_registry, 3), "Reliable transform commit should advance Server state.")
	_expect(await _wait_for_revision(ground_registry, 3), "Ground VR should receive its reliable final state.")
	_expect(
		(server_registry.call("get_window_state", window_id) as Dictionary).get("shared_transform") == final_transform,
		"Server should store the final shared-local transform."
	)
	_expect(
		(server_registry.call("get_window_state", window_id) as Dictionary).get("size_m") == Vector2(1.1, 0.7),
		"Server should atomically store the final physical size with the transform."
	)
	_expect(bool(server_registry.call("request_operation", window_id, "acquire_lease", {"timeout_msec": 10000})), "PC Server should acquire the released window next.")
	_expect(await _wait_for_revision(ground_registry, 4), "PC Server lease should replicate to Ground VR.")
	var server_lease_token := str((server_registry.call("get_window_state", window_id) as Dictionary).get("lease_token", ""))
	var server_preview_accepted := false
	for sequence in range(1, 21):
		server_preview_accepted = bool(server_registry.call("request_operation", window_id, "transform_preview", {
			"shared_transform": Transform3D(Basis.IDENTITY, Vector3(0.7, 1.0, -1.1)),
			"stream_sequence": sequence,
			"lease_token": server_lease_token,
		})) or server_preview_accepted
		if await _wait_for_counter(ground_preview_counter, 2, 15):
			break
	_expect(server_preview_accepted, "A new lease owner should be allowed to restart its peer-local preview sequence at one.")
	_expect(int(ground_preview_counter["count"]) >= 2, "Clients must receive previews across lease-owner changes through a Server-global sequence.")
	_expect(bool(server_registry.call("request_operation", window_id, "release_lease", {"lease_token": server_lease_token})), "PC Server should release its preview lease.")
	_expect(await _wait_for_revision(ground_registry, 5), "PC Server lease release should replicate reliably.")

	var astronaut_peer := ENetMultiplayerPeer.new()
	_expect(astronaut_peer.create_client("127.0.0.1", port, 4, 3) == OK, "Astronaut client should start connecting.")
	var astronaut_context := _create_branch("WindowAstronautClient", astronaut_peer)
	var astronaut_registry := astronaut_context["registry"] as Node
	var astronaut_authority := astronaut_context["authority"] as FakeAuthority
	_expect(await _wait_for_connection(astronaut_peer), "Astronaut client should connect through real ENet.")
	var astronaut_peer_id := astronaut_peer.get_unique_id()
	server_authority.roles[astronaut_peer_id] = State.ROLE_ASTRONAUT
	astronaut_authority.roles[astronaut_peer_id] = State.ROLE_ASTRONAUT
	_expect(await _wait_for_revision(astronaut_registry, 5), "Late Astronaut should receive the reliable final transform snapshot.")
	_expect(
		(astronaut_registry.call("get_window_state", window_id) as Dictionary).get("shared_transform") == final_transform,
		"Late snapshot must not depend on missed drag previews."
	)
	_expect(bool(astronaut_registry.call("select_window", window_id)), "Astronaut should be allowed to select a window locally.")
	var astronaut_result := {"received": false, "accepted": true}
	astronaut_registry.connect("operation_completed", func(result: Dictionary) -> void:
		if str(result.get("operation", "")) == "focus":
			astronaut_result["received"] = true
			astronaut_result["accepted"] = bool(result.get("accepted", true))
	)
	_expect(
		bool(astronaut_registry.call("request_operation", window_id, "focus", {})),
		"Astronaut should queue an allowlisted UI focus operation for Server validation."
	)
	_expect(await _wait_for_flag(astronaut_result, "received"), "Astronaut should receive an authoritative operation result.")
	_expect(bool(astronaut_result["accepted"]), "Astronaut ray interaction should be allowed to focus a shared window.")
	_expect(await _wait_for_revision(server_registry, 6), "Accepted Astronaut focus should advance authoritative state.")

	_expect(
		bool(ground_registry.call("request_operation", window_id, "acquire_lease", {"timeout_msec": 500})),
		"Ground VR should acquire the minimum lease duration."
	)
	_expect(await _wait_for_revision(server_registry, 7), "Second lease grant should advance state.")
	await create_timer(0.7).timeout
	_expect(await _wait_for_revision(server_registry, 8), "Expired lease should be cleared by Server authority.")
	_expect(
		int((server_registry.call("get_window_state", window_id) as Dictionary).get("lease_peer_id", -1)) == 0,
		"Lease timeout must release ownership."
	)

	_expect(bool(ground_registry.call("request_operation", window_id, "acquire_lease", {"timeout_msec": 2000})), "Ground VR should reacquire the window.")
	_expect(await _wait_for_revision(ground_registry, 9), "Reacquired lease should replicate.")
	lease_token = str((ground_registry.call("get_window_state", window_id) as Dictionary).get("lease_token", ""))
	var snap_transform := Transform3D(Basis.IDENTITY, Vector3(-0.8, 1.0, -1.0))
	_expect(
		bool(ground_registry.call("request_operation", window_id, "snap", {
			"snap_slot": "left_primary",
			"shared_transform": snap_transform,
			"size_m": Vector2(1.25, 0.75),
			"lease_token": lease_token,
		})),
		"Ground VR should submit a final snap operation."
	)
	_expect(await _wait_for_revision(astronaut_registry, 10), "Snap should replicate reliably to Astronaut.")
	_expect(
		str((astronaut_registry.call("get_window_state", window_id) as Dictionary).get("mode", "")) == State.MODE_SNAPPED,
		"Replicated window should enter SNAPPED mode."
	)
	_expect(
		(astronaut_registry.call("get_window_state", window_id) as Dictionary).get("size_m", Vector2.ZERO) == Vector2(1.25, 0.75),
		"Snap must replicate its authoritative physical dimensions with the transform."
	)
	_expect(bool(ground_registry.call("request_operation", window_id, "close", {})), "Ground VR should close the window.")
	_expect(await _wait_for_revision(astronaut_registry, 11), "Close state should replicate reliably.")
	var closed_state := astronaut_registry.call("get_window_state", window_id) as Dictionary
	_expect(str(closed_state.get("mode", "")) == State.MODE_CLOSED, "Close should leave a stable CLOSED tombstone.")
	_expect(not bool(closed_state.get("visible", true)), "Closed window content and presentation must be hidden together.")

	_expect(
		bool(ground_registry.call("request_operation", "", "open", descriptor)),
		"Opening the same unique descriptor should reopen the stable ID."
	)
	_expect(await _wait_for_revision(server_registry, 12), "Unique reopen should update, not duplicate, state.")
	_expect((server_registry.call("get_windows_snapshot") as Dictionary).size() == 1, "Unique reopen must not create a duplicate window.")
	_expect(str((server_registry.call("get_window_state", window_id) as Dictionary).get("mode", "")) == State.MODE_NORMAL, "Unique reopen should restore NORMAL mode.")
	_expect(
		bool(ground_registry.call("request_operation", window_id, "set_mode", {
			"mode": State.MODE_MAXIMIZED,
			"size_m": Vector2(1.6, 0.9),
		})),
		"Ground VR should request a bounded maximized mode and size together."
	)
	_expect(await _wait_for_revision(astronaut_registry, 13), "Maximized mode should replicate reliably.")
	var maximized_state := astronaut_registry.call("get_window_state", window_id) as Dictionary
	_expect(str(maximized_state.get("mode", "")) == State.MODE_MAXIMIZED, "Replicated window should enter MAXIMIZED mode.")
	_expect(maximized_state.get("size_m", Vector2.ZERO) == Vector2(1.6, 0.9), "MAXIMIZED mode must carry the authoritative dimensions instead of a local scale factor.")

	var multiple_descriptor := descriptor.duplicate(true)
	multiple_descriptor["window_type"] = "image"
	multiple_descriptor["content_key"] = "earth"
	multiple_descriptor["instance_policy"] = State.POLICY_MULTIPLE
	_expect(bool(server_registry.call("register_window", multiple_descriptor)), "Server should open the first multiple-instance window.")
	_expect(bool(server_registry.call("register_window", multiple_descriptor)), "Server should open the second multiple-instance window.")
	_expect((server_registry.call("get_windows_snapshot") as Dictionary).size() == 3, "Multiple policy should create distinct stable records.")
	var image_ids := _find_window_ids(server_registry, "image")
	_expect(image_ids.size() == 2 and image_ids[0] != image_ids[1], "Multiple windows should have distinct authoritative IDs.")

	_expect(bool(server_registry.call("unregister_window", window_id)), "Server unregister should hard-delete the paired window state.")
	_expect(await _wait_for_missing_window(ground_registry, window_id), "Ground VR should remove presentation/state after unregister.")
	_expect(await _wait_for_missing_window(astronaut_registry, window_id), "Astronaut should remove presentation/state after unregister.")

	var leased_image_id := image_ids[0]
	_expect(bool(ground_registry.call("request_operation", leased_image_id, "acquire_lease", {"timeout_msec": 2000})), "Ground VR should lease a remaining window.")
	var lease_revision := int(server_registry.call("get_revision")) + 1
	_expect(await _wait_for_revision(server_registry, lease_revision), "Remaining window lease should reach Server.")
	ground_peer.close()
	_expect(await _wait_for_lease_peer(server_registry, leased_image_id, 0), "Ground disconnect should release every owned lease.")

	server_peer.close()
	_expect(await _wait_for_revision(astronaut_registry, 0), "Server shutdown should clear client window replicas.")
	_finish()


func _start_loopback_server(peer: ENetMultiplayerPeer) -> int:
	for port in range(43620, 43640):
		if peer.create_server(port, 4, 3) == OK:
			return port
	_expect(false, "Spatial window network self-test should bind a loopback port.")
	return 0


func _create_branch(branch_name: String, peer: ENetMultiplayerPeer) -> Dictionary:
	var api := SceneMultiplayer.new()
	api.multiplayer_peer = peer
	var branch := Node.new()
	branch.name = branch_name
	root.add_child(branch)
	set_multiplayer(api, branch.get_path())
	_peers.append(peer)
	var authority := FakeAuthority.new()
	authority.name = "Authority"
	branch.add_child(authority)
	var registry: Node = RegistryScript.new()
	registry.name = "SpatialWindowRegistryService"
	registry.set("peer_authority_path", NodePath("../Authority"))
	branch.add_child(registry)
	return {"branch": branch, "authority": authority, "registry": registry}


func _find_window_id(registry: Node, window_type: String) -> String:
	var ids := _find_window_ids(registry, window_type)
	return ids[0] if not ids.is_empty() else ""


func _find_window_ids(registry: Node, window_type: String) -> Array[String]:
	var ids: Array[String] = []
	var snapshot := registry.call("get_windows_snapshot") as Dictionary
	for window_id in snapshot:
		if str((snapshot[window_id] as Dictionary).get("window_type", "")) == window_type:
			ids.append(str(window_id))
	ids.sort()
	return ids


func _wait_for_connection(peer: ENetMultiplayerPeer) -> bool:
	for _frame in range(CONNECT_TIMEOUT_FRAMES):
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await process_frame
	return false


func _wait_for_revision(registry: Node, expected_revision: int) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if int(registry.call("get_revision")) == expected_revision:
			return true
		await process_frame
	return false


func _wait_for_counter(counter: Dictionary, expected_count: int, frames: int = STATE_TIMEOUT_FRAMES) -> bool:
	for _frame in range(frames):
		if int(counter.get("count", 0)) >= expected_count:
			return true
		await process_frame
	return false


func _wait_for_counters(
	first: Dictionary,
	first_expected: int,
	second: Dictionary,
	second_expected: int,
	frames: int
) -> bool:
	for _frame in range(frames):
		if int(first.get("count", 0)) >= first_expected \
				and int(second.get("count", 0)) >= second_expected:
			return true
		await process_frame
	return false


func _wait_for_flag(container: Dictionary, key: String) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if bool(container.get(key, false)):
			return true
		await process_frame
	return false


func _wait_for_missing_window(registry: Node, window_id: String) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		if (registry.call("get_window_state", window_id) as Dictionary).is_empty():
			return true
		await process_frame
	return false


func _wait_for_lease_peer(registry: Node, window_id: String, expected_peer_id: int) -> bool:
	for _frame in range(STATE_TIMEOUT_FRAMES):
		var record := registry.call("get_window_state", window_id) as Dictionary
		if int(record.get("lease_peer_id", -1)) == expected_peer_id:
			return true
		await process_frame
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	for peer in _peers:
		peer.close()
	if _failures.is_empty():
		print("Spatial window registry network self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
