extends SceneTree

const Model := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/pico_camera_model.gd")
const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var metadata := fixture()
	var result := Model.head_from_camera(metadata)
	_expect(result.has("transform"), "device camera model accepted")
	if result.has("transform"):
		var camera: Transform3D = result.transform
		_expect(camera.origin.distance_to(Vector3(-0.032381516, -0.002039754, -0.069120892)) < 0.000001,
			"left optical center matches official SDK conversion, in head-local metres")
		_expect((-camera.basis.z).distance_to(Vector3(-0.003704133, -0.007621656, -0.999964094)) < 0.000001,
			"optical forward remains forward after exactly one camera basis conversion")
		_test_world_solution(camera)
	metadata.render_mode = 1
	metadata.selected_camera_index = 1
	result = Model.head_from_camera(metadata)
	_expect(result.has("transform") and result.transform.origin.x > 0.03, "right frame selects right camera")
	for mutation in [
		{"device_model": "unknown"}, {"camera_to_head_convention": ""},
		{"camera_extrinsics_status": 0}, {"camera_to_head_status": "sdk_read_failed"},
		{"camera_to_head_units": "mm"}, {"output_camera_raw_data": true},
		{"render_mode": 2}, {"selected_camera_index": 1},
		{"render_mode": 0.1}, {"render_mode": "0"}, {"selected_camera_index": null},
		{"camera_to_head_primary": []},
	]:
		var invalid := fixture()
		invalid.merge(mutation, true)
		_expect(Model.head_from_camera(invalid).has("error"), "invalid model rejected: " + str(mutation))
	for index in [0, 3, 12, 15]:
		var invalid := fixture()
		invalid.camera_to_head_primary[index] = NAN if index == 0 else 40.0
		_expect(Model.head_from_camera(invalid).has("error"), "malformed rigid matrix rejected")
	_expect(Model.intrinsics_error(fixture()).is_empty(), "corrected image FOV accepted")
	var round_trip: Dictionary = JSON.parse_string(JSON.stringify(fixture()))
	_expect(Model.head_from_camera(round_trip).has("transform"), "JSON float camera indices accepted")
	var old := fixture()
	old.camera_intrinsics_horizontal_fov_degrees = 90.0
	_expect(not Model.intrinsics_error(old).is_empty(), "old 90 degree image intrinsics rejected")
	old = fixture()
	old.camera_intrinsics_status = 0
	_expect(not Model.intrinsics_error(old).is_empty(), "failed intrinsics cannot reuse stale values")
	# A real-device diagnostic may supply the production Helper JSON, without images.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--metadata="):
			var path := argument.trim_prefix("--metadata=")
			var live: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			_expect(live is Dictionary, "device diagnostic JSON decoded")
			if live is Dictionary:
				_expect(Model.head_from_camera(live).has("transform"), "production Helper metadata accepted")
				_expect(Model.intrinsics_error(live).is_empty(), "production Helper image parameters accepted")
	if failures.is_empty():
		print("PICO camera model self-test passed (axes, origin, stereo, image mode, world composition, invalid metadata).")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _test_world_solution(camera: Transform3D) -> void:
	var head := Transform3D(Basis.from_euler(Vector3(0.07, 0.6, -0.03)), Vector3(2, 1.65, -1))
	var world_from_camera := head * camera
	var camera_from_cabinet := Transform3D(Basis(Vector3.UP, 0.2), Vector3(-0.6, -1.0, -3.4))
	var expected_world := world_from_camera * camera_from_cabinet
	var size := Vector3(1.2, 2, 0.6)
	var k := Vector4(610, 610, 480, 360)
	var pixels := PackedVector2Array()
	for point in Geometry.corners(size).slice(0, 4):
		pixels.append(Geometry.project(camera_from_cabinet, point, k))
	var solved := Geometry.solve(pixels, size, k, Vector2i(960, 720))
	_expect(solved.has("transform"), "four-corner pose solved")
	if solved.has("transform"):
		var actual_world: Transform3D = head * camera * (solved.transform as Transform3D)
		_expect(actual_world.origin.distance_to(expected_world.origin) < 0.001, "rotated head composes in correct order")
		_expect(actual_world.basis.is_equal_approx(expected_world.basis), "cabinet orientation preserved")
		var approximate_world: Transform3D = head * (solved.transform as Transform3D)
		_expect(approximate_world.origin.distance_to(expected_world.origin) > 0.03,
			"regression distinguishes old head-only approximation")


static func fixture() -> Dictionary:
	var left := [0.9999930663280631, -0.0003830075619801477, -0.0037041329628563916, -0.0323815156686094,
		-0.00041123088404245985, -0.999970870199322, -0.007621656117359568, -0.002039754377173925,
		-0.0037011059102737363, 0.007623126525169355, -0.9999640942338996, -0.06912089177633773,
		0.0, 0.0, 0.0, 1.0]
	var right := left.duplicate()
	right[3] = 0.0318042644701764
	right[7] = -0.00206614973530011
	right[11] = -0.06935845179372815
	return {"device_model": "A9410", "camera_to_head_convention": Model.CONVENTION,
		"camera_to_head_status": "valid", "camera_extrinsics_status": 1, "camera_to_head_units": "metres",
		"output_camera_raw_data": false, "render_mode": 0, "selected_camera_index": 0,
		"camera_to_head_primary": left, "camera_to_head_secondary": right,
		"camera_intrinsics_status": 1, "camera_intrinsics_source": "pico_4_ultra_rectified_sdk_fov",
		"camera_intrinsics_horizontal_fov_degrees": 76.35, "camera_intrinsics_vertical_fov_degrees": 61.05}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
