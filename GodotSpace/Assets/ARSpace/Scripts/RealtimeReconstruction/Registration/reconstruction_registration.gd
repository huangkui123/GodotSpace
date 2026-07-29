class_name ReconstructionRegistration
extends Node

## Estimates and applies one Sim(3) from LingBot map space into the parent
## space of ReconstructionRoot. Point data remains unchanged in LingBot space.

const MANIFEST_SCHEMA_VERSION: int = 1
const MIN_PAIR_COUNT: int = 6
const MIN_COLLECTION_SECONDS: float = 5.0
const MIN_TRANSLATION_SPAN_METERS: float = 0.3
const MIN_SOURCE_ENERGY: float = 0.000001
const MIN_AUTOMATIC_SCALE: float = 0.01
const MAX_AUTOMATIC_SCALE: float = 100.0
const MAX_POSITION_RMS_CM: float = 8.0
const MAX_ROTATION_RMS_DEGREES: float = 15.0
const HEAD_FALLBACK_SCORE_PENALTY: float = 0.35
const MIN_MANUAL_SCALE: float = 0.1
const MAX_MANUAL_SCALE: float = 10.0
const MAX_MANUAL_TRANSLATION_METERS: float = 100.0
const MAX_FRAME_ID_LENGTH: int = 128
const MAX_SAMPLE_COUNT: int = 1200
const EXTRINSIC_MATRIX_SIZE: int = 16
const EXTRINSIC_ORTHONORMAL_EPSILON: float = 0.001
const EXTRINSIC_LAST_ROW_EPSILON: float = 0.0001
const TARGET_MODE_CAMERA_TO_HEAD: StringName = &"pico_camera_to_head"
const TARGET_MODE_HEAD_TO_CAMERA: StringName = &"pico_head_to_camera"
const TARGET_MODE_HEAD_FALLBACK: StringName = &"head_fallback"

# LingBot camera bases use an OpenCV-style local camera convention. The
# per-session camera-basis correction is estimated from paired orientations,
# while this explicit conversion is retained as the deterministic fallback.
const OPENCV_TO_GODOT_CAMERA_BASIS := Basis(
	Vector3.RIGHT,
	Vector3.DOWN,
	Vector3.FORWARD
)

signal collection_started
signal sample_count_changed(pico_count: int, lingbot_count: int, paired_count: int)
signal automatic_solved(manifest: Dictionary)
signal registration_changed(manifest: Dictionary)
signal registration_applied(combined_transform: Transform3D)
signal registration_failed(message: String)

@export var reconstruction_root_path: NodePath

var _reconstruction_root: Node3D
var _pico_samples_by_frame: Dictionary = {}
var _lingbot_samples_by_frame: Dictionary = {}
var _collection_started_seconds: float = 0.0

var _solved: bool = false
var _auto_scale: float = 1.0
var _auto_rotation: Basis = Basis.IDENTITY
var _auto_translation: Vector3 = Vector3.ZERO
var _manual_translation: Vector3 = Vector3.ZERO
var _manual_yaw_degrees: float = 0.0
var _manual_pitch_degrees: float = 0.0
var _manual_roll_degrees: float = 0.0
var _manual_scale: float = 1.0
var _manual_pivot: Vector3 = Vector3.ZERO
var _quality: Dictionary = {}
var _last_error: String = ""


func _ready() -> void:
	add_to_group("reconstruction_registration")
	call_deferred("_resolve_reconstruction_root")


func set_reconstruction_root(root: Node3D) -> void:
	_reconstruction_root = root
	_apply_combined_transform()


func begin_collection() -> void:
	_pico_samples_by_frame.clear()
	_lingbot_samples_by_frame.clear()
	_collection_started_seconds = Time.get_ticks_msec() / 1000.0
	_last_error = ""
	collection_started.emit()
	sample_count_changed.emit(0, 0, 0)


func add_pico_sample(
	frame_id: Variant,
	metadata: Dictionary,
	godot_world_camera: Variant = null
) -> bool:
	var normalized_frame_id: String = _normalize_frame_id(frame_id)
	if normalized_frame_id.is_empty():
		return _fail_bool("PICO sample frame_id is invalid")
	if not _pico_samples_by_frame.has(normalized_frame_id) \
			and _pico_samples_by_frame.size() >= MAX_SAMPLE_COUNT:
		return _fail_bool("PICO registration sample limit reached")
	var camera_transform: Variant = _extract_godot_camera_transform(
		metadata,
		godot_world_camera
	)
	if camera_transform != null \
			and not _is_finite_transform(camera_transform as Transform3D):
		return _fail_bool("PICO Godot-world camera transform is not finite")
	var timestamp_seconds: float = _extract_timestamp_seconds(metadata)
	if not is_finite(timestamp_seconds):
		return _fail_bool("PICO sample timestamp is not finite")
	_pico_samples_by_frame[normalized_frame_id] = {
		"metadata": metadata.duplicate(true),
		"timestamp_seconds": timestamp_seconds,
		"godot_world_camera": camera_transform,
	}
	_emit_sample_counts()
	return true


