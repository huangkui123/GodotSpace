extends SceneTree

const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_geometry.gd")
const CaptureWriter := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_capture_writer.gd")
var failures: PackedStringArray = []


func _initialize() -> void:
	var world_from_tracking := Transform3D(
		Basis.from_euler(Vector3(0.1, 0.5, -0.08)), Vector3(2, 0.3, -1)
	)
	var tracking_from_camera := Transform3D(
		Basis.from_euler(Vector3(-0.2, -0.3, 0.05)), Vector3(0.2, 1.5, 0.1)
	)
	var cv_from_model := Transform3D(
		Basis.from_euler(Vector3(0.1, -0.4, 0.2)), Vector3(0.1, 0.2, 1.2)
	)
	var world_from_model := (
		world_from_tracking * tracking_from_camera * Geometry.OPENCV_TO_GODOT * cv_from_model
	)
	var solved := Geometry.solve_world_from_tracking(world_from_model, tracking_from_camera, cv_from_model)
	_expect(solved.has("world_from_tracking"), "valid transform chain should solve")
	if solved.has("world_from_tracking"):
		var result: Transform3D = solved["world_from_tracking"]
		_expect(result.is_equal_approx(world_from_tracking), "OpenCV/Godot direction or inverse is incorrect")
	var scaled := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE / 3.0), Vector3.ZERO)
	_expect(Geometry.solve_world_from_tracking(scaled, tracking_from_camera, cv_from_model).has("error"),
		"miniature scale must not be applied to XR origin")
	_expect(Geometry.from_row_major([[1, 0], [0, 1]]).has("error"), "invalid matrix shape must fail")
	_expect(Geometry.from_row_major([
		[-1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1],
	]).has("error"), "reflections must fail")
	var decoded := Geometry.from_row_major([
		[1, 0, 0, 2], [0, 1, 0, 3], [0, 0, 1, 4], [0, 0, 0, 1],
	])
	_expect(decoded.has("transform") and decoded["transform"].origin == Vector3(2, 3, 4),
		"row-major translation should decode")
	_expect(CaptureWriter.write_capture("user://cabinet_self_test", -1, 0, Vector2i.ZERO, {},
		PackedByteArray()).has("error"), "empty frame must not be saved")
	var image := Image.create(16, 16, false, Image.FORMAT_RGB8)
	image.fill(Color(0.2, 0.5, 0.8))
	var jpeg := image.save_jpg_to_buffer()
	var captured := CaptureWriter.write_capture(
		"user://cabinet_self_test", 42, 1234567890123456, Vector2i(16, 16),
		{"camera_intrinsics_available": false}, jpeg
	)
	_expect(captured.has("path"), "valid original frame should be saved")
	if captured.has("path"):
		var directory: String = captured["path"]
		_expect(FileAccess.get_file_as_bytes(directory.path_join("image.jpg")) == jpeg,
			"capture must preserve exact original JPEG bytes")
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("capture.json")))
		_expect(parsed["timestamp_ns"] == "1234567890123456", "capture timestamp must retain integer precision")
		_expect(parsed["camera_calibration_verified"] == false, "unverified calibration must remain unverified")
		for file in ["image.jpg", "capture.json"]:
			DirAccess.remove_absolute(directory.path_join(file))
		DirAccess.remove_absolute(directory)
	if failures.is_empty():
		print("Cabinet visual geometry/capture self-test passed")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
