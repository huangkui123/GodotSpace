extends SceneTree

const Registration := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Registration/reconstruction_registration.gd"
)

const EPSILON: float = 0.0005
const ROTATION_EPSILON_RADIANS: float = 0.001

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var root_node := Node3D.new()
	root_node.name = "ReconstructionRoot"
	root.add_child(root_node)
	var registration := Registration.new()
	registration.name = "Registration"
	root.add_child(registration)
	registration.set_reconstruction_root(root_node)

	var expected_scale := 2.25
	var expected_yaw := deg_to_rad(32.0)
	var expected_pitch := deg_to_rad(-18.0)
	var expected_roll := deg_to_rad(11.0)
	var expected_rotation := (
		Basis(Vector3.UP, expected_yaw)
		* Basis(Vector3.RIGHT, expected_pitch)
		* Basis(Vector3.FORWARD, expected_roll)
	).orthonormalized()
	var expected_translation := Vector3(1.2, 0.35, -2.4)
	var source_positions: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.10, 0.04, 0.02),
		Vector3(0.22, -0.03, 0.08),
		Vector3(0.34, 0.11, 0.16),
		Vector3(0.43, -0.06, 0.27),
		Vector3(0.48, 0.15, 0.39),
		Vector3(0.52, 0.01, 0.53),
	]

	registration.begin_collection()
	for index in range(source_positions.size()):
		var frame_id := "frame_%03d" % index
		var source_basis := Basis(Vector3.UP, deg_to_rad(float(index) * 3.0))
		var source_transform := Transform3D(source_basis, source_positions[index])
		var target_transform := Transform3D(
			expected_rotation * source_basis,
			expected_translation \
				+ expected_rotation * source_positions[index] * expected_scale
		)
		_expect(
			registration.add_pico_sample(
				frame_id,
				{"timestamp_seconds": float(index)},
				target_transform
			),
			"synthetic PICO sample must be accepted"
		)
		_expect(
			registration.add_lingbot_sample(frame_id, source_transform),
			"synthetic LingBot sample must be accepted"
		)

	var solve_result: Dictionary = registration.solve_automatic()
	_expect(bool(solve_result.get("ok", false)), "synthetic Sim(3) solve must succeed")
	var manifest: Dictionary = registration.get_registration_manifest()
	var automatic := manifest.get("automatic", {}) as Dictionary
	var quality := manifest.get("quality", {}) as Dictionary
	_expect(
		absf(float(automatic.get("scale", 0.0)) - expected_scale) < EPSILON,
		"automatic solve must recover uniform scale"
	)
	_expect(
		_array_vector3(automatic.get("translation", []) as Array).distance_to(
			expected_translation
		) < EPSILON,
		"automatic solve must recover translation"
	)
	var recovered_rotation_values := automatic.get(
		"rotation_quaternion",
		[]
	) as Array
	var recovered_rotation := Basis(Quaternion(
		float(recovered_rotation_values[0]),
		float(recovered_rotation_values[1]),
		float(recovered_rotation_values[2]),
		float(recovered_rotation_values[3])
	).normalized())
	_expect(
		Quaternion(recovered_rotation).angle_to(Quaternion(expected_rotation)) \
			< ROTATION_EPSILON_RADIANS,
		"automatic solve must recover pitch, yaw, and roll"
	)
	_expect(
		float(quality.get("position_rms_cm", 999.0)) < 0.01,
		"synthetic position RMS must be near zero"
	)
	_expect(
		float(quality.get("rotation_rms_deg", 999.0)) < 0.05,
		"synthetic rotation RMS must be near zero"
	)
	_expect(
		int(quality.get("pair_count", 0)) == source_positions.size(),
		"solve must use exact frame-id pairs"
	)
	_expect(
		str(quality.get("target_pose_mode", "")) == "head_fallback",
		"solve without PICO extrinsics must record the head fallback"
	)
	_expect(
		_transform_is_equal(root_node.transform, registration.get_combined_transform()),
		"solve must apply the combined Sim(3) to ReconstructionRoot"
	)
	var probe_source := Vector3(0.25, -0.1, 0.4)
	var probe_expected := expected_translation \
		+ expected_rotation * probe_source * expected_scale
	_expect(
		(registration.get_combined_transform() * probe_source).distance_to(
			probe_expected
		) < EPSILON,
		"combined transform must map LingBot points into Godot shared space"
	)

	var automatic_transform := registration.get_combined_transform()
	_expect(
		registration.apply_manual_adjustment(&"translation_x", 0.05),
		"manual X translation must be accepted"
	)
	_expect(
		registration.apply_manual_adjustment(&"translation_y", -0.02),
		"manual Y translation must be accepted"
	)
	_expect(
		registration.apply_manual_adjustment(&"translation_z", 0.03),
		"manual Z translation must be accepted"
	)
	_expect(
		registration.apply_manual_adjustment(&"yaw_degrees", 5.0),
		"manual yaw must be accepted"
	)
	_expect(
		registration.apply_manual_adjustment(&"pitch_degrees", 1.0),
		"advanced manual pitch must be accepted"
	)
	_expect(
		registration.apply_manual_adjustment(&"roll_degrees", -1.5),
		"advanced manual roll must be accepted"
	)
	_expect(
		registration.apply_manual_adjustment(&"scale_delta", 0.05),
		"manual uniform scale must be accepted"
	)
	var valid_manual_transform := registration.get_combined_transform()
	_expect(
		not registration.apply_manual_adjustment(&"scale_delta", -1.0),
		"unsafe manual scale must be rejected"
	)
	_expect(
		_transform_is_equal(
			registration.get_combined_transform(),
			valid_manual_transform
		),
		"rejected manual scale must not mutate the applied Sim(3)"
	)
	_expect(
		not _transform_is_equal(
			registration.get_combined_transform(),
			automatic_transform
		),
		"manual adjustment must change only the root Sim(3)"
	)
	_expect(registration.reset_manual(), "manual registration must reset")
	_expect(
		_transform_is_equal(registration.get_combined_transform(), automatic_transform),
		"manual reset must restore the automatic Sim(3)"
	)

	registration.apply_manual_adjustment(&"yaw_degrees", 2.0)
	registration.apply_manual_adjustment(&"scale_delta", 0.01)
	var round_trip_manifest := registration.get_registration_manifest()
	var second_root := Node3D.new()
	root.add_child(second_root)
	var restored_registration := Registration.new()
	root.add_child(restored_registration)
	restored_registration.set_reconstruction_root(second_root)
	_expect(
		restored_registration.set_registration_manifest(round_trip_manifest),
		"registration manifest must restore"
	)
	_expect(
		_transform_is_equal(
			restored_registration.get_combined_transform(),
			registration.get_combined_transform()
		),
		"registration manifest must preserve the combined Sim(3)"
	)
	var invalid_manifest := round_trip_manifest.duplicate(true)
	(invalid_manifest["automatic"] as Dictionary)["scale"] = 1000.0
	var restored_before_invalid := restored_registration.get_combined_transform()
	_expect(
		not restored_registration.set_registration_manifest(invalid_manifest),
		"manifest scale outside the safe range must be rejected"
	)
	_expect(
		_transform_is_equal(
			restored_registration.get_combined_transform(),
			restored_before_invalid
		),
		"rejected manifest must not mutate the applied Sim(3)"
	)

	var short_registration := Registration.new()
	root.add_child(short_registration)
	short_registration.begin_collection()
	_add_simple_samples(short_registration, 4.0, 1.0)
	var short_result: Dictionary = short_registration.solve_automatic()
	_expect(
		not bool(short_result.get("ok", true)),
		"collection shorter than five seconds must be rejected"
	)

	var static_registration := Registration.new()
	root.add_child(static_registration)
	static_registration.begin_collection()
	_add_simple_samples(static_registration, 6.0, 0.02)
	var static_result: Dictionary = static_registration.solve_automatic()
	_expect(
		not bool(static_result.get("ok", true)),
		"trajectory shorter than 0.3 m must be rejected"
	)

	var extrinsic_registration := Registration.new()
	root.add_child(extrinsic_registration)
	_add_extrinsic_samples(
		extrinsic_registration,
		expected_scale,
		expected_rotation,
		expected_translation
	)
	var extrinsic_result: Dictionary = extrinsic_registration.solve_automatic()
	_expect(
		bool(extrinsic_result.get("ok", false)),
		"valid PICO camera-to-head extrinsics must produce a solution"
	)
	var extrinsic_quality := extrinsic_registration.get_quality()
	_expect(
		str(extrinsic_quality.get("target_pose_mode", "")) == "pico_camera_to_head",
		"solver must select the physically correct PICO extrinsic direction"
	)
	_expect(
		bool(extrinsic_quality.get("pico_extrinsics_used", false)),
		"quality metadata must report PICO extrinsic use"
	)

	var bad_quality_registration := Registration.new()
	root.add_child(bad_quality_registration)
	bad_quality_registration.begin_collection()
	for index in range(source_positions.size()):
		var ratio := float(index) / float(source_positions.size() - 1)
		var source_transform := Transform3D(Basis.IDENTITY, source_positions[index])
		var bad_offset := Vector3(0.35, -0.25, 0.2) \
			if index % 2 == 0 else Vector3(-0.35, 0.25, -0.2)
		var target_transform := Transform3D(
			Basis(Vector3.UP, ratio * 1.5),
			expected_translation \
				+ expected_rotation * source_positions[index] * expected_scale \
				+ bad_offset
		)
		var bad_frame_id := "bad_%d" % index
		bad_quality_registration.add_pico_sample(
			bad_frame_id,
			{"timestamp_seconds": ratio * 6.0},
			target_transform
		)
		bad_quality_registration.add_lingbot_sample(bad_frame_id, source_transform)
	var bad_quality_result: Dictionary = bad_quality_registration.solve_automatic()
	_expect(
		not bool(bad_quality_result.get("ok", true)),
		"registration with excessive residuals must be rejected"
	)
	_expect(
		not bool(
			bad_quality_registration.get_registration_manifest().get("solved", true)
		),
		"rejected registration must not set the solved flag"
	)

	registration.reset_registration()
	_expect(
		not bool(registration.get_registration_manifest().get("solved", true)),
		"full registration reset must clear the solved flag"
	)
	_expect(
		registration.get_quality().is_empty(),
		"full registration reset must clear quality metrics"
	)
	_expect(
		_transform_is_equal(root_node.transform, Transform3D.IDENTITY),
		"full registration reset must restore ReconstructionRoot identity"
	)

	short_registration.queue_free()
	static_registration.queue_free()
	extrinsic_registration.queue_free()
	bad_quality_registration.queue_free()
	restored_registration.queue_free()
	second_root.queue_free()
	registration.queue_free()
	root_node.queue_free()
	await process_frame
	if _failures.is_empty():
		print("RECONSTRUCTION_REGISTRATION_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("RECONSTRUCTION_REGISTRATION_SELF_TEST: %s" % failure)
	quit(1)


func _add_simple_samples(
	registration: Node,
	duration_seconds: float,
	total_translation: float
) -> void:
	for index in range(7):
		var ratio := float(index) / 6.0
		var source_position := Vector3(total_translation * ratio, 0.0, ratio * 0.01)
		var source_transform := Transform3D(Basis.IDENTITY, source_position)
		var target_transform := Transform3D(
			Basis.IDENTITY,
			source_position * 2.0 + Vector3(1.0, 0.0, -1.0)
		)
		var frame_id := "simple_%d" % index
		registration.add_pico_sample(
			frame_id,
			{"timestamp_seconds": duration_seconds * ratio},
			target_transform
		)
		registration.add_lingbot_sample(frame_id, source_transform)


func _add_extrinsic_samples(
	registration: Node,
	expected_scale: float,
	expected_rotation: Basis,
	expected_translation: Vector3
) -> void:
	var camera_to_head := Transform3D(
		Basis(Vector3.UP, deg_to_rad(4.0)),
		Vector3(-0.035, 0.025, -0.045)
	)
	var source_positions: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.12, 0.05, 0.03),
		Vector3(0.23, -0.04, 0.10),
		Vector3(0.35, 0.13, 0.18),
		Vector3(0.46, -0.05, 0.30),
		Vector3(0.55, 0.16, 0.43),
		Vector3(0.62, 0.02, 0.58),
	]
	registration.begin_collection()
	for index in range(source_positions.size()):
		var ratio := float(index) / float(source_positions.size() - 1)
		var source_basis := (
			Basis(Vector3.UP, ratio * 0.5)
			* Basis(Vector3.RIGHT, ratio * 0.2)
		).orthonormalized()
		var source_camera := Transform3D(source_basis, source_positions[index])
		var target_camera := Transform3D(
			expected_rotation * source_basis,
			expected_translation \
				+ expected_rotation * source_positions[index] * expected_scale
		)
		var target_head := target_camera * camera_to_head.affine_inverse()
		var frame_id := "extrinsic_%d" % index
		registration.add_pico_sample(
			frame_id,
			{
				"timestamp_seconds": ratio * 6.0,
				"selected_camera_index": 0,
				"camera_extrinsics_status": 1,
				"camera_extrinsics_primary": _transform_to_row_major(
					camera_to_head
				),
			},
			target_head
		)
		registration.add_lingbot_sample(frame_id, source_camera)


func _transform_to_row_major(transform: Transform3D) -> Array[float]:
	return [
		transform.basis.x.x,
		transform.basis.y.x,
		transform.basis.z.x,
		transform.origin.x,
		transform.basis.x.y,
		transform.basis.y.y,
		transform.basis.z.y,
		transform.origin.y,
		transform.basis.x.z,
		transform.basis.y.z,
		transform.basis.z.z,
		transform.origin.z,
		0.0,
		0.0,
		0.0,
		1.0,
	]


func _array_vector3(values: Array) -> Vector3:
	if values.size() != 3:
		return Vector3(INF, INF, INF)
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


func _transform_is_equal(first: Transform3D, second: Transform3D) -> bool:
	return first.origin.is_equal_approx(second.origin) \
		and first.basis.x.is_equal_approx(second.basis.x) \
		and first.basis.y.is_equal_approx(second.basis.y) \
		and first.basis.z.is_equal_approx(second.basis.z)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