func add_lingbot_sample(
	frame_id: Variant,
	camera_to_lingbot_world: Transform3D
) -> bool:
	var normalized_frame_id: String = _normalize_frame_id(frame_id)
	if normalized_frame_id.is_empty():
		return _fail_bool("LingBot sample frame_id is invalid")
	if not _is_finite_transform(camera_to_lingbot_world):
		return _fail_bool("LingBot camera transform is not finite")
	if not _lingbot_samples_by_frame.has(normalized_frame_id) \
			and _lingbot_samples_by_frame.size() >= MAX_SAMPLE_COUNT:
		return _fail_bool("LingBot registration sample limit reached")
	_lingbot_samples_by_frame[normalized_frame_id] = camera_to_lingbot_world
	_emit_sample_counts()
	return true


func solve_automatic() -> Dictionary:
	var head_pairs := _collect_pairs(TARGET_MODE_HEAD_FALLBACK)
	if head_pairs.size() < MIN_PAIR_COUNT:
		return _failure_result(
			"Automatic registration needs at least %d paired camera samples" \
			% MIN_PAIR_COUNT
		)
	var duration_seconds := _paired_duration_seconds(head_pairs)
	if duration_seconds < MIN_COLLECTION_SECONDS:
		return _failure_result(
			"Automatic registration needs at least %.1f seconds of motion" \
			% MIN_COLLECTION_SECONDS
		)
	var target_span_meters := _maximum_pair_distance(head_pairs, &"target_position")
	if target_span_meters < MIN_TRANSLATION_SPAN_METERS:
		return _failure_result(
			"Automatic registration needs at least %.2f m of camera translation" \
			% MIN_TRANSLATION_SPAN_METERS
		)

	var modes: Array[StringName] = [
		TARGET_MODE_CAMERA_TO_HEAD,
		TARGET_MODE_HEAD_TO_CAMERA,
		TARGET_MODE_HEAD_FALLBACK,
	]
	var candidates: Array[Dictionary] = []
	for target_mode in modes:
		var candidate_pairs := _collect_pairs(target_mode)
		if candidate_pairs.size() < MIN_PAIR_COUNT:
			continue
		var candidate_duration := _paired_duration_seconds(candidate_pairs)
		if candidate_duration < MIN_COLLECTION_SECONDS:
			continue
		var candidate_span := _maximum_pair_distance(
			candidate_pairs,
			&"target_position"
		)
		if candidate_span < MIN_TRANSLATION_SPAN_METERS:
			continue
		var candidate := _solve_similarity_candidate(
			candidate_pairs,
			target_mode,
			candidate_duration,
			candidate_span
		)
		if bool(candidate.get("ok", false)):
			candidates.append(candidate)
	if candidates.is_empty():
		return _failure_result(
			"Automatic 3D registration could not solve a valid camera trajectory"
		)
	candidates.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return float(first.get("score", INF)) < float(second.get("score", INF))
	)
	var passing_candidates: Array[Dictionary] = []
	for candidate in candidates:
		var candidate_residuals := candidate.get("residuals", {}) as Dictionary
		if float(
			candidate_residuals.get("position_rms_cm", INF)
		) <= MAX_POSITION_RMS_CM and float(
			candidate_residuals.get("rotation_rms_deg", INF)
		) <= MAX_ROTATION_RMS_DEGREES:
			passing_candidates.append(candidate)
	var selected := candidates[0]
	if not passing_candidates.is_empty():
		selected = passing_candidates[0]
	var selected_residuals := selected.get("residuals", {}) as Dictionary
	var position_rms_cm := float(selected_residuals.get("position_rms_cm", INF))
	var rotation_rms_degrees := float(
		selected_residuals.get("rotation_rms_deg", INF)
	)
	if position_rms_cm > MAX_POSITION_RMS_CM:
		return _failure_result(
			"Automatic registration rejected: position RMS %.2f cm exceeds %.2f cm" \
			% [position_rms_cm, MAX_POSITION_RMS_CM]
		)
	if rotation_rms_degrees > MAX_ROTATION_RMS_DEGREES:
		return _failure_result(
			"Automatic registration rejected: rotation RMS %.2f degrees exceeds %.2f" \
			% [rotation_rms_degrees, MAX_ROTATION_RMS_DEGREES]
		)

	var selected_pairs := selected.get("pairs", []) as Array[Dictionary]
	var target_centroid := _centroid(selected_pairs, &"target_position")
	_auto_scale = float(selected["scale"])
	_auto_rotation = selected["rotation"] as Basis
	_auto_translation = selected["translation"] as Vector3
	_manual_translation = Vector3.ZERO
	_manual_yaw_degrees = 0.0
	_manual_pitch_degrees = 0.0
	_manual_roll_degrees = 0.0
	_manual_scale = 1.0
	_manual_pivot = target_centroid
	_quality = {
		"pair_count": selected_pairs.size(),
		"duration_seconds": float(selected["duration_seconds"]),
		"translation_span_m": float(selected["translation_span_m"]),
		"position_rms_cm": position_rms_cm,
		"rotation_rms_deg": rotation_rms_degrees,
		"target_pose_mode": str(selected["target_mode"]),
		"pico_extrinsics_used": bool(selected["pico_extrinsics_used"]),
		"camera_basis_correction_quaternion": _quaternion_to_array(
			Quaternion(
				selected["camera_basis_correction"] as Basis
			).normalized()
		),
		"position_rms_limit_cm": MAX_POSITION_RMS_CM,
		"rotation_rms_limit_deg": MAX_ROTATION_RMS_DEGREES,
	}
	_solved = true
	_last_error = ""
	_apply_combined_transform()
	var manifest := get_registration_manifest()
	automatic_solved.emit(manifest)
	registration_changed.emit(manifest)
	return {
		"ok": true,
		"manifest": manifest,
		"combined_transform": get_combined_transform(),
	}


