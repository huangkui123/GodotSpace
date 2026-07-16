extends SceneTree

const State = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_state.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	var descriptor_result := State.normalize_descriptor({
		"window_type": "work_list",
		"instance_policy": State.POLICY_UNIQUE,
		"content_key": "task-1",
		"shared_transform": Transform3D(Basis(Vector3.UP, 0.3), Vector3(1.0, 1.2, -2.0)),
		"size_m": Vector2(1.1, 0.7),
	})
	_expect(bool(descriptor_result.get("ok", false)), "A bounded rigid shared-local descriptor should be accepted.")
	var descriptor := descriptor_result.get("value", {}) as Dictionary
	var unique_id_one := State.make_stable_window_id("work_list", "task-1", State.POLICY_UNIQUE)
	var unique_id_two := State.make_stable_window_id("work_list", "task-1", State.POLICY_UNIQUE)
	_expect(unique_id_one == unique_id_two, "Unique IDs must be stable for the same type and content key.")
	var multi_id_one := State.make_stable_window_id("image", "earth", State.POLICY_MULTIPLE, 1)
	var multi_id_two := State.make_stable_window_id("image", "earth", State.POLICY_MULTIPLE, 2)
	_expect(multi_id_one != multi_id_two, "Multiple-instance IDs must include the authoritative sequence.")
	var maximum_type := "w".repeat(State.MAX_ID_BYTES)
	var maximum_multi_one := State.make_stable_window_id(maximum_type, "", State.POLICY_MULTIPLE, 1)
	var maximum_multi_two := State.make_stable_window_id(maximum_type, "", State.POLICY_MULTIPLE, 2)
	_expect(maximum_multi_one != maximum_multi_two and maximum_multi_one.ends_with("_1") and maximum_multi_two.ends_with("_2"), "Maximum-length window types must reserve bytes for the multiple-instance sequence.")
	var long_unique_one := State.make_stable_window_id(maximum_type, "content-a", State.POLICY_UNIQUE)
	var long_unique_two := State.make_stable_window_id(maximum_type, "content-b", State.POLICY_UNIQUE)
	_expect(long_unique_one != long_unique_two and long_unique_one.length() <= State.MAX_ID_BYTES, "Maximum-length unique types must preserve their content hash without exceeding the ID bound.")

	var record := State.make_record(descriptor, unique_id_one, 1, 1, 1)
	var record_result := State.normalize_record(record)
	_expect(bool(record_result.get("ok", false)), "A complete window record should normalize.")
	var normalized_record := record_result.get("value", {}) as Dictionary
	_expect(str(normalized_record.get("mode", "")) == State.MODE_NORMAL, "New windows should start in NORMAL mode.")
	_expect(int(normalized_record.get("owner_peer_id", 0)) == 1, "Window ownership must remain explicit.")
	_expect(int(normalized_record.get("lease_peer_id", -1)) == 0, "New windows must start without a manipulation lease.")

	var closed := normalized_record.duplicate(true)
	closed["mode"] = State.MODE_CLOSED
	closed["visible"] = false
	_expect(bool(State.normalize_record(closed).get("ok", false)), "CLOSED is a valid hidden tombstone state.")
	closed["visible"] = true
	_expect(not bool(State.normalize_record(closed).get("ok", false)), "CLOSED windows must never remain visible.")

	var snapped := normalized_record.duplicate(true)
	snapped["mode"] = State.MODE_SNAPPED
	snapped["snap_slot"] = "left_primary"
	_expect(bool(State.normalize_record(snapped).get("ok", false)), "SNAPPED requires a stable snap slot.")
	snapped["snap_slot"] = ""
	_expect(not bool(State.normalize_record(snapped).get("ok", false)), "SNAPPED without a slot must be rejected.")

	var leased := normalized_record.duplicate(true)
	leased["lease_peer_id"] = 9
	leased["lease_token"] = "lease_9_window_1"
	leased["lease_expires_msec"] = 5000
	_expect(bool(State.normalize_record(leased).get("ok", false)), "A complete bounded lease should normalize.")
	leased["lease_token"] = ""
	_expect(not bool(State.normalize_record(leased).get("ok", false)), "An active lease requires a token.")

	var scaled_transform := Transform3D(Basis.IDENTITY.scaled(Vector3(2.0, 2.0, 2.0)), Vector3.ZERO)
	_expect(not State.is_valid_shared_transform(scaled_transform), "Window transforms must be rigid and may not smuggle scale.")
	_expect(
		not State.is_valid_shared_transform(Transform3D(Basis.IDENTITY, Vector3(50.01, 0.0, 0.0))),
		"Window transforms must remain inside the 50 metre SharedSpaceOrigin contract."
	)
	_expect(State.is_valid_size(Vector2(0.2, 3.0)), "The inclusive 0.2-3 metre size boundary should be accepted.")
	_expect(not State.is_valid_size(Vector2(0.19, 1.0)), "Sub-0.2 metre windows should be rejected.")
	_expect(not State.is_valid_size(Vector2(1.0, 3.01)), "Over-3 metre windows should be rejected.")

	var snapshot := {unique_id_one: normalized_record}
	_expect(bool(State.normalize_snapshot(snapshot).get("ok", false)), "A keyed authoritative snapshot should normalize.")
	var mismatched_snapshot := {"different_id": normalized_record}
	_expect(not bool(State.normalize_snapshot(mismatched_snapshot).get("ok", false)), "Snapshot keys must match stable window IDs.")

	_expect(State.is_ground_role(State.ROLE_PC_GROUND), "PC Ground must be allowed to mutate window business state.")
	_expect(State.is_ground_role(State.ROLE_GROUND_VR), "Ground VR must be allowed to mutate window business state.")
	_expect(not State.is_ground_role(State.ROLE_ASTRONAUT), "Astronaut must not mutate window business state by default.")
	_expect(State.is_selectable_role(State.ROLE_ASTRONAUT), "Astronaut must retain local selection access.")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("Spatial window state self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
