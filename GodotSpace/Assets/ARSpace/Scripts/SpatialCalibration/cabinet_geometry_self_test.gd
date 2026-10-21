extends SceneTree

const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var dimensions := Vector3(1.2, 2.0, 0.6)
	var k := Vector4(650, 660, 480, 360)
	var size := Vector2i(960, 720)
	var rng := RandomNumberGenerator.new()
	rng.seed = 41014
	for index in range(60):
		var pose := Transform3D(Basis.from_euler(Vector3(
			rng.randf_range(-0.15, 0.15), rng.randf_range(-0.55, 0.55),
			rng.randf_range(-0.08, 0.08))), Vector3(-0.6, -1.0, -rng.randf_range(3.0, 5.0)))
		var pixels := PackedVector2Array()
		var corners := Geometry.corners(dimensions)
		for point in corners.slice(0, 4):
			pixels.append(Geometry.project(pose, point, k))
		var result := Geometry.solve(pixels, dimensions, k, size)
		_expect(result.has("transform"), "synthetic pose %d solves: %s" % [index, result])
		if result.has("transform"):
			var actual: Transform3D = result.transform
			_expect(actual.origin.distance_to(pose.origin) < 0.002, "translation recovers ground truth")
			_expect(actual.basis.get_rotation_quaternion().angle_to(pose.basis.get_rotation_quaternion()) < 0.002,
				"rotation recovers ground truth")
			_expect(float(result.rms_px) < 0.05, "exact reprojection is subpixel")
		for i in range(4):
			pixels[i] += Vector2(rng.randf_range(-0.7, 0.7), rng.randf_range(-0.7, 0.7))
		var noisy := Geometry.solve(pixels, dimensions, k, size)
		_expect(noisy.has("transform"), "noisy points solve")
		if noisy.has("transform"):
			_expect((noisy.transform as Transform3D).origin.distance_to(pose.origin) < 0.1,
				"bounded click noise has bounded translation error")
	var points := PackedVector2Array([Vector2(100, 100), Vector2(400, 100), Vector2(400, 600), Vector2(100, 600)])
	_expect(Geometry.solve(PackedVector2Array([points[0], points[2], points[1], points[3]]), dimensions, k, size).has("error"), "crossed points rejected")
	_expect(Geometry.solve(PackedVector2Array([points[0], points[0], points[2], points[3]]), dimensions, k, size).has("error"), "duplicate points rejected")
	_expect(Geometry.solve(points, Vector3(-1, 2, 1), k, size).has("error"), "negative dimensions rejected")
	_expect(Geometry.solve(points, dimensions, Vector4(NAN, 1, 1, 1), size).has("error"), "nonfinite intrinsics rejected")
	_expect(Geometry.intrinsics_from_metadata({}, size).has("error"), "missing metadata cannot silently become camera calibration")
	var pose := Transform3D(Basis.from_euler(Vector3(0.1, 0.2, 0.3)), Vector3(1, 2, 3))
	var encoded := Geometry.encode_transform(pose)
	_expect(Geometry.decode_transform(encoded) != null, "rigid pose serializes")
	encoded[0] = 9.0
	_expect(Geometry.decode_transform(encoded) == null, "scaled/sheared matrix rejected")
	if failures.is_empty():
		print("Cabinet geometry self-test passed (60 exact and noisy poses, invalid inputs).")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