func apply_manual_adjustment(kind: StringName, amount: float) -> bool:
	if not _solved:
		return _fail_bool("Automatic registration must be solved before manual adjustment")
	if not is_finite(amount):
		return _fail_bool("Manual adjustment amount is not finite")
	var previous_translation := _manual_translation
	var previous_yaw := _manual_yaw_degrees
	var previous_pitch := _manual_pitch_degrees
	var previous_roll := _manual_roll_degrees
	var previous_scale := _manual_scale
	match kind:
		&"translation_x":
			_manual_translation.x += amount
		&"translation_y":
			_manual_translation.y += amount
		&"translation_z":
			_manual_translation.z += amount
		&"yaw_degrees":
			_manual_yaw_degrees += amount
		&"pitch_degrees":
			_manual_pitch_degrees += amount
		&"roll_degrees":
			_manual_roll_degrees += amount
		&"scale_delta", &"uniform_scale":
			if amount <= -1.0:
				return _fail_bool("Manual scale delta must be greater than -1")
			var next_scale := _manual_scale * (1.0 + amount)
			if not is_finite(next_scale) \
					or next_scale < MIN_MANUAL_SCALE \
					or next_scale > MAX_MANUAL_SCALE:
				return _fail_bool("Manual scale is outside the safe range")
			_manual_scale = next_scale
		_:
			return _fail_bool("Unsupported manual registration adjustment: %s" % kind)
	if not _manual_values_are_finite() \
			or _manual_translation.length() > MAX_MANUAL_TRANSLATION_METERS:
		_manual_translation = previous_translation
		_manual_yaw_degrees = previous_yaw
		_manual_pitch_degrees = previous_pitch
		_manual_roll_degrees = previous_roll
		_manual_scale = previous_scale
		return _fail_bool("Manual registration values are outside the safe range")
	_normalize_manual_angles()
	_last_error = ""
	_apply_combined_transform()
	registration_changed.emit(get_registration_manifest())
	return true


func reset_manual() -> bool:
	if not _solved:
		return false
	_manual_translation = Vector3.ZERO
	_manual_yaw_degrees = 0.0
	_manual_pitch_degrees = 0.0
	_manual_roll_degrees = 0.0
	_manual_scale = 1.0
	_last_error = ""
	_apply_combined_transform()
	registration_changed.emit(get_registration_manifest())
	return true


func reset_registration() -> void:
	_pico_samples_by_frame.clear()
	_lingbot_samples_by_frame.clear()
	_collection_started_seconds = 0.0
	_solved = false
	_auto_scale = 1.0
	_auto_rotation = Basis.IDENTITY
	_auto_translation = Vector3.ZERO
	_manual_translation = Vector3.ZERO
	_manual_yaw_degrees = 0.0
	_manual_pitch_degrees = 0.0
	_manual_roll_degrees = 0.0
	_manual_scale = 1.0
	_manual_pivot = Vector3.ZERO
	_quality.clear()
	_last_error = ""
	_apply_combined_transform()
	sample_count_changed.emit(0, 0, 0)
	registration_changed.emit(get_registration_manifest())


func get_registration_manifest() -> Dictionary:
	return {
		"schema_version": MANIFEST_SCHEMA_VERSION,
		"coordinate_contract": "lingbot_world_to_reconstruction_root_parent",
		"solved": _solved,
		"automatic": {
			"scale": _auto_scale,
			"rotation_quaternion": _quaternion_to_array(
				Quaternion(_auto_rotation.orthonormalized())
			),
			"yaw_degrees": rad_to_deg(_auto_rotation.get_euler().y),
			"translation": _vector3_to_array(_auto_translation),
		},
		"manual": {
			"translation": _vector3_to_array(_manual_translation),
			"yaw_degrees": _manual_yaw_degrees,
			"pitch_degrees": _manual_pitch_degrees,
			"roll_degrees": _manual_roll_degrees,
			"scale": _manual_scale,
			"pivot": _vector3_to_array(_manual_pivot),
		},
		"quality": _quality.duplicate(true),
	}


