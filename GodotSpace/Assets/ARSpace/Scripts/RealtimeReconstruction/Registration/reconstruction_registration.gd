class_name ReconstructionRegistration
extends Node

## Estimates and applies one Sim(3) from LingBot map space into the parent
## space of ReconstructionRoot. Point data remains unchanged in LingBot space.

const MANIFEST_SCHEMA_VERSION: int = 1
const MIN_PAIR_COUNT: int = 6
const MIN_COLLECTION_SECONDS: float = 5.0
const MIN_TRANSLATION_SPAN_METERS: float = 0.3
const MIN_HORIZONTAL_VARIANCE: float = 0.0001
const MIN_DISTANCE_METERS: float = 0.01
const MIN_AUTOMATIC_SCALE: float = 0.01
const MAX_AUTOMATIC_SCALE: float = 100.0
const MIN_MANUAL_SCALE: float = 0.1
const MAX_MANUAL_SCALE: float = 10.0
const MAX_MANUAL_TRANSLATION_METERS: float = 100.0
const MAX_FRAME_ID_LENGTH: int = 128
const MAX_SAMPLE_COUNT: int = 1200

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
	var pairs := _collect_pairs()
	if pairs.size() < MIN_PAIR_COUNT:
		return _failure_result(
			"Automatic registration needs at least %d paired camera samples" \
			% MIN_PAIR_COUNT
		)
	var duration_seconds := _paired_duration_seconds(pairs)
	if duration_seconds < MIN_COLLECTION_SECONDS:
		return _failure_result(
			"Automatic registration needs at least %.1f seconds of motion" \
			% MIN_COLLECTION_SECONDS
		)
	var target_span_meters := _maximum_pair_distance(pairs, &"target_position")
	if target_span_meters < MIN_TRANSLATION_SPAN_METERS:
		return _failure_result(
			"Automatic registration needs at least %.2f m of camera translation" \
			% MIN_TRANSLATION_SPAN_METERS
		)

	var scale_result := _estimate_uniform_scale(pairs)
	if not bool(scale_result.get("ok", false)):
		return _failure_result(str(scale_result.get("error", "Scale estimation failed")))
	var estimated_scale := float(scale_result["scale"])
	if not is_finite(estimated_scale) \
			or estimated_scale < MIN_AUTOMATIC_SCALE \
			or estimated_scale > MAX_AUTOMATIC_SCALE:
		return _failure_result("Estimated automatic scale is outside the safe range")

	var source_centroid := _centroid(pairs, &"source_position")
	var target_centroid := _centroid(pairs, &"target_position")
	var yaw_result := _estimate_yaw(pairs, source_centroid, target_centroid)
	if not bool(yaw_result.get("ok", false)):
		return _failure_result(str(yaw_result.get("error", "Yaw estimation failed")))
	var estimated_yaw := float(yaw_result["yaw_radians"])
	if not is_finite(estimated_yaw):
		return _failure_result("Estimated yaw is not finite")
	var estimated_rotation := Basis(Vector3.UP, estimated_yaw)
	var estimated_translation := target_centroid \
		- estimated_rotation * source_centroid * estimated_scale
	if not _is_finite_vector3(estimated_translation):
		return _failure_result("Estimated translation is not finite")

	var residuals := _calculate_residuals(
		pairs,
		estimated_scale,
		estimated_rotation,
		estimated_translation
	)
	if not bool(residuals.get("ok", false)):
		return _failure_result(str(residuals.get("error", "Residual calculation failed")))

	_auto_scale = estimated_scale
	_auto_rotation = estimated_rotation
	_auto_translation = estimated_translation
	_manual_translation = Vector3.ZERO
	_manual_yaw_degrees = 0.0
	_manual_pitch_degrees = 0.0
	_manual_roll_degrees = 0.0
	_manual_scale = 1.0
	_manual_pivot = target_centroid
	_quality = {
		"pair_count": pairs.size(),
		"duration_seconds": duration_seconds,
		"translation_span_m": target_span_meters,
		"position_rms_cm": float(residuals["position_rms_cm"]),
		"rotation_rms_deg": float(residuals["rotation_rms_deg"]),
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


func _collect_pairs() -> Array[Dictionary]:
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
		var target_transform := pico_sample["godot_world_camera"] as Transform3D
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


func _estimate_uniform_scale(pairs: Array[Dictionary]) -> Dictionary:
	var ratios: Array[float] = []
	for first_index in range(pairs.size()):
		var first_source := pairs[first_index]["source_position"] as Vector3
		var first_target := pairs[first_index]["target_position"] as Vector3
		for second_index in range(first_index + 1, pairs.size()):
			var source_distance := first_source.distance_to(
				pairs[second_index]["source_position"] as Vector3
			)
			var target_distance := first_target.distance_to(
				pairs[second_index]["target_position"] as Vector3
			)
			if source_distance < MIN_DISTANCE_METERS \
					or target_distance < MIN_DISTANCE_METERS:
				continue
			var ratio := target_distance / source_distance
			if is_finite(ratio):
				ratios.append(ratio)
	if ratios.is_empty():
		return {"ok": false, "error": "Camera trajectory has no usable distance pairs"}
	ratios.sort()
	var middle_index := ratios.size() / 2
	var scale := ratios[middle_index]
	if ratios.size() % 2 == 0:
		scale = (ratios[middle_index - 1] + ratios[middle_index]) * 0.5
	return {"ok": true, "scale": scale}


func _estimate_yaw(
	pairs: Array[Dictionary],
	source_centroid: Vector3,
	target_centroid: Vector3
) -> Dictionary:
	var dot_sum := 0.0
	var cross_sum := 0.0
	var source_horizontal_energy := 0.0
	var target_horizontal_energy := 0.0
	for pair in pairs:
		var source_delta := (pair["source_position"] as Vector3) - source_centroid
		var target_delta := (pair["target_position"] as Vector3) - target_centroid
		dot_sum += target_delta.x * source_delta.x \
			+ target_delta.z * source_delta.z
		cross_sum += target_delta.x * source_delta.z \
			- target_delta.z * source_delta.x
		source_horizontal_energy += source_delta.x * source_delta.x \
			+ source_delta.z * source_delta.z
		target_horizontal_energy += target_delta.x * target_delta.x \
			+ target_delta.z * target_delta.z
	if source_horizontal_energy < MIN_HORIZONTAL_VARIANCE \
			or target_horizontal_energy < MIN_HORIZONTAL_VARIANCE:
		return {
			"ok": false,
			"error": "Camera trajectory needs horizontal translation to estimate yaw",
		}
	return {"ok": true, "yaw_radians": atan2(cross_sum, dot_sum)}


func _centroid(pairs: Array[Dictionary], position_key: StringName) -> Vector3:
	var result := Vector3.ZERO
	for pair in pairs:
		result += pair[position_key] as Vector3
	return result / float(pairs.size())


func _calculate_residuals(
	pairs: Array[Dictionary],
	scale: float,
	rotation: Basis,
	translation: Vector3
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
