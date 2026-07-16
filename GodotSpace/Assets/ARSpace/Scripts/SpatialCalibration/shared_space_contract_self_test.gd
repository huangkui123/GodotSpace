extends SceneTree

const Contract = preload("res://Assets/ARSpace/Scripts/SpatialCalibration/shared_space_contract.gd")
const CalibrationStateScript = preload("res://Assets/ARSpace/Scripts/SpatialCalibration/spatial_calibration_state.gd")
const ReplicaScript = preload("res://Assets/ARSpace/Scripts/SpatialCalibration/spatial_calibration_replica.gd")

var _failures: Array[String] = []
var _server_peer: ENetMultiplayerPeer


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_coordinate_contract()
	await _test_authoritative_state_and_replica()
	if _server_peer != null:
		_server_peer.close()
	if _failures.is_empty():
		print("Shared-space contract self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_coordinate_contract() -> void:
	var origin := Transform3D(Basis(Vector3.UP, 0.63), Vector3(2.0, 0.5, -3.0))
	var shared_point := Vector3(1.25, 1.6, -0.75)
	var world_point: Vector3 = Contract.shared_to_world_point(origin, shared_point)
	_expect(
		Contract.world_to_shared_point(origin, world_point).is_equal_approx(shared_point),
		"Point conversion must round-trip through the absolute SharedSpaceOrigin."
	)
	var shared_transform := Transform3D(Basis(Vector3.RIGHT, -0.2), shared_point)
	var round_trip: Transform3D = Contract.world_to_shared_transform(
		origin,
		Contract.shared_to_world_transform(origin, shared_transform)
	)
	_expect(round_trip.is_equal_approx(shared_transform), "Transform conversion must round-trip.")
	var shared_normal := Vector3(0.2, 0.9, -0.3).normalized()
	var world_normal: Vector3 = Contract.shared_to_world_normal(origin, shared_normal)
	_expect(
		Contract.world_to_shared_normal(origin, world_normal).is_equal_approx(shared_normal),
		"Normal conversion must use the inverse-transpose contract."
	)
	_expect(Contract.is_valid_origin_transform(origin), "A rigid finite origin must be valid.")
	_expect(
		not Contract.is_valid_origin_transform(Transform3D(Basis.from_scale(Vector3(2.0, 1.0, 1.0)), Vector3.ZERO)),
		"Scaled origins must be rejected so meters remain consistent."
	)
	_expect(not Contract.is_valid_shared_point(Vector3(51.0, 0.0, 0.0)), "Out-of-range shared points must be rejected.")


func _test_authoritative_state_and_replica() -> void:
	_server_peer = ENetMultiplayerPeer.new()
	var port := _start_server()
	if port == 0:
		return
	var api := SceneMultiplayer.new()
	api.multiplayer_peer = _server_peer
	var branch := Node3D.new()
	branch.name = "CalibrationUnitBranch"
	root.add_child(branch)
	set_multiplayer(api, branch.get_path())
	var origin := Node3D.new()
	origin.name = "SharedSpaceOrigin"
	origin.add_to_group("shared_space_origin")
	branch.add_child(origin)
	var state: Node = CalibrationStateScript.new()
	state.name = "SpatialCalibrationState"
	state.set("shared_space_origin_path", NodePath("../SharedSpaceOrigin"))
	branch.add_child(state)
	var replica: Node = ReplicaScript.new()
	replica.name = "SpatialCalibrationReplica"
	replica.set("state_service_path", NodePath("../SpatialCalibrationState"))
	replica.set("shared_space_origin_path", NodePath("../SharedSpaceOrigin"))
	branch.add_child(replica)
	await process_frame

	var first_origin := Transform3D(Basis(Vector3.UP, 0.25), Vector3(1.0, 0.0, 2.0))
	var second_origin := Transform3D(Basis(Vector3.UP, -0.4), Vector3(-2.0, 0.2, 1.0))
	_expect(
		bool(state.call("commit_calibration", first_origin, {"rms_error_m": 0.02}, "unit_test")),
		"Server must accept a valid calibration commit."
	)
	_expect(
		bool(state.call("commit_calibration", second_origin, {"rms_error_m": 0.01}, "unit_test")),
		"Server must accept a replacement calibration commit."
	)
	var committed: Dictionary = state.call("get_state")
	_expect(
		(committed["origin_global"] as Transform3D).is_equal_approx(second_origin),
		"Calibration commit must replace the absolute origin instead of accumulating a delta."
	)
	_expect(origin.global_transform.is_equal_approx(second_origin), "Committed origin must be applied to the scene.")
	_expect(bool(state.call("set_preview", Vector3(0.2, 1.0, -0.4), {"depth_m": 1.2})), "Valid preview must be accepted.")
	_expect(bool(state.call("confirm_point", Vector3(0.2, 1.0, -0.4), {"depth_m": 1.2})), "Valid confirmed point must be accepted.")
	await process_frame
	committed = state.call("get_state")
	_expect((committed["confirmed_points"] as Array).size() == 1, "One confirmed point must be stored.")
	_expect((state.call("get_preview") as Dictionary).is_empty(), "Confirming a point must clear its preview.")
	var marker_root := replica.call("get_marker_root") as Node3D
	_expect(marker_root != null and marker_root.get_child_count() == 1, "Replica must rebuild one shared-local confirmed marker.")
	if marker_root != null and marker_root.get_child_count() == 1:
		_expect(
			(marker_root.get_child(0) as Node3D).position.is_equal_approx(Vector3(0.2, 1.0, -0.4)),
			"Replica marker position must remain shared-local under SharedSpaceOrigin."
		)
	var oversized := "x".repeat(5000)
	_expect(
		not bool(state.call("set_preview", Vector3.ZERO, {"payload": oversized})),
		"Oversized metadata must be rejected before replication."
	)
	_expect(bool(state.call("begin_recalibration", "unit_retry")), "Server must enter recalibration state.")
	committed = state.call("get_state")
	_expect(str(committed["status"]) == "calibrating", "Recalibration must expose an explicit state.")
	_expect((committed["confirmed_points"] as Array).is_empty(), "Recalibration must remove stale confirmed points.")
	_expect(bool(state.call("clear_calibration", "unit_clear")), "Server must clear calibration state.")
	committed = state.call("get_state")
	_expect(str(committed["status"]) == "uncalibrated", "Clear must restore the uncalibrated state.")
	_expect((committed["origin_global"] as Transform3D).is_equal_approx(Transform3D.IDENTITY), "Clear must restore identity origin.")
	_expect(origin.global_transform.is_equal_approx(Transform3D.IDENTITY), "Clear must apply identity to SharedSpaceOrigin.")
	branch.queue_free()
	await process_frame
	await process_frame


func _start_server() -> int:
	for port in range(43520, 43540):
		if _server_peer.create_server(port, 1, 3) == OK:
			return port
	_expect(false, "Shared-space unit test should bind a loopback port.")
	return 0


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