func set_registration_manifest(manifest: Dictionary) -> bool:
	var validation_error := _registration_manifest_error(manifest)
	if not validation_error.is_empty():
		return _fail_bool(validation_error)
	var automatic := manifest["automatic"] as Dictionary
	var manual := manifest["manual"] as Dictionary
	var rotation_values := automatic["rotation_quaternion"] as Array
	var automatic_rotation := Basis(Quaternion(
		float(rotation_values[0]),
		float(rotation_values[1]),
		float(rotation_values[2]),
		float(rotation_values[3])
	).normalized())
	var automatic_scale := float(automatic["scale"])
	var automatic_translation := _array_to_vector3(automatic["translation"] as Array)
	var manual_translation := _array_to_vector3(manual["translation"] as Array)
	var manual_pivot := _array_to_vector3(manual["pivot"] as Array)
	var manual_yaw := float(manual["yaw_degrees"])
	var manual_pitch := float(manual["pitch_degrees"])
	var manual_roll := float(manual["roll_degrees"])
	var manual_scale := float(manual["scale"])

	_solved = true
	_auto_scale = automatic_scale
	_auto_rotation = automatic_rotation
	_auto_translation = automatic_translation
	_manual_translation = manual_translation
	_manual_yaw_degrees = manual_yaw
	_manual_pitch_degrees = manual_pitch
	_manual_roll_degrees = manual_roll
	_manual_scale = manual_scale
	_manual_pivot = manual_pivot
	_quality = (manifest.get("quality", {}) as Dictionary).duplicate(true)
	_normalize_manual_angles()
	_last_error = ""
	_apply_combined_transform()
	registration_changed.emit(get_registration_manifest())
	return true


func get_combined_transform() -> Transform3D:
	var automatic_basis := _auto_rotation.scaled(Vector3.ONE * _auto_scale)
	var manual_basis := _manual_rotation().scaled(Vector3.ONE * _manual_scale)
	var combined_basis := manual_basis * automatic_basis
	var combined_origin := _manual_pivot \
		+ _manual_translation \
		+ manual_basis * (_auto_translation - _manual_pivot)
	return Transform3D(combined_basis, combined_origin)


func get_last_error() -> String:
	return _last_error


func get_quality() -> Dictionary:
	return _quality.duplicate(true)


func _resolve_reconstruction_root() -> void:
	if not reconstruction_root_path.is_empty():
		_reconstruction_root = get_node_or_null(reconstruction_root_path) as Node3D
	if _reconstruction_root == null:
		_reconstruction_root = get_tree().get_first_node_in_group(
			"reconstruction_root"
		) as Node3D
	_apply_combined_transform()


func _apply_combined_transform() -> void:
	if _reconstruction_root == null or not is_instance_valid(_reconstruction_root):
		return
	var combined_transform := get_combined_transform()
	if not _is_finite_transform(combined_transform):
		_fail_bool("Combined registration transform is not finite")
		return
	_reconstruction_root.transform = combined_transform
	registration_applied.emit(combined_transform)


func _collect_pairs(
	target_mode: StringName = TARGET_MODE_HEAD_FALLBACK
) -> Array[Dictionary]:
	var frame_ids: Array[String] = []
	for frame_id_value in _pico_samples_by_frame:
		var frame_id := str(frame_id_value)
		if not _lingbot_samples_by_frame.has(frame_id):
			continue
		var pico_sample := _pico_samples_by_frame[frame_id] as Dictionary
		if pico_sample.get("godot_world_camera") == null:
			continue
		frame_ids.append(frame_id)
	frame_ids.sort()
	var pairs: Array[Dictionary] = []
	for frame_id in frame_ids:
		var pico_sample := _pico_samples_by_frame[frame_id] as Dictionary
		var head_transform := pico_sample["godot_world_camera"] as Transform3D
		var target_transform_variant: Variant = _target_camera_transform(
			head_transform,
			pico_sample.get("metadata", {}) as Dictionary,
			target_mode
		)
		if target_transform_variant == null:
			continue
		var target_transform := target_transform_variant as Transform3D
		var source_transform := _lingbot_samples_by_frame[frame_id] as Transform3D
		pairs.append({
			"frame_id": frame_id,
			"timestamp_seconds": float(pico_sample["timestamp_seconds"]),
			"source_transform": source_transform,
			"target_transform": target_transform,
			"source_position": source_transform.origin,
			"target_position": target_transform.origin,
		})
	return pairs


func _target_camera_transform(
	head_transform: Transform3D,
	metadata: Dictionary,
	target_mode: StringName
) -> Variant:
	if target_mode == TARGET_MODE_HEAD_FALLBACK:
		return head_transform
	var extrinsic_variant: Variant = _extract_selected_pico_extrinsic(metadata)
	if extrinsic_variant == null:
		return null
	var camera_to_head := extrinsic_variant as Transform3D
	if target_mode == TARGET_MODE_CAMERA_TO_HEAD:
		return head_transform * camera_to_head
	if target_mode == TARGET_MODE_HEAD_TO_CAMERA:
		return head_transform * camera_to_head.affine_inverse()
	return null


func _extract_selected_pico_extrinsic(metadata: Dictionary) -> Variant:
	var selected_camera_index := int(metadata.get("selected_camera_index", 0))
	var key := (
		"camera_extrinsics_secondary"
		if selected_camera_index == 1
		else "camera_extrinsics_primary"
	)
	var values_variant: Variant = metadata.get(key)
	if typeof(values_variant) != TYPE_ARRAY:
		return null
	var values := values_variant as Array
	if values.size() != EXTRINSIC_MATRIX_SIZE:
		return null
	var numbers: Array[float] = []
	for value in values:
		if not _is_number(value) or not is_finite(float(value)):
			return null
		numbers.append(float(value))
	if absf(numbers[12]) > EXTRINSIC_LAST_ROW_EPSILON \
			or absf(numbers[13]) > EXTRINSIC_LAST_ROW_EPSILON \
			or absf(numbers[14]) > EXTRINSIC_LAST_ROW_EPSILON \
			or absf(numbers[15] - 1.0) > EXTRINSIC_LAST_ROW_EPSILON:
		return null
	var basis := Basis(
		Vector3(numbers[0], numbers[4], numbers[8]),
		Vector3(numbers[1], numbers[5], numbers[9]),
		Vector3(numbers[2], numbers[6], numbers[10])
	)
	if absf(basis.determinant() - 1.0) > EXTRINSIC_ORTHONORMAL_EPSILON:
		return null
	var orthonormal_basis := basis.orthonormalized()
	if basis.x.distance_to(orthonormal_basis.x) > EXTRINSIC_ORTHONORMAL_EPSILON \
			or basis.y.distance_to(orthonormal_basis.y) > EXTRINSIC_ORTHONORMAL_EPSILON \
			or basis.z.distance_to(orthonormal_basis.z) > EXTRINSIC_ORTHONORMAL_EPSILON:
		return null
	return Transform3D(
		orthonormal_basis,
		Vector3(numbers[3], numbers[7], numbers[11])
	)


func _paired_duration_seconds(pairs: Array[Dictionary]) -> float:
	var minimum_timestamp := INF
	var maximum_timestamp := -INF
	for pair in pairs:
		var timestamp := float(pair["timestamp_seconds"])
		minimum_timestamp = minf(minimum_timestamp, timestamp)
		maximum_timestamp = maxf(maximum_timestamp, timestamp)
	return maximum_timestamp - minimum_timestamp


func _maximum_pair_distance(pairs: Array[Dictionary], position_key: StringName) -> float:
	var maximum_distance := 0.0
	for first_index in range(pairs.size()):
		var first_position := pairs[first_index][position_key] as Vector3
		for second_index in range(first_index + 1, pairs.size()):
			var second_position := pairs[second_index][position_key] as Vector3
			maximum_distance = maxf(
				maximum_distance,
				first_position.distance_to(second_position)
			)
	return maximum_distance


func _solve_similarity_candidate(
	pairs: Array[Dictionary],
	target_mode: StringName,
	duration_seconds: float,
	translation_span_meters: float
) -> Dictionary:
	var source_centroid := _centroid(pairs, &"source_position")
	var target_centroid := _centroid(pairs, &"target_position")
	var rotation_result := _estimate_full_rotation(
		pairs,
		source_centroid,
		target_centroid
	)
	if not bool(rotation_result.get("ok", false)):
		return rotation_result
	var rotation := rotation_result["rotation"] as Basis
	var numerator := 0.0
	var denominator := 0.0
	for pair in pairs:
		var source_delta := (pair["source_position"] as Vector3) - source_centroid
		var target_delta := (pair["target_position"] as Vector3) - target_centroid
		numerator += target_delta.dot(rotation * source_delta)
		denominator += source_delta.length_squared()
	if denominator < MIN_SOURCE_ENERGY:
		return {"ok": false, "error": "Camera trajectory has insufficient 3D motion"}
	var scale := numerator / denominator
	if not is_finite(scale) \
			or scale < MIN_AUTOMATIC_SCALE \
			or scale > MAX_AUTOMATIC_SCALE:
		return {"ok": false, "error": "Estimated automatic scale is outside the safe range"}
	var translation := target_centroid - rotation * source_centroid * scale
	if not _is_finite_vector3(translation):
		return {"ok": false, "error": "Estimated automatic translation is not finite"}
	var camera_basis_correction := _estimate_camera_basis_correction(pairs, rotation)
	var residuals := _calculate_residuals(
		pairs,
		scale,
		rotation,
		translation,
		camera_basis_correction
	)
	if not bool(residuals.get("ok", false)):
		return residuals
	var score := float(residuals["position_rms_cm"]) / MAX_POSITION_RMS_CM \
		+ float(residuals["rotation_rms_deg"]) / MAX_ROTATION_RMS_DEGREES
	if target_mode == TARGET_MODE_HEAD_FALLBACK \
			and _pairs_have_pico_extrinsics(pairs):
		score += HEAD_FALLBACK_SCORE_PENALTY
	return {
		"ok": true,
		"pairs": pairs,
		"scale": scale,
		"rotation": rotation,
		"translation": translation,
		"camera_basis_correction": camera_basis_correction,
		"residuals": residuals,
		"score": score,
		"target_mode": target_mode,
		"pico_extrinsics_used": target_mode != TARGET_MODE_HEAD_FALLBACK,
		"duration_seconds": duration_seconds,
		"translation_span_m": translation_span_meters,
	}


func _estimate_full_rotation(
	pairs: Array[Dictionary],
	source_centroid: Vector3,
	target_centroid: Vector3
) -> Dictionary:
	var sxx := 0.0
	var sxy := 0.0
	var sxz := 0.0
	var syx := 0.0
	var syy := 0.0
	var syz := 0.0
	var szx := 0.0
	var szy := 0.0
	var szz := 0.0
	var source_energy := 0.0
	for pair in pairs:
		var source := (pair["source_position"] as Vector3) - source_centroid
		var target := (pair["target_position"] as Vector3) - target_centroid
		source_energy += source.length_squared()
		sxx += source.x * target.x
		sxy += source.x * target.y
		sxz += source.x * target.z
		syx += source.y * target.x
		syy += source.y * target.y
		syz += source.y * target.z
		szx += source.z * target.x
		szy += source.z * target.y
		szz += source.z * target.z
	if source_energy < MIN_SOURCE_ENERGY:
		return {"ok": false, "error": "Camera trajectory has insufficient 3D variance"}
	var matrix: Array[Array] = [
		[sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
		[syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
		[szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
		[sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
	]
	var eigenvector := _largest_eigenvector_symmetric_4x4(matrix)
	if eigenvector.size() != 4:
		return {"ok": false, "error": "Could not solve the 3D rotation eigenproblem"}
	var quaternion := Quaternion(
		eigenvector[1],
		eigenvector[2],
		eigenvector[3],
		eigenvector[0]
	).normalized()
	if not is_finite(quaternion.length_squared()) \
			or quaternion.length_squared() < 0.999:
		return {"ok": false, "error": "Estimated automatic rotation is invalid"}
	return {"ok": true, "rotation": Basis(quaternion).orthonormalized()}


func _largest_eigenvector_symmetric_4x4(
	source_matrix: Array[Array]
) -> Array[float]:
	var matrix: Array[Array] = []
	var vectors: Array[Array] = []
	for row in range(4):
		matrix.append((source_matrix[row] as Array).duplicate())
		var vector_row: Array[float] = []
		for column in range(4):
			vector_row.append(1.0 if row == column else 0.0)
		vectors.append(vector_row)
	for _iteration in range(64):
		var first := 0
		var second := 1
		var largest := 0.0
		for row in range(4):
			for column in range(row + 1, 4):
				var magnitude := absf(float(matrix[row][column]))
				if magnitude > largest:
					largest = magnitude
					first = row
					second = column
		if largest < 0.000000000001:
			break
		var app := float(matrix[first][first])
		var aqq := float(matrix[second][second])
		var apq := float(matrix[first][second])
		var angle := 0.5 * atan2(2.0 * apq, aqq - app)
		var cosine := cos(angle)
		var sine := sin(angle)
		for index in range(4):
			if index == first or index == second:
				continue
			var aip := float(matrix[index][first])
			var aiq := float(matrix[index][second])
			var next_aip := cosine * aip - sine * aiq
			var next_aiq := sine * aip + cosine * aiq
			matrix[index][first] = next_aip
			matrix[first][index] = next_aip
			matrix[index][second] = next_aiq
			matrix[second][index] = next_aiq
		matrix[first][first] = cosine * cosine * app \
			- 2.0 * sine * cosine * apq \
			+ sine * sine * aqq
		matrix[second][second] = sine * sine * app \
			+ 2.0 * sine * cosine * apq \
			+ cosine * cosine * aqq
		matrix[first][second] = 0.0
		matrix[second][first] = 0.0
		for row in range(4):
			var vip := float(vectors[row][first])
			var viq := float(vectors[row][second])
			vectors[row][first] = cosine * vip - sine * viq
			vectors[row][second] = sine * vip + cosine * viq
	var largest_index := 0
	for index in range(1, 4):
		if float(matrix[index][index]) > float(matrix[largest_index][largest_index]):
			largest_index = index
	var result: Array[float] = []
	var length_squared := 0.0
	for row in range(4):
		var value := float(vectors[row][largest_index])
		result.append(value)
		length_squared += value * value
	if length_squared < 0.000000000001:
		return []
	var inverse_length := 1.0 / sqrt(length_squared)
	for index in range(result.size()):
		result[index] *= inverse_length
	return result


func _estimate_camera_basis_correction(
	pairs: Array[Dictionary],
	world_rotation: Basis
) -> Basis:
	var sum := Vector4.ZERO
	var reference := Quaternion()
	var has_reference := false
	for pair in pairs:
		var source_transform := pair["source_transform"] as Transform3D
		var target_transform := pair["target_transform"] as Transform3D
		var source_world_basis := (
			world_rotation * source_transform.basis.orthonormalized()
		).orthonormalized()
		var correction := (
			source_world_basis.inverse()
			* target_transform.basis.orthonormalized()
		).orthonormalized()
		var quaternion := Quaternion(correction).normalized()
		if not has_reference:
			reference = quaternion
			has_reference = true
		elif reference.dot(quaternion) < 0.0:
			quaternion = Quaternion(
				-quaternion.x,
				-quaternion.y,
				-quaternion.z,
				-quaternion.w
			)
		sum += Vector4(quaternion.x, quaternion.y, quaternion.z, quaternion.w)
	if sum.length_squared() < 0.000000000001:
		return OPENCV_TO_GODOT_CAMERA_BASIS
	var normalized := sum.normalized()
	return Basis(Quaternion(
		normalized.x,
		normalized.y,
		normalized.z,
		normalized.w
	)).orthonormalized()


func _pairs_have_pico_extrinsics(pairs: Array[Dictionary]) -> bool:
	for pair in pairs:
		var frame_id := str(pair.get("frame_id", ""))
		if not _pico_samples_by_frame.has(frame_id):
			continue
		var pico_sample := _pico_samples_by_frame[frame_id] as Dictionary
		if _extract_selected_pico_extrinsic(
			pico_sample.get("metadata", {}) as Dictionary
		) != null:
			return true
	return false


func _centroid(pairs: Array[Dictionary], position_key: StringName) -> Vector3:
	var result := Vector3.ZERO
	for pair in pairs:
		result += pair[position_key] as Vector3
	return result / float(pairs.size())


func _calculate_residuals(
	pairs: Array[Dictionary],
	scale: float,
	rotation: Basis,
	translation: Vector3,
	camera_basis_correction: Basis
) -> Dictionary:
	var position_squared_sum := 0.0
	var rotation_squared_sum := 0.0
	for pair in pairs:
		var source_transform := pair["source_transform"] as Transform3D
		var target_transform := pair["target_transform"] as Transform3D
		var predicted_position := translation + rotation * source_transform.origin * scale
		var position_error := predicted_position.distance_to(target_transform.origin)
		var predicted_basis := (
			rotation * source_transform.basis.orthonormalized()
			* camera_basis_correction
		).orthonormalized()
		var target_basis := target_transform.basis.orthonormalized()
		var rotation_error := Quaternion(predicted_basis).angle_to(Quaternion(target_basis))
		if not is_finite(position_error) or not is_finite(rotation_error):
			return {"ok": false, "error": "Registration residual is not finite"}
		position_squared_sum += position_error * position_error
		rotation_squared_sum += rotation_error * rotation_error
	var divisor := float(pairs.size())
	return {
		"ok": true,
		"position_rms_cm": sqrt(position_squared_sum / divisor) * 100.0,
		"rotation_rms_deg": rad_to_deg(sqrt(rotation_squared_sum / divisor)),
	}


func _extract_godot_camera_transform(
	metadata: Dictionary,
	explicit_transform: Variant
) -> Variant:
	if typeof(explicit_transform) == TYPE_TRANSFORM3D:
		return explicit_transform
	for key in [
		"godot_world_camera",
		"godot_world_camera_transform",
		"camera_to_godot_world",
	]:
		if metadata.has(key) and typeof(metadata[key]) == TYPE_TRANSFORM3D:
			return metadata[key]
	return null


func _extract_timestamp_seconds(metadata: Dictionary) -> float:
	for seconds_key in ["timestamp_seconds", "frame_timestamp_seconds"]:
		if metadata.has(seconds_key) and _is_number(metadata[seconds_key]):
			return float(metadata[seconds_key])
	for nanoseconds_key in [
		"frame_timestamp_ns",
		"capture_timestamp_ns",
		"timestamp_ns",
	]:
		if metadata.has(nanoseconds_key) and _is_number(metadata[nanoseconds_key]):
			return float(metadata[nanoseconds_key]) / 1_000_000_000.0
	return Time.get_ticks_msec() / 1000.0


func _registration_manifest_error(manifest: Dictionary) -> String:
	if int(manifest.get("schema_version", -1)) != MANIFEST_SCHEMA_VERSION:
		return "Unsupported registration manifest schema"
	if str(manifest.get("coordinate_contract", "")) \
			!= "lingbot_world_to_reconstruction_root_parent":
		return "Registration manifest coordinate contract is incompatible"
	if not bool(manifest.get("solved", false)):
		return "Registration manifest does not contain a solved registration"
	if typeof(manifest.get("automatic")) != TYPE_DICTIONARY \
			or typeof(manifest.get("manual")) != TYPE_DICTIONARY:
		return "Registration manifest sections are invalid"
	var automatic := manifest["automatic"] as Dictionary
	var manual := manifest["manual"] as Dictionary
	if not _is_number(automatic.get("scale")):
		return "Automatic scale is invalid"
	var automatic_scale := float(automatic["scale"])
	if not is_finite(automatic_scale) \
			or automatic_scale < MIN_AUTOMATIC_SCALE \
			or automatic_scale > MAX_AUTOMATIC_SCALE:
		return "Automatic scale is outside the safe range"
	if not _is_numeric_array(automatic.get("rotation_quaternion"), 4) \
			or not _is_numeric_array(automatic.get("translation"), 3):
		return "Automatic transform values are invalid"
	var rotation_values := automatic["rotation_quaternion"] as Array
	var quaternion := Quaternion(
		float(rotation_values[0]),
		float(rotation_values[1]),
		float(rotation_values[2]),
		float(rotation_values[3])
	)
	if not is_finite(quaternion.length_squared()) or quaternion.length_squared() < 0.000001:
		return "Automatic rotation is invalid"
	if not _is_numeric_array(manual.get("translation"), 3) \
			or not _is_numeric_array(manual.get("pivot"), 3):
		return "Manual registration vectors are invalid"
	if _array_to_vector3(manual["translation"] as Array).length() \
			> MAX_MANUAL_TRANSLATION_METERS:
		return "Manual translation is outside the safe range"
	for key in ["yaw_degrees", "pitch_degrees", "roll_degrees", "scale"]:
		if not _is_number(manual.get(key)) or not is_finite(float(manual[key])):
			return "Manual registration value %s is invalid" % key
	var manual_scale := float(manual["scale"])
	if manual_scale < MIN_MANUAL_SCALE or manual_scale > MAX_MANUAL_SCALE:
		return "Manual scale is outside the safe range"
	return ""


func _manual_rotation() -> Basis:
	return Basis(Vector3.UP, deg_to_rad(_manual_yaw_degrees)) \
		* Basis(Vector3.RIGHT, deg_to_rad(_manual_pitch_degrees)) \
		* Basis(Vector3.FORWARD, deg_to_rad(_manual_roll_degrees))


func _manual_values_are_finite() -> bool:
	return _is_finite_vector3(_manual_translation) \
		and is_finite(_manual_yaw_degrees) \
		and is_finite(_manual_pitch_degrees) \
		and is_finite(_manual_roll_degrees) \
		and is_finite(_manual_scale)


func _normalize_manual_angles() -> void:
	_manual_yaw_degrees = wrapf(_manual_yaw_degrees, -180.0, 180.0)
	_manual_pitch_degrees = wrapf(_manual_pitch_degrees, -180.0, 180.0)
	_manual_roll_degrees = wrapf(_manual_roll_degrees, -180.0, 180.0)


func _emit_sample_counts() -> void:
	var paired_count := 0
	for frame_id_value in _pico_samples_by_frame:
		var frame_id := str(frame_id_value)
		if not _lingbot_samples_by_frame.has(frame_id):
			continue
		var pico_sample := _pico_samples_by_frame[frame_id] as Dictionary
		if pico_sample.get("godot_world_camera") != null:
			paired_count += 1
	sample_count_changed.emit(
		_pico_samples_by_frame.size(),
		_lingbot_samples_by_frame.size(),
		paired_count
	)


func _normalize_frame_id(frame_id: Variant) -> String:
	if typeof(frame_id) not in [TYPE_STRING, TYPE_STRING_NAME, TYPE_INT]:
		return ""
	var normalized := str(frame_id).strip_edges()
	if normalized.is_empty() or normalized.length() > MAX_FRAME_ID_LENGTH:
		return ""
	return normalized


func _is_finite_transform(value: Transform3D) -> bool:
	return _is_finite_vector3(value.origin) \
		and _is_finite_vector3(value.basis.x) \
		and _is_finite_vector3(value.basis.y) \
		and _is_finite_vector3(value.basis.z) \
		and absf(value.basis.determinant()) > 0.000001


func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _is_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT]


func _is_numeric_array(value: Variant, required_size: int) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != required_size:
		return false
	for entry in value as Array:
		if not _is_number(entry) or not is_finite(float(entry)):
			return false
	return true


func _vector3_to_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]


func _array_to_vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _quaternion_to_array(value: Quaternion) -> Array[float]:
	return [value.x, value.y, value.z, value.w]


func _failure_result(message: String) -> Dictionary:
	_last_error = message
	registration_failed.emit(message)
	return {"ok": false, "error": message}


func _fail_bool(message: String) -> bool:
	_last_error = message
	registration_failed.emit(message)
	return false
